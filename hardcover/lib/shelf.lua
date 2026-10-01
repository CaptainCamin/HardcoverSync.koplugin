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
local function authorNames(book)
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

  if #names == 0 then
    return nil
  end

  return table.concat(names, ", ")
end

local function seriesName(book)
  local series = _t.dig(book, "book_series", 1)
  if not series then
    return nil
  end

  local name = _t.dig(series, "series", "name") or series.name
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
  }
end

function Shelf.statusLabel(status_id)
  return STATUS_LABELS[status_id] or "Unknown"
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

local function addRow(rows, label, value)
  if value == nil or value == "" then
    return
  end
  table.insert(rows, { label = label, value = value })
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

  addRow(rows, "ISBN", book.isbn_13 or book.isbn_10)

  local rating = book.rating
  if rating then
    if book.ratings_count then
      addRow(rows, "Community rating", string.format("%.1f (%d ratings)", rating, book.ratings_count))
    else
      addRow(rows, "Community rating", string.format("%.1f", rating))
    end
  end

  addRow(rows, "Readers", book.users_count)
  addRow(rows, "Reads", book.users_read_count)

  addRow(rows, "Description", book.description)

  return rows
end

return Shelf