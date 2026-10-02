-- Pure shaping of an API book into a KOReader Menu row.
--
-- No widgets and no KOReader beyond util/gettext, so it runs under stock Lua in
-- the harness. It exists because this logic was duplicated in two dialogs and
-- had drifted: search_dialog.lua and shelf_dialog.lua each built rows slightly
-- differently, and the shelf version was missing a field whose absence is
-- visible on screen (see `title` below).
--
-- Three row fields are load-bearing, and each has already caused a bug:
--
--   * `file` -- the vendored ListMenu picks its drawing path with
--     is_directory = not (entry.is_file or entry.file). A row with neither is
--     drawn through the FOLDER branch, which crashed both shelf views on device.
--     API-sourced books have no real file, so the marker is synthetic.
--
--   * `title` -- listmenu.lua:277 sets bookinfo = self.entry, and :502 renders
--     title = bookinfo.title and bookinfo.title or filename_without_suffix,
--     where filename_without_suffix derives from entry.file (:131). A row that
--     sets only `text` therefore prints its own file marker on screen. The
--     shelf did exactly that: every row showed "hardcover-201" between its
--     title and status label. Both fields are always set.
--
--   * cover keys -- absent when there is no cover, never empty. An empty-string
--     cover_url builds an image widget that can never load.
--
-- Four defects fixed in the move from search_dialog.lua:
--
--   * `if book.contributions.author` indexed a FUNCTION, so the primary author
--     was always dropped and only contributors survived.
--   * `series` was assigned three times; the last write won, so a series
--     position was discarded whenever the book also had a language.
--   * The language branch read `self.series` -- the dialog's field, never set --
--     to decide whether to prefix, so it always took the wrong branch.
--   * Language was carried in the `series` field, conflating two unrelated
--     things and confusing ListMenu's series rendering.

local util = require("util")
local _ = require("gettext")

local ListRow = {}

-- Decode HTML entities, falling back when the field is absent or empty.
-- An empty string is treated as absent because the API returns "" for a field
-- it has no value for, and rendering a blank line is worse than the fallback.
local function decode(value, fallback)
  if type(value) ~= "string" or value == "" then return fallback end
  return util.htmlEntitiesToUtf8(value)
end

--[[
The primary author plus contributors, de-duplicated, in display order.

De-duplication matters: the primary author usually also appears as the first
contribution, and printing them twice reads as two people with one name.

Two shapes arrive here, and the shelf path used to depend on the difference
without saying so:

  * a search row, straight off the API, has author.name and a contributions
    list;
  * a shelf row has already been normalised by Shelf, which joins the names
    into one `authors` STRING.

Handling only the first is how the shelf lost its author column: the search
dialog had been rewritten to use this module, and the shelf's rows silently
came out with a title and no author. Prefer the pre-joined string when present
and fall back to the structured fields.
]]
function ListRow.authors(book)
  local seen, out = {}, {}

  local function push(name)
    name = decode(name, nil)
    if name and not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end

  -- Shelf rows: already joined by Shelf.normalizeEntry.
  if type(book.authors) == "string" and book.authors ~= "" then
    for name in book.authors:gmatch("[^,]+") do
      push((name:gsub("^%s+", ""):gsub("%s+$", "")))
    end
    if #out > 0 then return table.concat(out, ", ") end
  end

  -- Search rows: the structured form.
  push(book.author and book.author.name)
  push(type(book.author) == "string" and book.author or nil)

  for _, contribution in ipairs(book.contributions or {}) do
    if type(contribution) == "table" then
      -- Contributions carry author either as a table or as a bare string,
      -- depending on the query. Handle both rather than assuming.
      if type(contribution.author) == "table" then
        push(contribution.author.name)
      else
        push(contribution.author)
      end
      push(contribution.name)
    end
  end

  return table.concat(out, ", ")
end

--
-- Build one row.
--
-- opts.year = false leaves the release year off the title.
-- opts.compatibility_mode (default true) selects the single-line `text` form
-- used by the stock Menu; the SearchMenu path wants title/authors laid out
-- separately instead. `title` is set either way, because ListMenu reads it.
--
function ListRow.row(book, opts)
  opts = opts or {}
  book = book or {}

  local title = decode(book.title, _("Unknown Title"))
  if opts.year ~= false and book.release_year and book.release_year ~= "" then
    title = title .. " (" .. tostring(book.release_year) .. ")"
  end

  -- Which count to show, when both are present. users_count is how many people
  -- have this on a list; users_read_count is how many finished it. The first is
  -- the more common signal, so it wins.
  local mandatory = ""
  if book.users_count and book.users_count > 0 then
    mandatory = tostring(book.users_count) .. " " .. _("readers")
  elseif book.users_read_count and book.users_read_count > 0 then
    mandatory = tostring(book.users_read_count) .. " " .. _("reads")
  end

  local row = {
    text = title,
    -- See the header: without this, ListMenu prints the file marker instead.
    title = title,
    mandatory = mandatory,
    mandatory_dim = true,
    book_id = book.book_id,
    edition_id = book.edition_id,
    edition_format = book.edition_format,
    filetype = book.filetype,
    -- Carried so a hold or tap handler can act on the book without re-deriving
    -- it from the row. Costs nothing: the callback already closes over it.
    book = book,
    -- See the header. Never omit, never make nil.
    file = "hardcover-" .. tostring(book.book_id),
  }

  -- Series, with its position. Assigned once: the old code wrote this field up
  -- to three times and the last write silently discarded the position.
  local series_entry = book.book_series and book.book_series[1] or nil
  local series_name = series_entry and series_entry.series and series_entry.series.name or nil
  if series_name then
    -- The name only: ListMenu appends " #<series_index>" itself, so putting the
    -- position in both printed it twice ("Series #3 #3").
    row.series = series_name
    local position = series_entry.position
    if position then
      row.series_index = position
    end
  end

  -- Language gets its own field. It used to be written into `series`, which
  -- both lost the series and made ListMenu render a language as a series name.
  local language = book.language
  if language then
    row.language = language.language or language.code2
  end

  if book.pages then
    row.pages = book.pages
  end

  local authors = ListRow.authors(book)
  if authors ~= "" then
    row.authors = authors
  end

  if opts.compatibility_mode ~= false then
    local line = title
    if book.edition_id then
      -- An edition row identifies itself by format; the book row by author.
      if book.filetype then
        line = line .. " - " .. tostring(book.filetype)
      end
    elseif authors ~= "" then
      line = line .. " - " .. authors
    end
    row.text = line
  end

  -- Cover keys only when a URL actually exists. See the header.
  local image = book.cached_image
  if type(image) == "table" and type(image.url) == "string" and image.url ~= "" then
    row.cover_url = image.url
    row.cover_w = image.width
    row.cover_h = image.height
    row.lazy_load_cover = true
  end

  return row
end

--
-- Map a list of books to rows, marking the one matching active_item.
--
-- The highlight tells the reader where they already are without opening
-- anything -- most useful in the edition picker, where the current edition is
-- otherwise indistinguishable from the others.
--
function ListRow.rows(books, opts, active_item)
  local out = {}
  for i, book in ipairs(books or {}) do
    local row = ListRow.row(book, opts)
    if active_item then
      local same_edition = row.edition_id and row.edition_id == active_item.edition_id
      local same_book = row.book_id == active_item.book_id
      row.highlight = (same_edition or same_book) or false
    end
    out[i] = row
  end
  return out
end

return ListRow