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

local json = require("json")
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

local function encode(value)
  local ok, text = pcall(json.encode, value)
  return ok and type(text) == "string" and text or nil
end

-- "simple": a JSON null reads as nil (the API is decoded the same way). Without it
-- KOReader's decoder hands back a placeholder that is not nil, and `if book.pages`
-- would be true for a book with no page count.
local function decode(text)
  if type(text) ~= "string" then return nil end
  local ok, value = pcall(json.decode, text, json.decode.simple)
  return ok and type(value) == "table" and value or nil
end

-- A shelf entry (or anything shaped like one) cut down to the book's own fields.
function BookStore.rowOf(entry)
  if type(entry) ~= "table" or not tonumber(entry.book_id) then return nil end
  local row = {}
  for _, field in ipairs(BookStore.ROW_FIELDS) do row[field] = entry[field] end
  row.book_id = tonumber(entry.book_id)
  return row
end

-- Save the books of these shelf entries, replacing what was saved of them.
function BookStore:saveRows(entries)
  local books, seen = {}, {}
  for _, entry in ipairs(type(entries) == "table" and entries or {}) do
    local row = BookStore.rowOf(entry)
    local text = row and not seen[row.book_id] and encode(row)
    if text then
      seen[row.book_id] = true
      books[#books + 1] = { book_id = row.book_id, row = text }
    end
  end
  if #books == 0 then return true end
  return self.db:putRows(books, self.now())
end

-- { [book_id] = row } for the ids that are saved.
function BookStore:rows(ids)
  local out = {}
  for id, text in pairs(self.db:getRows(ids) or {}) do
    out[id] = decode(text)
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
  local text = encode(kept)
  if not text then return false end

  local ok = self.db:putDetail(book_id, tonumber(edition_id) or 0, text, self.now())
  if not edition_id then
    -- an edition's page count is not the book's, so only a book-level fetch does this
    self:saveRows({ Shelf.normalizeEntry({ book = kept }) })
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

  local book = decode(edition_id and self.db:getDetail(book_id, tonumber(edition_id)) or nil)
    or decode(self.db:getDetail(book_id, 0))
    or decode(self.db:anyDetail(book_id))
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

-- Drop what no list holds and was not opened recently (see OPENED_CAP).
function BookStore:evict()
  return self.db:evict(BookStore.OPENED_CAP)
end

-- Everything, for sign out: what is saved shows what was on your lists.
function BookStore:clear()
  return self.db:clear()
end

return BookStore
