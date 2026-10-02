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
  ["ui/widget/iconwidget"] = widget("Icon"),
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
  local cover_w = math.floor(d.content_width * 0.30)
  assert(d.title_text.width == d.content_width - cover_w - 15, "title width " .. tostring(d.title_text.width))
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

check("no cover: a generic placeholder in the same box, and nothing is fetched", function()
  local loader = fakeLoader()
  local d = BookDetailDialog:new { detail = detail({ title = "T" }), image_loader = loader }
  assert(d.cover_cell, "no cover box")
  assert(#loader.urls == 0, "fetched a cover for a book that has none")
  local icon = d.cover_cell[1][1]
  assert(icon.kind == "Icon" and icon.icon == "book.opened", "the placeholder is not the book icon")
  assert(d.content_group[1].kind == "HGroup", "the header layout changed for a book with no cover")
end)

check("the placeholder is the same size as a real cover, so the layout is the same", function()
  local without = BookDetailDialog:new { detail = detail({ title = "T" }), image_loader = fakeLoader() }
  local with = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  assert(without.cover_cell[1].dimen.w == with.cover_cell[1].dimen.w
    and without.cover_cell[1].dimen.h == with.cover_cell[1].dimen.h, "box sizes differ")
  assert(without.title_text.width == with.title_text.width, "the text column moves with the cover")
end)

check("while a cover loads, the box shows the placeholder", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  assert(d.cover_cell[1][1].kind == "Icon", "the box is empty until the picture arrives")
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

print("\n== the series card ==")

local function seriesOf(n, opts)
  opts = opts or {}
  local books = {}
  for i = 1, n do
    books[i] = { book_id = 100 + i, title = "Book " .. i, position = i, status_id = (i == 1) and 3 or nil }
  end
  return { name = opts.name or "The Saga", is_completed = opts.is_completed, books = books }
end

check("every book is a row, the one on screen is marked, and your status shows", function()
  local card = Shelf.seriesCard(seriesOf(4, { is_completed = true }), 103)
  assert(card.title == "More in The Saga", card.title)
  assert(card.subtitle == "4 books \194\183 complete", card.subtitle)
  assert(#card.rows == 4)
  assert(card.rows[1].text == "#1  Book 1 \194\183 Read", card.rows[1].text)
  assert(card.rows[3].current == true and card.rows[3].text == "#3  Book 3 \194\183 this book", card.rows[3].text)
  assert(card.rows[2].current == false and card.rows[2].book_id == 102)
end)

check("an ongoing series says so; an unknown one says nothing", function()
  assert(Shelf.seriesCard(seriesOf(3, { is_completed = false }), 101).subtitle:find("ongoing", 1, true))
  assert(Shelf.seriesCard(seriesOf(3), 101).subtitle == "3 books")
end)

check("a fractional position keeps its decimal", function()
  local series = { name = "S", books = { { book_id = 1, title = "A", position = 2.5 }, { book_id = 2, title = "B", position = 3 } } }
  assert(Shelf.seriesCard(series, 2).rows[1].text:find("#2.5", 1, true), Shelf.seriesCard(series, 2).rows[1].text)
end)

check("a book with no position still gets a row", function()
  local series = { name = "S", books = { { book_id = 1, title = "A" }, { book_id = 2, title = "B", position = 1 } } }
  assert(#Shelf.seriesCard(series, 2).rows == 2)
end)

check("there is no card when there is nothing to link to", function()
  assert(Shelf.seriesCard(seriesOf(1), 101) == nil, "a card for a series of one")
  assert(Shelf.seriesCard({ name = "S", books = {} }, 1) == nil)
  assert(Shelf.seriesCard(nil, 1) == nil)
  assert(Shelf.seriesCard({ name = "S" }, 1) == nil)
end)

check("a long series is a window around the current book", function()
  local card = Shelf.seriesCard(seriesOf(30), 115, 10) -- book 115 is #15
  local books, gaps = 0, {}
  for _, row in ipairs(card.rows) do
    if row.gap then gaps[#gaps + 1] = row.text else books = books + 1 end
  end
  assert(books == 10, "showed " .. books .. " books")
  assert(#gaps == 2 and gaps[1]:find("earlier") and gaps[2]:find("more"), table.concat(gaps, ","))
  local has_current = false
  for _, row in ipairs(card.rows) do if row.current then has_current = true end end
  assert(has_current, "the current book fell out of its own window")
  assert(card.total == 30)
end)

check("the window stays inside the series at either end", function()
  local first = Shelf.seriesCard(seriesOf(30), 101, 10)
  assert(first.rows[1].gap == nil and first.rows[1].book_id == 101, "no gap before the first book")
  assert(first.rows[#first.rows].gap, "nothing marks the books left out after the window")
  local last = Shelf.seriesCard(seriesOf(30), 130, 10)
  assert(last.rows[1].gap and last.rows[#last.rows].book_id == 130, "the window ran past the end")
end)

check("the series id is read from the book", function()
  assert(Shelf.seriesId({ book_series = { { position = 1, series = { id = 12, name = "S" } } } }) == 12)
  assert(Shelf.seriesId({ book_series = { { position = 1, series = { name = "S" } } } }) == nil, "invented an id")
  assert(Shelf.seriesId({ book_series = {} }) == nil and Shelf.seriesId({}) == nil and Shelf.seriesId(nil) == nil)
end)

check("the dialog shows the card, and tapping a row opens that book", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  assert(d.series_card == nil and #d.series_buttons == 0)
  local opened
  d:setSeries(Shelf.seriesCard(seriesOf(4), 102), function(id) opened = id end)
  assert(d.series_card, "the card was not kept")
  -- the book on screen is not a button; the other three are
  assert(#d.series_buttons == 3, "buttons: " .. #d.series_buttons)
  d.series_buttons[1].callback()
  assert(opened == 101, "opened " .. tostring(opened))
  d.series_buttons[2].callback()
  assert(opened == 103, "opened " .. tostring(opened))
end)

check("the book on screen is not tappable", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  d:setSeries(Shelf.seriesCard(seriesOf(3), 102), function() end)
  for _, button in ipairs(d.series_buttons) do
    assert(button.enabled == true and not button.text:find("this book"), "the current book is a button")
  end
end)

check("the rows fit inside the dialog", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  d:setSeries(Shelf.seriesCard(seriesOf(3), 102), function() end)
  for _, button in ipairs(d.series_buttons) do
    assert(button.width <= d.content_width, "a row is wider than the content (" .. button.width .. ")")
  end
end)

check("the series rows come before Close in the focus order", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  d:setSeries(Shelf.seriesCard(seriesOf(4), 102), function() end)
  assert(#d.layout == 4, "layout rows: " .. #d.layout)
  assert(d.layout[#d.layout][1].kind == "Button" and d.layout[#d.layout][1].text == "Close", "Close is not last")
end)

check("clearing the card removes it", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  d:setSeries(Shelf.seriesCard(seriesOf(4), 102), function() end)
  d:setSeries(nil)
  assert(d.series_card == nil and #d.series_buttons == 0)
end)

check("adding the card keeps the cover (it is rebuilt, not lost)", function()
  local loader = fakeLoader()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = loader }
  d:setSeries(Shelf.seriesCard(seriesOf(4), 102), function() end)
  assert(d.cover_cell, "the cover box disappeared on rebuild")
  assert(#loader.urls == 2, "the cover is requested again on rebuild (from the cache): " .. #loader.urls)
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

check("the detail queries ask for the series id, so the rest of the series can be fetched", function()
  captured = nil
  Api:getBookDetail(7, 1, nil)
  assert(captured.q:match("series%s*{%s*id%s+name"), "the book query does not ask for series { id name }")
  Api:getBookDetail(7, 1, 555)
  assert(captured.q:match("series%s*{%s*id%s+name"), "the edition query does not ask for series { id name }")
end)

check("with no edition, the book id is used", function()
  captured = nil
  local result = Api:getBookDetail(7, 1, nil)
  assert(result and result.book.title == "T")
  assert(captured.vars.bookId == 7 and captured.vars.editionId == nil)
end)

print("\n== fetching a series ==")

local function answerSeries(results, err)
  Api.query = function(_, q, vars) captured = { q = q, vars = vars }; return results, err end
end

check("it follows Hardcover's recipe for a clean list", function()
  answerSeries({ series_by_pk = { id = 12, name = "S", is_completed = true, book_series = {} } })
  Api:getSeriesBooks(12, 1)
  local q = captured.q
  assert(captured.vars.seriesId == 12 and captured.vars.userId == 1)
  assert(q:find("canonical_id: { _is_null: true }", 1, true), "merged duplicates are not excluded")
  assert(q:find("is_partial_book: { _eq: false }", 1, true), "partial editions are not excluded")
  assert(q:find("compilation: { _eq: false }", 1, true), "compilations are not excluded")
  assert(q:find("distinct_on: position", 1, true), "more than one book per position")
  assert(q:find("order_by: [{ position: asc }, { book: { users_count: desc } }]", 1, true), "the wrong book wins a position")
end)

check("rows come back flat, with your own status on each", function()
  answerSeries({ series_by_pk = { id = 12, name = "Hainish Cycle", is_completed = true, book_series = {
    { position = 1, book = { book_id = 301, title = "Rocannon's World", release_year = 1966, user_books = { { status_id = 3, rating = 4 } } } },
    { position = 2, book = { book_id = 302, title = "Planet of Exile", user_books = {} } },
  } } })
  local series = Api:getSeriesBooks(12, 1)
  assert(series.name == "Hainish Cycle" and series.is_completed == true and #series.books == 2)
  assert(series.books[1].book_id == 301 and series.books[1].status_id == 3 and series.books[1].rating == 4)
  assert(series.books[2].status_id == nil, "invented a status for a book you have not shelved")
  assert(series.books[1].position == 1)
end)

check("a failed request returns nothing", function()
  answerSeries(nil, { completed = false })
  local series, err = Api:getSeriesBooks(12, 1)
  assert(series == nil and err ~= nil)
  answerSeries({ series_by_pk = nil })
  assert(Api:getSeriesBooks(99, 1) == nil, "a series that does not exist")
  assert(Api:getSeriesBooks(nil, 1) == nil)
end)

r.finish()
