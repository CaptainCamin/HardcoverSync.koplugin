-- The book detail screen: what the dialog builds, and the query behind it.
--
-- Found by reading the code against KOReader's own widget source (the emulator
-- that would render it needs a KOReader install). Each check below is one of
-- those defects:
--
--   * a nil subtitle left a hole in the VerticalGroup constructor, and the
--     group's ipairs stopped at it: everything after the title vanished
--   * the Back key was bound to an event with no handler
--   * TextWidget reads max_width, not width, so long text ran off the screen
--   * a TextBoxWidget given a height shows only the lines that fit
--   * the edition query was sent the book id, never the edition id
--
-- The widgets here are small stand-ins that keep their children in plain
-- arrays, so the structure the dialog builds can be walked and counted.
--
-- Run with:  lua spec/book_detail_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function make()
  local t = {}
  return setmetatable(t, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end

-- a widget class whose instances are the table they were built from, so a
-- constructor's children stay in a plain array
local function widget(kind)
  local C = { kind = kind }
  C.__index = C
  function C:new(o)
    o = o or {}
    o.kind = kind
    return setmetatable(o, C)
  end
  function C:getSize() return { w = self.width or 0, h = 20 } end
  function C:free() end
  return C
end

local FocusManager = {}
function FocusManager:extend(o)
  o = o or {}
  o.__index = o
  return setmetatable(o, { __index = FocusManager })
end
function FocusManager:new(o)
  o = setmetatable(o or {}, self)
  o.key_events = {}
  o:init()
  return o
end

local widgets = {
  ["ui/widget/focusmanager"] = FocusManager,
  ["ui/widget/textwidget"] = widget("Text"),
  ["ui/widget/textboxwidget"] = widget("TextBox"),
  ["ui/widget/button"] = widget("Button"),
  ["ui/widget/imagewidget"] = widget("Image"),
  ["ui/renderimage"] = { renderImageData = function() return _G.FAKE_BB end },
  ["ui/widget/horizontalgroup"] = widget("HGroup"),
  ["ui/widget/horizontalspan"] = widget("HSpan"),
  ["ui/widget/verticalgroup"] = widget("VGroup"),
  ["ui/widget/verticalspan"] = widget("VSpan"),
  ["ui/widget/container/centercontainer"] = widget("Center"),
  ["ui/widget/container/framecontainer"] = widget("Frame"),
  ["ui/widget/container/leftcontainer"] = widget("Left"),
  ["ui/widget/container/scrollablecontainer"] = widget("Scroll"),
  ["ui/geometry"] = { new = function(_, t) return t end },
  ["device"] = { screen = {
    getWidth = function() return 1000 end,
    getHeight = function() return 1400 end,
    scaleBySize = function(_, n) return n end,
    getSize = function() return { w = 1000, h = 1400 } end,
  } },
}

package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
local real_require = require
_G.require = function(name)
  if widgets[name] then return widgets[name] end
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local BookDetailDialog = real_require("hardcover/lib/ui/book_detail_dialog")
local Shelf = real_require("hardcover/lib/shelf")
local Api = real_require("hardcover/lib/hardcover_api")

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local function kinds(group)
  local out = {}
  for _, child in ipairs(group) do out[#out + 1] = child.kind end
  return out
end

local function detail(book)
  return { book = book, status_id = 2, user_rating = 4 }
end

local function contains(group, widget)
  for _, child in ipairs(group) do
    if child == widget then return true end
  end
  return false
end

-- a loader that records what it is asked for and hands the image over on demand
local function fakeLoader()
  local loader = { urls = {}, halted = false }
  function loader:loadImages(urls, callback)
    for _, url in ipairs(urls) do self.urls[#self.urls + 1] = url end
    self.deliver = callback
    return {}, function() self.halted = true end
  end
  return loader
end

local FULL = {
  title = "The Dispossessed", subtitle = "An Ambiguous Utopia",
  contributions = { { author = { name = "Ursula K. Le Guin" } } },
  book_series = { { position = 1, series = { name = "Hainish Cycle" } } },
  release_year = 1974, pages = 387, rating = 4.3, ratings_count = 12345, users_count = 56789,
  description = "A description.", publisher = { name = "Harper" }, isbn_13 = "9780061054884",
  cached_image = { url = "http://img/cover.jpg", width = 200, height = 300 },
}

print("\n== the body is built whole ==")

check("a book with no subtitle still shows its status, details and description", function()
  local d = BookDetailDialog:new { detail = detail({ title = "T", description = "About it.", publisher = { name = "P" } }) }
  assert(contains(d.content_group, d.status_text), "status missing")
  assert(contains(d.content_group, d.description_text), "description missing: " .. table.concat(kinds(d.content_group), ","))
  assert(#d.meta_rows == 1 and contains(d.content_group, d.meta_rows[1]), "details missing")
end)

check("a book with a subtitle shows it in the header", function()
  local d = BookDetailDialog:new { detail = detail({ title = "T", subtitle = "A Subtitle" }) }
  assert(d.subtitle_text and d.subtitle_text.kind == "TextBox", "no subtitle")
  assert(contains(d.content_group, d.description_text) == false)
  assert(#kinds(d.content_group) >= 3, table.concat(kinds(d.content_group), ","))
end)

check("a detail rebuilt from a saved row (no edition fields) is whole", function()
  local row = Shelf.normalizeEntry({ id = 1, status_id = 1, book = { book_id = 7, title = "Saved", pages = 100, description = "d" } })
  local d = BookDetailDialog:new { detail = Shelf.detailFromEntry(row) }
  assert(d.title_text and d.description_text and contains(d.content_group, d.description_text))
end)

check("what the book has appears, what it lacks does not", function()
  local d = BookDetailDialog:new { detail = detail(FULL) }
  assert(d.authors_text and d.series_text and d.facts_text and d.community_text, "header lines missing")
  local bare = BookDetailDialog:new { detail = { book = { title = "T" } } }
  assert(bare.authors_text == nil and bare.series_text == nil and bare.facts_text == nil
    and bare.status_text == nil and bare.community_text == nil and bare.description_text == nil,
    "invented a line for a field the book does not have")
  assert(#bare.meta_rows == 0, "invented detail rows")
end)

print("\n== the header ==")

check("the title is bold and wraps", function()
  local d = BookDetailDialog:new { detail = detail({ title = string.rep("Long ", 40) }) }
  assert(d.title_text.kind == "TextBox" and d.title_text.bold == true)
  assert(d.title_text.width == d.content_width, "no cover, so it should span the content width")
end)

check("with a cover, the text sits beside it in the width that is left", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  assert(d.cover_cell, "no cover box")
  local cover_w = math.floor(d.content_width * 0.30)
  assert(d.title_text.width == d.content_width - cover_w - 15, "title width " .. tostring(d.title_text.width))
  assert(d.content_group[1].kind == "HGroup", "header is not cover-beside-text")
end)

check("the cover box has a fixed size, so the text does not move when the picture arrives", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  local box = d.cover_cell[1].dimen
  assert(box.w == math.floor(d.content_width * 0.30) and box.h == math.floor(box.w * 1.5), "box " .. box.w .. "x" .. box.h)
end)

check("no cover, no box and no fetch", function()
  local loader = fakeLoader()
  local d = BookDetailDialog:new { detail = detail({ title = "T" }), image_loader = loader }
  assert(d.cover_cell == nil and #loader.urls == 0)
  assert(d.content_group[1] == d.content_group[1] and d.content_group[1].kind ~= "HGroup", "header has a cover column with no cover")
end)

check("content is narrower than the dialog, leaving room for the scroll bars", function()
  -- ScrollableContainer calls content wider than its viewport "scrollable
  -- sideways" and draws a horizontal scroll bar; the vertical bar takes
  -- 3 * scroll_bar_width off the viewport. Content as wide as the dialog is
  -- always too wide by that.
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  assert(d.content_width < d.width, "content is as wide as the dialog (" .. d.content_width .. ")")
  assert(d.width - d.content_width >= 18, "gutter is only " .. (d.width - d.content_width))
end)

print("\n== the cover ==")

check("the cover is requested by its url", function()
  local loader = fakeLoader()
  BookDetailDialog:new { detail = detail(FULL), image_loader = loader }
  assert(#loader.urls == 1 and loader.urls[1] == "http://img/cover.jpg", table.concat(loader.urls, ","))
end)

check("when the picture arrives it goes into the box", function()
  local loader = fakeLoader()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = loader }
  _G.FAKE_BB = { free = function() end }
  loader.deliver("http://img/cover.jpg", "IMAGEBYTES")
  assert(d.cover_bb == _G.FAKE_BB, "the picture was not kept")
  local filled = d.cover_cell[1]
  assert(filled.kind == "Center" and filled[1].kind == "Image", "the box was not filled")
  assert(filled[1].scale_factor == 0, "the picture is not fitted to the box")
  assert(filled[1].image_disposable == false, "the widget would free a buffer the dialog owns")
end)

check("closing stops the fetch and frees the picture", function()
  local loader, freed = fakeLoader(), false
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = loader }
  _G.FAKE_BB = { free = function() freed = true end }
  loader.deliver("http://img/cover.jpg", "IMAGEBYTES")
  d:onCloseWidget()
  assert(loader.halted, "the fetch was left running")
  assert(freed, "the picture's memory was not released")
  assert(d.cover_bb == nil)
end)

check("a picture that arrives after the dialog closed is ignored", function()
  local loader = fakeLoader()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = loader }
  d:onCloseWidget()
  local rendered = false
  _G.FAKE_BB = setmetatable({}, { __index = function() rendered = true end })
  loader.deliver("http://img/cover.jpg", "IMAGEBYTES")
  assert(d.cover_bb == nil, "kept a picture for a closed dialog")
end)

check("rebuilding the dialog drops the old picture and fetch", function()
  local loader, freed = fakeLoader(), false
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = loader }
  _G.FAKE_BB = { free = function() freed = true end }
  loader.deliver("http://img/cover.jpg", "IMAGEBYTES")
  d:setDetail(detail({ title = "Other" }))
  assert(loader.halted and freed, "the old cover was left behind")
end)

print("\n== text that must fit ==")

check("single-line text is limited with max_width, the field TextWidget reads", function()
  local d = BookDetailDialog:new { detail = detail({ title = "T", rating = 4, users_count = 10 }) }
  assert(d.status_text.max_width == d.content_width, "status max_width " .. tostring(d.status_text.max_width))
  assert(d.community_text.max_width == d.content_width, "community max_width " .. tostring(d.community_text.max_width))
  local loading = BookDetailDialog:new { loading = true }
  assert(loading.loading_text.max_width == loading.width, "loading text is not limited")
end)

check("detail labels sit in a fixed-width column and values wrap", function()
  local d = BookDetailDialog:new { detail = detail({ title = "T", publisher = { name = "Harper" }, isbn_13 = "123" }) }
  local want = math.floor(d.content_width * 0.32)
  assert(#d.meta_rows == 2, "rows: " .. #d.meta_rows)
  for _, row in ipairs(d.meta_rows) do
    assert(row[1].kind == "Left" and row[1].dimen.w == want, "label column is not fixed")
    assert(row[3].kind == "TextBox", "value does not wrap")
  end
end)

check("the description is not clipped to a fixed height", function()
  local d = BookDetailDialog:new { detail = detail({ title = "T", description = string.rep("word ", 2000) }) }
  assert(d.description_text.height == nil, "height = " .. tostring(d.description_text.height))
end)

print("\n== what the header says ==")

check("every line is a finished string", function()
  local sum = Shelf.detailSummary(detail(FULL))
  assert(sum.title == "The Dispossessed" and sum.subtitle == "An Ambiguous Utopia")
  assert(sum.authors == "Ursula K. Le Guin", tostring(sum.authors))
  assert(sum.series == "Hainish Cycle #1", tostring(sum.series))
  assert(sum.facts == "1974 \194\183 387 pages", tostring(sum.facts))
  assert(sum.mine == "Currently Reading \194\183 Your rating 4", tostring(sum.mine))
  assert(sum.community == "Community 4.3 (12,345 ratings) \194\183 56,789 readers", tostring(sum.community))
  assert(sum.cover and sum.cover.url == "http://img/cover.jpg")
end)

check("a field the book lacks is nil, never an empty string", function()
  local sum = Shelf.detailSummary({ book = { title = "T", subtitle = "", description = "", rating = 0, ratings_count = 0, users_count = 0, pages = 0 } })
  for _, key in ipairs({ "subtitle", "description", "authors", "series", "facts", "mine", "community", "cover" }) do
    assert(sum[key] == nil, key .. " = " .. tostring(sum[key]))
  end
end)

check("a half rating keeps its decimal, a whole one does not", function()
  assert(Shelf.detailSummary({ book = {}, status_id = 3, user_rating = 4.5 }).mine == "Read \194\183 Your rating 4.5")
  assert(Shelf.detailSummary({ book = {}, user_rating = 5 }).mine == "Your rating 5")
end)

check("a cover with no url is no cover", function()
  assert(Shelf.detailSummary({ book = { cached_image = { url = "" } } }).cover == nil)
  assert(Shelf.detailSummary({ book = { cached_image = "x" } }).cover == nil)
end)

check("an edition's release date beats the book's year", function()
  local sum = Shelf.detailSummary({ book = { release_year = 1999, release_date = "2005-06-01" } })
  assert(sum.facts == "2005", tostring(sum.facts))
end)

check("the detail rows leave out what the header already says", function()
  local labels = {}
  for _, row in ipairs(Shelf.extraRows(FULL)) do labels[#labels + 1] = row.label end
  local text = table.concat(labels, ",")
  assert(text:find("Publisher") and text:find("ISBN"), "lost a detail row: " .. text)
  for _, said in ipairs({ "Author", "Series", "Pages", "Published", "Community", "Readers", "Description" }) do
    assert(not text:find(said), said .. " is repeated in the details: " .. text)
  end
end)

print("\n== leaving the screen ==")

check("every key the dialog binds has a handler", function()
  local d = BookDetailDialog:new { detail = detail({ title = "T" }) }
  local count = 0
  for name in pairs(d.key_events) do
    count = count + 1
    assert(type(BookDetailDialog["on" .. name]) == "function", "key event " .. name .. " has no handler (on" .. name .. ")")
  end
  assert(count > 0 and d.key_events.CloseDetail, "Back is not bound")
end)

check("Back works on the loading screen too", function()
  local d = BookDetailDialog:new { loading = true }
  assert(d.key_events.CloseDetail, "no Back binding while loading")
end)

print("\n== the numbers shown ==")

check("a rating of zero is not shown as a community rating", function()
  local rows = Shelf.detailRows({ title = "T", rating = 0, ratings_count = 0 })
  for _, row in ipairs(rows) do assert(row.label ~= "Community rating", "shown: " .. tostring(row.value)) end
  local rated = Shelf.detailRows({ title = "T", rating = 4.2, ratings_count = 10 })
  local found = false
  for _, row in ipairs(rated) do if row.label == "Community rating" then found = true end end
  assert(found, "a real rating disappeared")
end)

print("\n== the query behind it ==")

local captured
Api.query = function(_, q, vars)
  captured = { q = q, vars = vars }
  if vars.editionId then
    return { editions = { { id = vars.editionId, edition_format = "Hardcover", pages = 300,
      book = { book_id = 7, title = "T" } } } }
  end
  return { books = { { book_id = 7, title = "T" } } }
end

check("a linked edition is looked up by its own id", function()
  captured = nil
  local result = Api:getBookDetail(7, 1, 555)
  assert(result and result.book.title == "T", "no detail came back")
  assert(captured.vars.editionId == 555, "editionId sent: " .. tostring(captured.vars.editionId))
  assert(captured.vars.bookId == nil, "the book id was sent for an edition query")
  assert(captured.q:find("$editionId", 1, true), "the query never uses $editionId")
  assert(not captured.q:find("$bookId", 1, true), "the query still declares an unused $bookId")
end)

check("with no edition, the book id is used", function()
  captured = nil
  local result = Api:getBookDetail(7, 1, nil)
  assert(result and result.book.title == "T")
  assert(captured.vars.bookId == 7 and captured.vars.editionId == nil)
end)

r.finish()
