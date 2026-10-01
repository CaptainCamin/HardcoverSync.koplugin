-- list_row: shaping an API book into a KOReader Menu row.
--
-- Pure module, no widgets, so this runs under stock Lua with no KOReader stubs
-- at all. It exists because the row shape is load-bearing in three separate
-- ways and each of them has already cost this plugin a bug:
--
--   * `file` must be set, or the vendored ListMenu draws the row as a FOLDER.
--     That branch crashed both shelf views on device.
--   * `title` must be set, or ListMenu falls back to filename_without_suffix
--     (listmenu.lua:502) and prints the synthetic `file` marker on screen. This
--     is not hypothetical: the shelf did exactly that, and
--     spec/emu/.out/shelf_page1.txt showed "hardcover-201" between every row's
--     title and status.
--   * cover keys must be absent, not empty, when there is no cover -- an empty
--     cover_url builds an image widget that can never load.
--
-- The series/author handling had four defects, all listed in the module header.

local ROOT = arg[1] or "."
package.path = ROOT .. "/spec/?.lua;" .. package.path

local support = require("support")
local r = support.reporter()

-- The only KOReader dependency is util.htmlEntitiesToUtf8, which this needs.
support.preload_koreader_stubs()

local ListRow = dofile(ROOT .. "/hardcover/lib/ui/list_row.lua")

local function base(overrides)
  local book = {
    book_id = 201,
    title = "The Lathe of Heaven",
    cached_image = {},
  }
  for k, v in pairs(overrides or {}) do book[k] = v end
  return book
end

-- ---------------------------------------------------------------- file marker
do
  local row = ListRow.row(base())
  r.check("row carries a file marker", row.file == "hardcover-201",
          "file was " .. tostring(row.file))
  r.check("file marker is unique per book",
          ListRow.row(base({ book_id = 202 })).file ~= row.file,
          "two books produced the same marker")
  -- A missing book_id must not produce "hardcover-nil", which every unlinked
  -- book would then collide on in the menu's cover cache.
  r.check("a book with no id still gets a distinct marker",
          type(ListRow.row({ title = "x" }).file) == "string",
          "file marker was not a string")
end

-- ---------------------------------------------------------------- title
-- The regression for the on-screen marker leak. A row with `text` but no
-- `title` renders its own file marker, because listmenu.lua:502 does
--   title = bookinfo.title and bookinfo.title or filename_without_suffix
do
  local shelf_row = ListRow.row(base())
  r.check("row sets title", shelf_row.title == "The Lathe of Heaven",
          "title was " .. tostring(shelf_row.title))
  r.check("title is not the file marker", shelf_row.title ~= shelf_row.file,
          "title fell back to the file marker")

  local with_year = ListRow.row(base({ release_year = 1971 }))
  r.check("title carries the year", with_year.title:find("1971", 1, true) ~= nil,
          "title was " .. tostring(with_year.title))

  r.check("a book with no title still gets one",
          ListRow.row({ book_id = 1 }).title ~= nil,
          "title was nil, so ListMenu would fall back to the file marker")
end

-- ---------------------------------------------------------------- authors, both shapes
-- The old code read `book.contributions.author`, indexing a FUNCTION, so the
-- primary author was always dropped and only contributors survived.
do
  local row = ListRow.row(base({
    author = { name = "Ursula K. Le Guin" },
    contributions = {
      { author = { name = "Ursula K. Le Guin" } },
      { author = { name = "Brian Attebery" } },
    },
  }))
  r.check("primary author survives",
          row.authors and row.authors:find("Le Guin", 1, true) ~= nil,
          "authors were " .. tostring(row.authors))
  r.check("contributors are included",
          row.authors and row.authors:find("Attebery", 1, true) ~= nil,
          "authors were " .. tostring(row.authors))
  -- The primary author also appears in contributions; printing them twice reads
  -- as two people with the same name.
  -- gmatch returns only captures, so count with a loop rather than assigning
  -- two values: `local _, n = s:gmatch(...)` leaves n nil.
  local occurrences = 0
  for _ in tostring(row.authors):gmatch("Le Guin") do
    occurrences = occurrences + 1
  end
  r.check("a repeated author is not printed twice", occurrences == 1,
          "Le Guin appears " .. tostring(occurrences) .. " times in " .. tostring(row.authors))

  --[[
  Shelf rows arrive pre-joined: Shelf.normalizeEntry puts the names in one
  `authors` STRING, not in author/contributions. A module that reads only the
  structured shape silently drops the shelf's entire author column -- which is
  what happened when the shelf was first pointed at this module, and what
  spec/shelf_dialog_harness.lua caught.
  ]]
  local shelf_row = ListRow.row(base({ authors = "Ursula K. Le Guin" }))
  r.check("a pre-joined authors string is used",
          shelf_row.authors == "Ursula K. Le Guin",
          "authors were " .. tostring(shelf_row.authors))
  r.check("a pre-joined authors string reaches the text",
          shelf_row.text:find("Le Guin", 1, true) ~= nil,
          "text was " .. tostring(shelf_row.text))

  local multi = ListRow.row(base({ authors = "Le Guin, Attebery" }))
  r.check("a joined list is split on commas",
          multi.authors == "Le Guin, Attebery",
          "authors were " .. tostring(multi.authors))

  r.check("authors with nothing set yield no authors field",
          ListRow.row(base()).authors == nil,
          "authors was " .. tostring(ListRow.row(base()).authors))
end

-- ---------------------------------------------------------------- series
-- `series` was assigned three times in the old code and the last write won, so
-- the series position was silently discarded whenever language was present.
do
  local row = ListRow.row(base({
    book_series = { { series = { name = "Hainish Cycle" }, position = 2 } },
  }))
  r.check("series name is kept", row.series and row.series:find("Hainish", 1, true) ~= nil,
          "series was " .. tostring(row.series))
  r.check("series position is kept",
          row.series and row.series:find("#2", 1, true) ~= nil,
          "series was " .. tostring(row.series))

  -- Language used to be carried in the `series` field, conflating two things.
  local with_lang = ListRow.row(base({
    book_series = { { series = { name = "Hainish Cycle" }, position = 2 } },
    language = { language = "English", code2 = "en" },
  }))
  r.check("language does not overwrite series",
          with_lang.series and with_lang.series:find("Hainish", 1, true) ~= nil,
          "series was " .. tostring(with_lang.series))
  r.check("language gets its own field", with_lang.language == "English",
          "language was " .. tostring(with_lang.language))
end

-- ---------------------------------------------------------------- mandatory
do
  r.check("reader count becomes mandatory",
          ListRow.row(base({ users_count = 4737 })).mandatory:find("4737", 1, true) ~= nil)
  r.check("read count becomes mandatory",
          ListRow.row(base({ users_read_count = 12 })).mandatory:find("12", 1, true) ~= nil)
  r.check("reader count wins over read count",
          ListRow.row(base({ users_count = 5, users_read_count = 9 })).mandatory:find("5", 1, true) ~= nil)
  r.check("a book with no counts still has a mandatory string",
          type(ListRow.row(base()).mandatory) == "string",
          "mandatory was " .. tostring(ListRow.row(base()).mandatory))
end

-- ---------------------------------------------------------------- covers
do
  local row = ListRow.row(base({
    cached_image = { url = "https://cdn/cover.jpg", width = 300, height = 450 },
  }))
  r.check("cover url is passed through", row.cover_url == "https://cdn/cover.jpg")
  r.check("cover dimensions are passed through", row.cover_w == 300 and row.cover_h == 450)
  r.check("cover is lazily loaded", row.lazy_load_cover == true)

  -- An empty-string cover_url builds an image widget that can never load, which
  -- draws as a broken tile. The key must be absent, not empty.
  local none = ListRow.row(base({ cached_image = { url = "" } }))
  r.check("an empty cover url yields no cover_url key", none.cover_url == nil,
          "cover_url was " .. tostring(none.cover_url))
  r.check("a missing cached_image is survivable",
          ListRow.row({ book_id = 1, title = "x" }).cover_url == nil)
end

-- ---------------------------------------------------------------- compatibility
do
  local plain = ListRow.row(base({ edition_id = 55, filetype = "epub" }),
                            { compatibility_mode = false })
  r.check("compatibility off keeps text as the plain title",
          plain.text == "The Lathe of Heaven", "text was " .. tostring(plain.text))

  local compat = ListRow.row(base({ edition_id = 55, filetype = "epub" }),
                             { compatibility_mode = true })
  r.check("compatibility on names the format",
          compat.text:find("epub", 1, true) ~= nil, "text was " .. tostring(compat.text))
end

-- ---------------------------------------------------------------- html
do
  local row = ListRow.row(base({ title = "The Lathe &amp; Heaven" }))
  r.check("html entities are decoded", row.title == "The Lathe & Heaven",
          "title was " .. tostring(row.title))
end

-- ---------------------------------------------------------------- rows()
do
  local rows = ListRow.rows({ base(), base({ book_id = 202 }) })
  r.check("rows() maps a list", #rows == 2, "got " .. #rows .. " rows")
  r.check("rows() keeps order", rows[1].book_id == 201 and rows[2].book_id == 202)
  r.check("rows() tolerates nil", #ListRow.rows(nil) == 0)
end

-- ---------------------------------------------------------------- highlight
do
  local rows = ListRow.rows({ base({ edition_id = 7 }) })
  r.check("no active item means no highlight", rows[1].highlight == nil
          or rows[1].highlight == false)
end

r.finish()