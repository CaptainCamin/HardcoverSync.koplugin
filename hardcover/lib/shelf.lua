-- Pure logic for reading-list browsing and book detail display.
--
-- No KOReader requires on purpose: this module runs under stock Lua in the
-- spec suite, and the UI layer (shelf_dialog.lua) only formats what these
-- functions return.

local _t = require("hardcover/lib/table_util")

local Shelf = {}

local STATUS_LABELS = {
  [1] = "Want to Read",
  [2] = "Currently Reading",
  [3] = "Read",
  [4] = "Paused",
  [5] = "Did Not Finish",
  [6] = "Ignored",
}

local UNKNOWN_TITLE = "Unknown title"

-- reading_format_id is only present on edition queries
local FORMAT_LABELS = {
  [1] = "Physical Book",
  [2] = "Audiobook",
  [4] = "E-Book",
}

local function formatFallback(book)
  return FORMAT_LABELS[book.reading_format_id]
end

--
-- Author names out of the shapes the API returns.
--
-- `contributions` (requested explicitly) is the reliable structured field:
-- an array of { author = { name = ... } }.
--
-- `cached_contributors` is NOT a display string -- Hardcover returns it as a
-- nested array of the same contribution objects, so it must not be split on
-- commas. It is only used as a fallback when `contributions` is absent, and
-- both shapes are handled.
--
local function authorList(book)
  local names = {}

  local function add(author)
    if type(author) == "table" and author.name and author.name ~= "" then
      table.insert(names, author.name)
    end
  end

  local contributions = book.contributions
  if type(contributions) == "table" then
    if contributions.author then
      -- a lone contribution object rather than an array
      add(contributions.author)
    else
      for _, contribution in ipairs(contributions) do
        if type(contribution) == "table" then
          add(contribution.author)
        end
      end
    end
  end

  -- fallback: the cached field carries the same structure
  if #names == 0 then
    local cached = book.cached_contributors
    if type(cached) == "table" then
      if cached.author then
        add(cached.author)
      else
        for _, contribution in ipairs(cached) do
          if type(contribution) == "table" then
            add(contribution.author)
          end
        end
      end
    elseif type(cached) == "string" and cached ~= "" then
      -- some responses do deliver a plain "Last, First" list
      for name in cached:gmatch("[^,]+") do
        local trimmed = name:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
          table.insert(names, trimmed)
        end
      end
    end
  end

  return names
end

-- already a joined string, or nil when the book has no authors
local function authorNames(book)
  local names = authorList(book)
  if #names == 0 then
    return nil
  end

  return table.concat(names, ", ")
end

-- the series' bare name, without the book's place in it; nil when in none
local function seriesTitle(book)
  local series = _t.dig(book, "book_series", 1)
  if not series then
    return nil
  end

  local name = _t.dig(series, "series", "name") or series.name
  if type(name) ~= "string" or name == "" then
    return nil
  end
  return name
end

local function seriesName(book)
  local series = _t.dig(book, "book_series", 1)
  local name = seriesTitle(book)
  if not name then
    return nil
  end

  if series.position then
    return name .. " #" .. series.position
  end

  return name
end

--
-- Flatten a user_books row (with its nested book) into the shape the list
-- dialog renders. Defensive throughout: shelves contain user data that can
-- be partially null.
--
function Shelf.normalizeEntry(user_book)
  user_book = user_book or {}
  local book = user_book.book or {}

  return {
    user_book_id = user_book.id,
    book_id = book.book_id or book.id,
    status_id = user_book.status_id,
    user_rating = user_book.rating,
    date_added = user_book.date_added,
    title = book.title or user_book.title or UNKNOWN_TITLE,
    authors = authorNames(book),
    series = seriesName(book),
    release_year = book.release_year,
    pages = book.pages,
    users_count = book.users_count,
    community_rating = book.rating,
    ratings_count = book.ratings_count,
    cached_image = book.cached_image,
    description = book.description,
    -- kept raw so a book's details can be rebuilt from this row alone when the
    -- network is not there (see Shelf.detailFromEntry)
    contributions = book.contributions,
    book_series = book.book_series,
  }
end

--
-- The shape the book detail screen expects, rebuilt from a shelf row.
--
-- A shelf row carries most of what the detail query returns, so an offline tap
-- can still show something. It is the book level view: edition fields
-- (publisher, format, ISBN) are not on a shelf row and are simply absent.
--
function Shelf.detailFromEntry(entry)
  entry = entry or {}
  return {
    book = {
      book_id = entry.book_id,
      title = entry.title,
      release_year = entry.release_year,
      pages = entry.pages,
      users_count = entry.users_count,
      rating = entry.community_rating,
      ratings_count = entry.ratings_count,
      description = entry.description,
      cached_image = entry.cached_image,
      contributions = entry.contributions,
      book_series = entry.book_series,
    },
    user_book_id = entry.user_book_id,
    status_id = entry.status_id,
    user_rating = entry.user_rating,
  }
end

function Shelf.statusLabel(status_id)
  return STATUS_LABELS[status_id] or "Unknown"
end

-- The statuses a book can be put on, in the order the shelf chooser lists them.
function Shelf.statusChoices()
  local choices = {}
  for _, id in ipairs({ 1, 2, 3, 5 }) do
    choices[#choices + 1] = { status_id = id, label = STATUS_LABELS[id] }
  end
  return choices
end

-- The label of the details screen's shelf button: the invitation to put the book somewhere when it is
-- not in the library, otherwise to move it (where it is now is the status pill above).
function Shelf.shelfButtonText(status_id)
  if status_id then
    return "Change shelf"
  end
  return "Add to shelf"
end

--
-- Star glyph descriptors for a rating. Returns a list of "full"/"half"
-- entries so the UI can map them onto whichever icon font it has, rather
-- than hard-coding a glyph here.
--
function Shelf.ratingStars(rating)
  local stars = {}

  if not rating or rating <= 0 then
    return stars
  end

  if rating > 5 then
    rating = 5
  end

  local whole = math.floor(rating)
  for _ = 1, whole do
    table.insert(stars, "full")
  end

  if rating - whole >= 0.5 then
    table.insert(stars, "half")
  end

  return stars
end

--
-- Accumulate a fetched page onto the entries collected so far.
--
function Shelf.appendPage(entries, page, has_more)
  local result = entries or {}

  if page then
    for _, entry in ipairs(page) do
      table.insert(result, entry)
    end
  end

  -- nothing more to fetch: stop rather than requesting the next page
  if not has_more then
    return result
  end

  return result
end

-- U+00B7, as bytes so this reads the same on any Lua
local MIDDOT = " \194\183 "

-- 1234567 -> "1,234,567"
local function withCommas(n)
  local digits = string.format("%d", math.floor(tonumber(n) or 0))
  local formatted = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (formatted:gsub("^,", ""))
end

local function joinParts(parts)
  if #parts == 0 then return nil end
  return table.concat(parts, MIDDOT)
end

--
-- What the book detail header and status lines say, as plain strings.
--
-- Kept out of the dialog so it can be tested without KOReader, and so the
-- screen only has to lay out text: every field is a finished string or nil,
-- never an empty string, so the dialog can simply skip what is missing.
--
--   title, subtitle   the book's name
--   authors           "A. Author, B. Writer"
--   series            "The Saga #3"
--   facts             "2019 · 342 pages · Hardcover"
--   mine              "Currently Reading · Your rating 4.5"   (the reader's own standing)
--   community         "Community 4.2 (1,234 ratings) · 5,678 readers"
--   description       the full text
--   cover             { url, width, height } when there is a cover to fetch
--
function Shelf.detailSummary(detail)
  detail = detail or {}
  local book = detail.book or {}

  local summary = {
    title = (type(book.title) == "string" and book.title ~= "") and book.title or UNKNOWN_TITLE,
    subtitle = (type(book.subtitle) == "string" and book.subtitle ~= "") and book.subtitle or nil,
    description = (type(book.description) == "string" and book.description ~= "") and book.description or nil,
  }

  -- already a joined string, or nil when the book has no authors
  summary.authors = authorNames(book)

  summary.series = seriesName(book)
  -- what tapping the series and the author search for
  summary.series_title = seriesTitle(book)
  summary.first_author = authorList(book)[1]

  -- an edition's own release date is more precise than the book's year
  local published
  if type(book.release_date) == "string" then
    published = book.release_date:match("^(%d%d%d%d)")
  end
  if not published and book.release_year then
    published = tostring(book.release_year)
  end

  local facts = {}
  if published then facts[#facts + 1] = published end
  local pages = tonumber(book.pages)
  if pages and pages > 0 then facts[#facts + 1] = string.format("%d pages", pages) end
  local format = book.edition_format or formatFallback(book)
  if format and format ~= "" then facts[#facts + 1] = format end
  summary.facts = joinParts(facts)

  local mine = {}
  if detail.status_id then mine[#mine + 1] = Shelf.statusLabel(detail.status_id) end
  local user_rating = tonumber(detail.user_rating)
  if user_rating and user_rating > 0 then
    local shown = user_rating % 1 == 0 and string.format("%d", user_rating) or string.format("%.1f", user_rating)
    mine[#mine + 1] = "Your rating " .. shown
  end
  summary.mine = joinParts(mine)

  -- 0 means nobody has rated it: "0.0 (0 ratings)" is noise, not a rating
  local community = {}
  local rating = tonumber(book.rating)
  if rating and rating > 0 then
    local text = string.format("Community %.1f", rating)
    local count = tonumber(book.ratings_count)
    if count and count > 0 then
      text = text .. " (" .. withCommas(count) .. " ratings)"
    end
    community[#community + 1] = text
  end
  local readers = tonumber(book.users_count)
  if readers and readers > 0 then
    community[#community + 1] = withCommas(readers) .. " readers"
  end
  summary.community = joinParts(community)

  summary.cover = Shelf.coverOf(book)

  return summary
end

--
-- The id of the series a book belongs to, for fetching the rest of it. Nil when
-- the book is in no series (or the response did not carry an id).
--
function Shelf.seriesId(book)
  local series = type(book) == "table" and book.book_series
  if type(series) ~= "table" then return nil end
  for _, entry in ipairs(series) do
    local id = _t.dig(entry, "series", "id")
    if id then return id end
  end
  return nil
end

-- how a book's place in its series reads: 1 -> "#1", 2.5 -> "#2.5"
local function positionLabel(position)
  local n = tonumber(position)
  if not n then return "\226\128\162" end -- a bullet when there is no position
  return string.format("#%g", n)
end

-- short enough to sit at the end of a row
local SHORT_STATUS = {
  [1] = "Want to Read",
  [2] = "Reading",
  [3] = "Read",
  [5] = "Did Not Finish",
}

--
-- The "more in this series" carousel, as plain data.
--
-- `series` is { name, is_completed, books = { { book_id, title, position,
-- status_id, cover }, ... } } in series order. Returns nil when there is nothing
-- to link to (the only book in the series is the one on screen).
--
--   title          "More in Hainish Cycle"
--   subtitle       "9 books \194\183 complete"
--   items          every book: { book_id, number = "#4", title, status =
--                  "Read", current = bool, cover = { url, width, height } }
--   current_index  where the book on screen is, so the strip can open on it
--
-- The strip is paged by the screen (Shelf.carouselWindow), not trimmed here.
--
function Shelf.seriesCard(series, current_book_id)
  if type(series) ~= "table" or type(series.books) ~= "table" then return nil end

  local items, current_index, others = {}, nil, 0
  for i, book in ipairs(series.books) do
    local current = book.book_id == current_book_id
    if current then current_index = i else others = others + 1 end
    items[i] = {
      book_id = book.book_id,
      number = positionLabel(book.position),
      title = book.title or UNKNOWN_TITLE,
      status = (not current) and SHORT_STATUS[book.status_id] or nil,
      current = current,
      cover = book.cover,
    }
  end
  if others == 0 then return nil end

  local subtitle = { string.format("%d books", #items) }
  if series.is_completed == true then
    subtitle[#subtitle + 1] = "complete"
  elseif series.is_completed == false then
    subtitle[#subtitle + 1] = "ongoing"
  end

  return {
    title = "More in " .. (series.name or "this series"),
    subtitle = table.concat(subtitle, MIDDOT),
    items = items,
    current_index = current_index,
  }
end

--
-- Which items a strip shows: `per_page` of `total`, starting at `first`.
--
-- With no `first`, the page that holds `centre` (the book on screen), as near
-- the middle as the ends allow. Returns { first, last, has_prev, has_next }.
--
function Shelf.carouselWindow(total, per_page, first, centre)
  total = math.max(0, total or 0)
  per_page = math.max(1, per_page or 1)

  if first == nil then
    first = (centre or 1) - math.floor(per_page / 2)
  end
  first = math.max(1, math.min(first, math.max(1, total - per_page + 1)))

  local last = math.min(total, first + per_page - 1)
  return { first = first, last = last, has_prev = first > 1, has_next = last < total }
end

--
-- What says whether a saved shelf is still right, from a user_books_aggregate's
-- `aggregate`: how many books it holds, when the latest of them last changed, and the
-- total of your ratings on it. A book joining or leaving the shelf changes the count or
-- the time (Hardcover moves a book's updated_at when its status changes); a rating
-- changes the total, whether or not it moves the time. nil when the answer is not an
-- aggregate.
--
function Shelf.fingerprint(aggregate)
  if type(aggregate) ~= "table" then return nil end
  local count = tonumber(aggregate.count)
  if not count then return nil end
  local latest = type(aggregate.max) == "table" and aggregate.max.updated_at or nil
  local ratings = type(aggregate.sum) == "table" and tonumber(aggregate.sum.rating) or nil
  return string.format("%d|%s|%s", count, type(latest) == "string" and latest or "",
    ratings and string.format("%.1f", ratings) or "")
end

-- A book's cover as { url, width, height }, or nil when it has none.
function Shelf.coverOf(book)
  local image = type(book) == "table" and book.cached_image
  if type(image) == "table" and type(image.url) == "string" and image.url ~= "" then
    return { url = image.url, width = image.width, height = image.height }
  end
  return nil
end

-- The rows the header does not already say: publisher, language, ISBN, reads.
local HEADER_LABELS = {
  Author = true, Series = true, Format = true, Pages = true, Published = true,
  ["Community rating"] = true, Readers = true, Description = true,
}

function Shelf.extraRows(book)
  local rows = {}
  for _, row in ipairs(Shelf.detailRows(book)) do
    if not HEADER_LABELS[row.label] then
      rows[#rows + 1] = row
    end
  end
  return rows
end

local function addRow(rows, label, value)
  if value == nil or value == "" then
    return
  end
  table.insert(rows, { label = label, value = value })
end

-- "1997-06-26" -> "26 Jun 1997"; a bare year stays a year; nil for anything else
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local function dateText(value)
  if type(value) ~= "string" then return nil end
  local y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then return value:match("^(%d%d%d%d)$") end
  m = MONTHS[tonumber(m)]
  if not m then return y end
  return string.format("%d %s %s", tonumber(d), m, y)
end

-- 31288 -> "8h 41m"; under an hour "41m"; nil for nothing
local function durationText(seconds)
  seconds = tonumber(seconds)
  if not seconds or seconds < 60 then return nil end
  local minutes = math.floor(seconds / 60 + 0.5)
  if minutes < 60 then return minutes .. "m" end
  return string.format("%dh %dm", math.floor(minutes / 60), minutes % 60)
end

-- Who else worked on it, one row per role: "Illustrator", "Translator", "Narrator"...
-- (the authors are in the header; a contribution with no role is an author).
local function creditRows(rows, book)
  local roles, order = {}, {}
  for _, c in ipairs(type(book.contributions) == "table" and book.contributions or {}) do
    local role = type(c) == "table" and type(c.contribution) == "string" and c.contribution or nil
    local name = type(c) == "table" and type(c.author) == "table" and c.author.name or nil
    if role and role ~= "" and role ~= "Author" and type(name) == "string" and name ~= "" then
      if not roles[role] then roles[role] = {}; order[#order + 1] = role end
      table.insert(roles[role], name)
    end
  end
  for _, role in ipairs(order) do
    table.insert(rows, { label = role, value = table.concat(roles[role], ", ") })
  end
end

local function countText(n, one, many)
  n = tonumber(n)
  if not n or n <= 0 then return nil end
  local text = tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return text .. " " .. (n == 1 and one or many)
end

--
-- Label/value rows describing a book, in display order. Edition level fields
-- (publisher, format, ISBN, edition release date) win over the book level
-- equivalents when the caller fetched an edition.
--
function Shelf.detailRows(book)
  book = book or {}
  local rows = {}

  addRow(rows, "Author", authorNames(book))

  local series = seriesName(book)
  addRow(rows, "Series", series)

  addRow(rows, "Format", book.edition_format or formatFallback(book))
  addRow(rows, "Publisher", _t.dig(book, "publisher", "name"))
  addRow(rows, "Pages", book.pages)
  addRow(rows, "Audiobook", durationText(book.audio_seconds or _t.dig(book, "default_audio_edition", "audio_seconds")))

  local language = book.language
  if type(language) == "table" then
    addRow(rows, "Language", language.language or language.code2)
  else
    addRow(rows, "Language", language)
  end

  -- an edition's own release date is more precise than the book's year.
  -- Normalize both to a string so callers never have to type-check.
  local published
  if type(book.release_date) == "string" then
    published = book.release_date:match("^(%d%d%d%d)")
  end
  if not published and book.release_year then
    published = tostring(book.release_year)
  end
  addRow(rows, "Published", published)

  -- the edition's own day, and the book's first appearance when that is another day
  local edition_day = type(book.release_date) == "string" and dateText(book.release_date) or nil
  local first_day = dateText(book.first_release_date)
  addRow(rows, "Edition released", edition_day and #edition_day > 4 and edition_day or nil)
  if first_day and first_day ~= edition_day then addRow(rows, "First published", first_day) end

  addRow(rows, "ISBN", book.isbn_13 or book.isbn_10)
  creditRows(rows, book)

  -- 0 means nobody has rated it: "0.0 (0 ratings)" is noise, not a rating
  local rating = book.rating
  if rating and rating > 0 then
    if book.ratings_count then
      addRow(rows, "Community rating", string.format("%.1f (%d ratings)", rating, book.ratings_count))
    else
      addRow(rows, "Community rating", string.format("%.1f", rating))
    end
  end

  addRow(rows, "Readers", book.users_count)
  addRow(rows, "Reads", countText(book.users_read_count, "read", "reads") and tostring(book.users_read_count):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
  addRow(rows, "Written reviews", countText(book.reviews_count, "review", "reviews"))
  addRow(rows, "On lists", countText(book.lists_count, "list", "lists"))
  addRow(rows, "Editions", countText(book.editions_count, "edition", "editions"))

  addRow(rows, "Description", book.description)

  return rows
end

return Shelf