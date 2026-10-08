-- Every book the device knows, kept once.
--
-- A book on three lists is saved once, not three times, and so is its synopsis.
-- What a book is (title, authors, series, synopsis, publication year, cover) hardly
-- ever changes, so once it is here it is not fetched again to show a list: a list
-- that changes only has to say which books it holds now (see list_store.lua).
--
-- Two kinds of record:
--   row     what a list or shelf row shows: a shelf entry's book fields (see
--           Shelf.normalizeEntry), never your own status or rating
--   detail  the book's details screen as last fetched, per edition, so a book you
--           opened online opens offline with everything it showed
--
-- Pure logic over an injected store (`db`, see sqlite_store.lua), which holds strings;
-- this file does the JSON. Every operation is best-effort, like the store under it.

local Codec = require("hardcover/lib/codec")
local Shelf = require("hardcover/lib/shelf")

local BookStore = {}
BookStore.__index = BookStore

-- How many books you only opened (on no saved list) keep their details. A book a list
-- holds stays as long as the list does, whatever this says.
BookStore.OPENED_CAP = 500

-- The fields of a shelf entry that describe the book itself. Your status and rating,
-- when the book went on a shelf or list, and the row ids are left out: they belong to
-- the shelf or list, and change.
BookStore.ROW_FIELDS = {
  "book_id", "title", "authors", "series", "release_year", "pages", "users_count",
  "community_rating", "ratings_count", "cached_image", "description", "contributions",
  "book_series",
}

function BookStore:new(o)
  o = o or {}
  o.now = o.now or os.time
  return setmetatable(o, self)
end

-- A shelf entry (or anything shaped like one) cut down to the book's own fields.
function BookStore.rowOf(entry)
  if type(entry) ~= "table" or not tonumber(entry.book_id) then return nil end
  local row = {}
  for _, field in ipairs(BookStore.ROW_FIELDS) do row[field] = entry[field] end
  row.book_id = tonumber(entry.book_id)
  return row
end

-- Did the old saved-shelves file cut this synopsis short? It kept at most 600 bytes
-- and ended a cut one with an ellipsis.
function BookStore.isCut(description)
  return type(description) == "string" and #description >= 300 and #description <= 603
    and description:sub(-3) == "\226\128\166"
end

-- How long details that may still change (see isSettled) are trusted before the details
-- screen fetches them again.
BookStore.RECHECK_AFTER = 7 * 24 * 3600

--
-- Is what the details screen shows of this book (the `book` of Api:getBookDetail) done
-- changing? Out, with a synopsis, a cover and a length: a book's synopsis, publication
-- date, authors and series hardly ever change after that, so its details are kept for
-- good. A book still to come, or missing any of those, is fetched again now and then
-- (RECHECK_AFTER), as Hardcover's librarians fill it in.
--
function BookStore.isSettled(book, today)
  if type(book) ~= "table" then return false end
  if type(book.description) ~= "string" or book.description == "" then return false end
  if not (type(book.cached_image) == "table" and book.cached_image.url) then return false end
  if not (tonumber(book.pages) or tonumber(book.audio_seconds)
      or (type(book.default_audio_edition) == "table" and tonumber(book.default_audio_edition.audio_seconds))) then
    return false
  end
  today = today or os.date("%Y-%m-%d")
  local released = book.first_release_date or book.release_date
  if type(released) == "string" and released ~= "" then return released <= today end
  local year = tonumber(book.release_year)
  return year ~= nil and year <= tonumber(today:sub(1, 4))
end

-- Save the books of these shelf entries, replacing what was saved of them. `partial`:
-- these rows are not whole (see isCut), so the books count as not saved yet.
function BookStore:saveRows(entries, partial)
  local books, seen = {}, {}
  for _, entry in ipairs(type(entries) == "table" and entries or {}) do
    local row = BookStore.rowOf(entry)
    local text = row and not seen[row.book_id] and Codec.encode(row)
    if text then
      seen[row.book_id] = true
      books[#books + 1] = { book_id = row.book_id, row = text, partial = partial and true or nil }
    end
  end
  if #books == 0 then return true end
  return self.db:putRows(books, self.now())
end

-- { [book_id] = row } for the ids that are saved.
function BookStore:rows(ids)
  local out = {}
  for id, text in pairs(self.db:getRows(ids) or {}) do
    out[id] = Codec.decode(text)
  end
  return out
end

-- The ids in `ids` with no saved row, in the order given and each once: what a list
-- that changed has to fetch.
function BookStore:missing(ids)
  local known = self.db:knownIds(ids) or {}
  local out, seen = {}, {}
  for _, id in ipairs(ids or {}) do
    id = tonumber(id)
    if id and not known[id] and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  return out
end

--
-- Keep what the details screen just fetched (Api:getBookDetail's answer). Only the
-- book: your status and rating on it are left out, as they change elsewhere. A detail
-- fetched without an edition also refreshes the book's row, so the numbers a list shows
-- (community rating, readers) catch up whenever the book is opened.
--
function BookStore:saveDetail(book_id, edition_id, detail)
  local book = type(detail) == "table" and detail.book
  book_id = tonumber(book_id) or (type(book) == "table" and tonumber(book.book_id))
  if type(book) ~= "table" or not book_id then return false end

  local kept = {}
  for k, v in pairs(book) do
    if k ~= "user_books" then kept[k] = v end
  end
  -- when Hardcover last said what this is (see isSettled)
  kept._checked_at = self.now()
  local text = Codec.encode(kept)
  if not text then return false end

  local ok = self.db:putDetail(book_id, tonumber(edition_id) or 0, text, self.now())
  if not edition_id then
    -- an edition's page count is not the book's, so only a book-level fetch does this
    local row = Shelf.normalizeEntry({ book = kept })
    row.user_book_id, row.status_id, row.user_rating, row.date_added = nil, nil, nil, nil
    self:saveRows({ row })
  end
  self.db:evict(BookStore.OPENED_CAP)
  return ok
end

--
-- What the details screen can show of a book with no network: { book = ... } in the
-- shape Api:getBookDetail returns, or nil when nothing is saved. Your status and rating
-- are not in it (the caller lays them over). `source` says where it came from:
--   "details"  the details as they were last fetched (this edition's, or any)
--   "row"      only what a list or shelf row knows: no edition fields, but the synopsis
--
function BookStore:detail(book_id, edition_id)
  book_id = tonumber(book_id)
  if not book_id then return nil end

  local book = Codec.decode(edition_id and self.db:getDetail(book_id, tonumber(edition_id)) or nil)
    or Codec.decode(self.db:getDetail(book_id, 0))
    or Codec.decode(self.db:anyDetail(book_id))
  if book then
    book.book_id = book.book_id or book_id
    return { book = book }, "details"
  end

  local row = self:rows({ book_id })[book_id]
  if row then
    local detail = Shelf.detailFromEntry(row)
    return { book = detail.book }, "row"
  end
end

--
-- The details screen's saved copy of a book, if it can be shown without asking Hardcover
-- for the book again: fetched before (not just a list's row), and either done changing
-- (isSettled) or fetched within RECHECK_AFTER. Counts as the book being opened again.
-- Returns { book = ... } (no status or rating) or nil.
--
function BookStore:settledDetail(book_id, edition_id)
  local detail, source = self:detail(book_id, edition_id)
  if source ~= "details" then return nil end
  local book = detail.book
  local fresh = tonumber(book._checked_at)
    and (self.now() - book._checked_at) >= 0 and (self.now() - book._checked_at) < BookStore.RECHECK_AFTER
  if not (BookStore.isSettled(book) or fresh) then return nil end
  self.db:touchDetail(tonumber(book_id), tonumber(edition_id) or 0, self.now())
  return detail
end

--
-- The community numbers Hardcover gave for the book just now (rating, ratings_count,
-- users_count, users_read_count), laid over its saved details and row, for next time.
-- When the details were fetched does not change: these numbers say nothing about whether
-- the rest is current.
--
function BookStore:updateNumbers(book_id, numbers)
  book_id = tonumber(book_id)
  if not (book_id and type(numbers) == "table") then return false end
  local fields = { "rating", "ratings_count", "users_count", "users_read_count" }
  local text = self.db:getDetail(book_id, 0)
  local book = Codec.decode(text)
  if book then
    for _, f in ipairs(fields) do
      if numbers[f] ~= nil then book[f] = numbers[f] end
    end
    local updated = Codec.encode(book)
    if updated and updated ~= text then self.db:putDetail(book_id, 0, updated, self.now()) end
  end
  local row = self:rows({ book_id })[book_id]
  -- (a row whose synopsis is still cut short is left to be fetched whole)
  if row and not BookStore.isCut(row.description) then
    if numbers.rating ~= nil then row.community_rating = numbers.rating end
    if numbers.ratings_count ~= nil then row.ratings_count = numbers.ratings_count end
    if numbers.users_count ~= nil then row.users_count = numbers.users_count end
    self:saveRows({ row })
  end
  return true
end

-- Your saved copy of a series (Api:getSeriesBooks's answer) and when it was saved, or nil.
function BookStore:series(user_id, series_id)
  local saved = Codec.decode(self.db:getBlob("series:" .. tostring(user_id or 0) .. ":" .. tostring(series_id)))
  if saved and type(saved.series) == "table" then return saved.series, saved.saved_at end
end

function BookStore:putSeries(user_id, series_id, series)
  local text = type(series) == "table" and Codec.encode({ series = series, saved_at = self.now() })
  return text and self.db:putBlob("series:" .. tostring(user_id or 0) .. ":" .. tostring(series_id), text) or false
end

-- Drop what no list holds and was not opened recently (see OPENED_CAP).
function BookStore:evict()
  return self.db:evict(BookStore.OPENED_CAP)
end

-- Everything, for sign out: what is saved shows what was on your lists.
function BookStore:clear()
  return self.db:clear()
end

return BookStore
