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
  ["ui/widget/button"] = (function()
    local B = widget("Button")
    function B:enable() self.enabled = true end
    function B:disable() self.enabled = false end
    return B
  end)(),
  -- the real one is an InputContainer; here a tap is just its callback
  ["hardcover/lib/ui/tap_row"] = widget("TapRow"),
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
local Theme = real_require("hardcover/lib/ui/theme")
local Shelf = real_require("hardcover/lib/shelf")
local Api = real_require("hardcover/lib/hardcover_api")

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local function kinds(group)
  local out = {}
  for _, child in ipairs(group) do out[#out + 1] = type(child.kind) == "string" and child.kind or "?" end
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
  local loader = { urls = {}, halted = false, batches = {} }
  function loader:loadImages(urls, callback, opts)
    self.batches[#self.batches + 1] = { urls = urls, callback = callback, opts = opts }
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
  assert(d.status_text, "status pill missing")
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
  assert(d.authors_text and d.series_text and d.facts_text and d.stats_strip, "header lines missing")
  local bare = BookDetailDialog:new { detail = { book = { title = "T" } } }
  assert(bare.authors_text == nil and bare.series_text == nil and bare.facts_text == nil
    and bare.status_text == nil and bare.description_text == nil,
    "invented a line for a field the book does not have")
  assert(#bare.meta_rows == 0, "invented detail rows")
end)

check("the stat strip is always three figures; an unknown one is a dash, not a zero", function()
  local stats = Shelf.detailStats(detail(FULL))
  assert(#stats == 3)
  assert(stats[1][1] == "4.3" and stats[1][2] == "12,345 ratings", stats[1][1] .. " / " .. stats[1][2])
  assert(stats[2][1] == "56,789" and stats[2][2] == "readers")
  assert(stats[3][1] == "4" and stats[3][2] == "your rating")
  local none = Shelf.detailStats({ book = { rating = 0, users_count = 0 } })
  assert(#none == 3 and none[1][1] == "\226\128\147" and none[2][1] == "\226\128\147" and none[3][1] == "\226\128\147")
  assert(Shelf.detailStats({ book = { rating = 4, ratings_count = 1, users_count = 1 }, user_rating = 3.5 })[3][1] == "3.5")
  assert(#Shelf.detailStats(nil) == 3)
end)

print("\n== the header ==")

check("the title is bold and wraps", function()
  local d = BookDetailDialog:new { detail = detail({ title = string.rep("Long ", 40) }) }
  -- the title is set in the serif display face; bold is asked for only when that face
  -- is not already a real bold (Theme.serif says which)
  local _, serif_bold = Theme.serif("display")
  assert(d.title_text.kind == "TextBox" and d.title_text.bold == serif_bold)
  local cover_w = math.floor(d.content_width * 0.34)
  assert(d.title_text.width == d.content_width - cover_w - 2 * Theme.line.hair - Theme.space.l,
    "title width " .. tostring(d.title_text.width))
end)

check("with a cover, the text sits beside it in the width that is left", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  assert(d.cover_cell, "no cover box")
  local cover_w = math.floor(d.content_width * 0.34)
  assert(d.title_text.width == d.content_width - cover_w - 2 * Theme.line.hair - Theme.space.l,
    "title width " .. tostring(d.title_text.width))
  assert(d.content_group[1].kind == "HGroup", "header is not cover-beside-text")
end)

check("the cover box has a fixed size, so the text does not move when the picture arrives", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  local box = d.cover_cell[1].dimen
  assert(box.w == math.floor(d.content_width * 0.34) and box.h == math.floor(box.w * 1.5), "box " .. box.w .. "x" .. box.h)
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

check("the cover is asked for at the size of its box: large, at exactly that box", function()
  local loader = fakeLoader()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = loader }
  local bw, bh = BookDetailDialog.coverBox(1000)
  local box = d.cover_cell[1].dimen
  assert(box.w == bw and box.h == bh, "the box " .. box.w .. "x" .. box.h .. " is not coverBox's " .. bw .. "x" .. bh)
  local opts = loader.batches[1].opts
  assert(opts and opts.size == "large", "not asked for the large size")
  assert(opts.box and opts.box.w == bw and opts.box.h == bh, "the request is not for the box it is drawn in")
end)

check("coverBox is the one size the header and the request both use, and it is 2:3", function()
  local bw, bh = BookDetailDialog.coverBox(1000)
  assert(bh == math.floor(bw * 1.5), bw .. "x" .. bh)
  local cw = BookDetailDialog.coverBox(600)
  assert(cw < bw, "a narrower screen gave a box that is not narrower")
end)

check("when the picture arrives it goes into the box", function()
  local loader = fakeLoader()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = loader }
  _G.FAKE_BB = { free = function() end }
  loader.deliver("http://img/cover.jpg", "IMAGEBYTES")
  assert(d.cover_bb == _G.FAKE_BB, "the picture was not kept")
  assert(d.dithered == true, "a page with a picture is not dithered")
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

-- the words of a pill: its first child, or (a pill with a chevron) the first child of its row
local function pillWords(pill)
  local first = pill[1]
  return first.text and first or first[1]
end

check("single-line text is limited with max_width, the field TextWidget reads", function()
  local d = BookDetailDialog:new { detail = detail({ title = "T", rating = 4, users_count = 10 }) }
  -- the pills' words are limited to the text column, so a long series name is cut
  assert(pillWords(d.status_text).max_width and pillWords(d.status_text).max_width < d.content_width,
    "status max_width " .. tostring(pillWords(d.status_text).max_width))
  local long = BookDetailDialog:new { detail = detail({ title = "T", book_series = { { position = 1, series = { name = string.rep("Series ", 30) } } } }) }
  assert(pillWords(long.series_text).max_width and pillWords(long.series_text).max_width < long.content_width, "a long series name is not limited")
  local loading = BookDetailDialog:new { loading = true }
  assert(loading.loading_text.max_width == loading.width - 2 * Theme.margin, "loading text is not limited")
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
  for _, key in ipairs({ "subtitle", "description", "authors", "series", "series_title", "first_author", "facts", "mine", "community", "cover" }) do
    assert(sum[key] == nil, key .. " = " .. tostring(sum[key]))
  end
end)

check("what a tap searches for: the bare series name and the first author", function()
  local book = { contributions = { { author = { name = "A. One" } }, { author = { name = "B. Two" } } },
    book_series = { { position = 4, series = { name = "Hainish Cycle" } } } }
  local sum = Shelf.detailSummary({ book = book })
  assert(sum.series == "Hainish Cycle #4" and sum.series_title == "Hainish Cycle", tostring(sum.series_title))
  assert(sum.authors == "A. One, B. Two" and sum.first_author == "A. One", tostring(sum.first_author))
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

check("the detail rows add the dates, audiobook length, credits and counts when the book has them", function()
  local rows = {}
  for _, row in ipairs(Shelf.extraRows({
    release_date = "2014-09-01", first_release_date = "1997-06-26", audio_seconds = 31288,
    contributions = { { contribution = "Author", author = { name = "A" } }, { contribution = "Illustrator", author = { name = "I" } },
      { contribution = "Illustrator", author = { name = "J" } }, { author = { name = "B" } } },
    reviews_count = 1, lists_count = 5076, editions_count = 539,
  })) do rows[row.label] = row.value end
  assert(rows["Edition released"] == "1 Sep 2014", tostring(rows["Edition released"]))
  assert(rows["First published"] == "26 Jun 1997", tostring(rows["First published"]))
  assert(rows.Audiobook == "8h 41m", tostring(rows.Audiobook))
  assert(rows.Illustrator == "I, J" and rows.Author == nil, "credits")
  assert(rows["Written reviews"] == "1 review" and rows["On lists"] == "5,076 lists" and rows.Editions == "539 editions",
    tostring(rows["Written reviews"]) .. " / " .. tostring(rows["On lists"]) .. " / " .. tostring(rows.Editions))
  -- nothing known adds nothing, and a year-only date is not a "released" day
  assert(#Shelf.extraRows({ release_date = "2014", first_release_date = "2014" }) == 0)
  assert(Shelf.extraRows({ audio_seconds = 20 })[1] == nil, "a few seconds is not a length")
end)

check("both detail queries (the book's and a linked edition's) ask for every field the details show", function()
  local sent = {}
  local Api = require("hardcover/lib/hardcover_api")
  Api.enabled = true
  Api.query = function(_, q) sent[#sent + 1] = q return nil end
  Api:getBookDetail(1, 2)
  Api:getBookDetail(1, 2, 3)
  assert(#sent == 2, "queries sent: " .. #sent)
  for i, q in ipairs(sent) do
    for _, field in ipairs({ "ratings_distribution", "cached_tags", "first_release_date: release_date", "reviews_count",
      "lists_count", "editions_count", "default_audio_edition", "contribution\n" }) do
      assert(q:find(field, 1, true), "query " .. i .. " does not ask for " .. field)
    end
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

check("every book is an item, the one on screen is marked, and your status shows", function()
  local card = Shelf.seriesCard(seriesOf(4, { is_completed = true }), 103)
  assert(card.title == "More in The Saga", card.title)
  assert(card.subtitle == "4 books \194\183 complete", card.subtitle)
  assert(#card.items == 4 and card.current_index == 3)
  assert(card.items[1].number == "#1" and card.items[1].title == "Book 1" and card.items[1].status == "Read")
  assert(card.items[3].current == true and card.items[3].status == nil, "the book on screen shows a status")
  assert(card.items[2].current == false and card.items[2].book_id == 102)
end)

check("a cover travels with its item", function()
  local series = seriesOf(2)
  series.books[1].cover = { url = "http://img/1.jpg" }
  local card = Shelf.seriesCard(series, 102)
  assert(card.items[1].cover.url == "http://img/1.jpg" and card.items[2].cover == nil)
end)

check("an ongoing series says so; an unknown one says nothing", function()
  assert(Shelf.seriesCard(seriesOf(3, { is_completed = false }), 101).subtitle:find("ongoing", 1, true))
  assert(Shelf.seriesCard(seriesOf(3), 101).subtitle == "3 books")
end)

check("a fractional position keeps its decimal", function()
  local series = { name = "S", books = { { book_id = 1, title = "A", position = 2.5 }, { book_id = 2, title = "B", position = 3 } } }
  assert(Shelf.seriesCard(series, 2).items[1].number == "#2.5", Shelf.seriesCard(series, 2).items[1].number)
end)

check("a book with no position still gets an item", function()
  local series = { name = "S", books = { { book_id = 1, title = "A" }, { book_id = 2, title = "B", position = 1 } } }
  assert(#Shelf.seriesCard(series, 2).items == 2)
end)

check("there is no card when there is nothing to link to", function()
  assert(Shelf.seriesCard(seriesOf(1), 101) == nil, "a card for a series of one")
  assert(Shelf.seriesCard({ name = "S", books = {} }, 1) == nil)
  assert(Shelf.seriesCard(nil, 1) == nil)
  assert(Shelf.seriesCard({ name = "S" }, 1) == nil)
end)

check("the strip opens on the page that holds the book on screen", function()
  local w = Shelf.carouselWindow(30, 4, nil, 15)
  assert(w.first <= 15 and w.last >= 15 and w.last - w.first == 3, w.first .. "-" .. w.last)
  assert(w.has_prev and w.has_next)
end)

check("the strip stays inside the series at either end", function()
  local a = Shelf.carouselWindow(30, 4, nil, 1)
  assert(a.first == 1 and a.last == 4 and not a.has_prev and a.has_next)
  local z = Shelf.carouselWindow(30, 4, nil, 30)
  assert(z.first == 27 and z.last == 30 and z.has_prev and not z.has_next)
  local over = Shelf.carouselWindow(30, 4, 99)
  assert(over.last == 30 and not over.has_next, "paging past the end")
  local under = Shelf.carouselWindow(30, 4, -5)
  assert(under.first == 1 and not under.has_prev, "paging before the start")
end)

check("a series that fits is one page with no arrows to show", function()
  local w = Shelf.carouselWindow(3, 4, nil, 2)
  assert(w.first == 1 and w.last == 3 and not w.has_prev and not w.has_next)
  local empty = Shelf.carouselWindow(0, 4)
  assert(empty.last == 0 and not empty.has_next)
end)

check("the series id is read from the book", function()
  assert(Shelf.seriesId({ book_series = { { position = 1, series = { id = 12, name = "S" } } } }) == 12)
  assert(Shelf.seriesId({ book_series = { { position = 1, series = { name = "S" } } } }) == nil, "invented an id")
  assert(Shelf.seriesId({ book_series = {} }) == nil and Shelf.seriesId({}) == nil and Shelf.seriesId(nil) == nil)
end)

check("the dialog shows the carousel, and tapping a cover opens that book", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  assert(d.series_card == nil and d.carousel == nil)
  local opened
  d:setSeries(Shelf.seriesCard(seriesOf(4), 102), function(id) opened = id end)
  assert(d.series_card and d.carousel, "the carousel was not built")
  assert(contains(d.content_group, d.carousel.widget), "the carousel is not in the page")
  -- the book on screen is not tappable; the other three are
  assert(#d.carousel.targets == 3, "targets: " .. #d.carousel.targets)
  d.carousel.targets[1].callback()
  assert(opened == 101, "opened " .. tostring(opened))
  d.carousel.targets[2].callback()
  assert(opened == 103, "opened " .. tostring(opened))
end)

check("a series that fits needs no arrows; a long one has them", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  d:setSeries(Shelf.seriesCard(seriesOf(3), 102), function() end)
  assert(d.carousel.paged == false and #d.layout == 2, "layout rows: " .. #d.layout)
  d:setSeries(Shelf.seriesCard(seriesOf(30), 115), function() end)
  assert(d.carousel.paged and d.carousel.prev and d.carousel.next)
end)

check("the arrows turn the page, and cannot go past either end", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  d:setSeries(Shelf.seriesCard(seriesOf(30), 101), function() end)
  local c = d.carousel
  assert(c.first == 1)
  c:turn(1)
  assert(c.first == 1 + c.per_page, "first " .. c.first)
  c:turn(-1)
  assert(c.first == 1)
  c:turn(-1)
  assert(c.first == 1, "went before the start")
  for _ = 1, 20 do c:turn(1) end
  assert(c.last == 30, "last " .. c.last)
end)

check("focus order: the action bar, then the arrows, then Close", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  d:setSeries(Shelf.seriesCard(seriesOf(30), 115), function() end)
  assert(#d.layout == 3, "layout rows: " .. #d.layout)
  assert(d.layout[1][1] == d.shelf_button, "the action bar is not first")
  assert(d.layout[2][1] == d.carousel.prev and d.layout[2][2] == d.carousel.next)
  local last = d.layout[#d.layout]
  assert(last[1] == d.close_button and #last == 1, "Close is not last")
end)

check("covers are fetched for the page on screen, and a stale answer is dropped", function()
  local loader = fakeLoader()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = loader }
  local series = seriesOf(30)
  for i, b in ipairs(series.books) do b.cover = { url = "http://img/" .. i .. ".jpg" } end
  d:setSeries(Shelf.seriesCard(series, 101), function() end)
  local requested = #loader.urls
  -- the carousel's own batch (the header's cover is another)
  local stale_deliver
  for _, batch in ipairs(loader.batches) do
    if #batch.urls > 1 then stale_deliver = batch.callback end
  end
  assert(stale_deliver, "the carousel asked for no covers")
  local old_box = d.carousel.boxes[1].box
  d.carousel:turn(1)
  assert(loader.halted, "the old page's request was not stopped")
  assert(#loader.urls > requested, "no covers were requested for the new page")
  _G.FAKE_BB = _G.FAKE_BB or {}
  stale_deliver("http://img/1.jpg", "bytes")
  assert(old_box.bb == nil, "a cover for the page that was turned away drew into a freed box")
end)

check("a series cover that arrives makes the page dithered; turning a page with no picture does not", function()
  local function strip_dialog()
    local loader = fakeLoader()
    local d = BookDetailDialog:new { detail = detail(FULL), image_loader = loader }
    local series = seriesOf(30)
    for i, b in ipairs(series.books) do b.cover = { url = "http://img/" .. i .. ".jpg" } end
    d:setSeries(Shelf.seriesCard(series, 101), function() end)
    return d, loader
  end

  -- the page is turned before any cover arrives: placeholders only, nothing dithered
  local turned = strip_dialog()
  turned.carousel:turn(1)
  assert(turned.dithered == nil, "turning a page with no picture dithered the page")

  -- a cover arriving on the strip: its box is refreshed dithered, and so is the page
  local d, loader = strip_dialog()
  local deliver
  for _, batch in ipairs(loader.batches) do
    if #batch.urls > 1 then deliver = batch.callback end
  end
  assert(deliver, "the carousel asked for no covers")
  deliver("http://img/2.jpg", "bytes")
  assert(d.dithered == true, "a cover on the strip did not dither the page")
end)

check("clearing the card removes it", function()
  local d = BookDetailDialog:new { detail = detail(FULL), image_loader = fakeLoader() }
  d:setSeries(Shelf.seriesCard(seriesOf(4), 102), function() end)
  d:setSeries(nil)
  assert(d.series_card == nil and d.carousel == nil)
end)

check("a tap range is the widget's rectangle cut to what the scroll area shows", function()
  local Viewport = real_require("hardcover/lib/ui/viewport")
  local a, b = { x = 0, y = 0, w = 100, h = 100 }, { x = 50, y = 80, w = 100, h = 100 }
  local o = Viewport.intersect(a, b)
  assert(o.x == 50 and o.y == 80 and o.w == 50 and o.h == 20)
  assert(Viewport.intersect(a, { x = 0, y = 100, w = 10, h = 10 }) == nil, "touching edges overlap")
  assert(Viewport.intersect(a, { x = 500, y = 500, w = 10, h = 10 }) == nil)
  assert(Viewport.intersect(a, {}) == nil and Viewport.intersect(nil, a) == nil, "unpositioned widgets overlap")
end)

check("a widget scrolled out of view has no tap range at all", function()
  local Viewport = real_require("hardcover/lib/ui/viewport")
  local scroll_area = { x = 0, y = 0, w = 100, h = 100 }
  local dimen = { x = 0, y = 150, w = 100, h = 50 }
  local range = Viewport.range(function() return dimen end, function() return scroll_area end)
  assert(range() == nil, "an off-screen widget would take taps meant for the buttons below")
  dimen.y = 90
  local r = range()
  assert(r and r.h == 10, "a half-visible widget keeps only the visible part")
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

check("Reviews: an action bar button that calls back, and none without a callback", function()
  local opened = 0
  local d = BookDetailDialog:new {
    detail = detail({ title = "T", description = "About it." }),
    on_reviews = function() opened = opened + 1 end,
  }
  assert(d.reviews_button, "no Reviews button")
  assert(d.reviews_button.text == "Reviews")
  -- in the action bar, between the header and About (the buttons sit in a row)
  local pos = {}
  for i, child in ipairs(d.content_group) do
    if child == d.description_text then pos.about = i end
    if child == d.reviews_button or contains(child, d.reviews_button) then pos.button = i end
  end
  assert(pos.button, "the button is not in the page")
  assert(pos.about and pos.button < pos.about, "the action bar is not above About")
  d.reviews_button.callback()
  assert(opened == 1, "tapping it did not open the reviews")
  local none = BookDetailDialog:new { detail = detail({ title = "T" }) }
  assert(none.reviews_button == nil, "a Reviews button with nothing to open")
  -- still there after the series arrives and the body is rebuilt
  d:setSeries(nil, nil)
  assert(d.reviews_button, "the rebuild lost the button")
end)

check("Similar to T: a strip of covers above the series, tapping one opens that book", function()
  local opened = {}
  local d = BookDetailDialog:new { detail = detail({ title = "T", description = "About it." }) }
  assert(d.similar_card == nil and d.similar_carousel == nil)
  local card = { title = "Similar to T", subtitle = "6 books", items = {} }
  for i = 1, 6 do card.items[i] = { book_id = 100 + i, number = "Author " .. i, title = "Book " .. i, current = false } end
  d:setSimilar(card, function(id) opened[#opened + 1] = id end)
  assert(d.similar_carousel and contains(d.content_group, d.similar_carousel.widget), "the strip is not in the page")
  d.similar_carousel.targets[1].callback()
  d.similar_carousel.targets[2].callback()
  assert(opened[1] == 101 and opened[2] == 102, "tapping a cover did not open that book")
  assert(d.similar_carousel.paged and #d.layout >= 3, "the arrows are not in the focus layout")
  -- with the series too, the series is first and both are in the page
  d:setSeries(card, function() end)
  assert(d.carousel and d.similar_carousel)
  local at = {}
  for i, child in ipairs(d.content_group) do
    if child == d.similar_carousel.widget then at.similar = i end
    if child == d.carousel.widget then at.series = i end
    if child == d.description_text then at.about = i end
  end
  assert(at.about < at.series and at.series < at.similar, "wrong order of About, series, similar")
  d:releaseCover()
  assert(d.similar_carousel == nil and d.carousel == nil, "releasing left a strip")
  d:setSimilar(nil, nil)
  assert(d.similar_carousel == nil, "clearing left the strip")
end)

check("On device: an action bar button that calls back with the dialog, and none without a callback", function()
  local got
  local d = BookDetailDialog:new {
    detail = detail({ title = "T" }), on_reviews = function() end, on_find = function(dialog) got = dialog end,
  }
  assert(d.find_button and d.find_button.text == "On device", "no On device button")
  d.find_button.callback()
  assert(got == d, "tapping it did not search")
  assert(BookDetailDialog:new { detail = detail({ title = "T" }), on_reviews = function() end }.find_button == nil)
  d:setSeries(nil, nil)
  assert(d.find_button, "the rebuild lost the button")
  -- the fullest bar: Shelf, Lists, Reviews, On device, Z-library
  local all = BookDetailDialog:new {
    detail = detail(FULL), on_lists = function() end, on_reviews = function() end,
    on_find = function() end, on_zlibrary = function() end,
  }
  local used = 0
  for _, b in ipairs({ all.shelf_button, all.lists_button, all.reviews_button, all.find_button, all.zlibrary_button }) do
    assert(b, "a button is missing from the full bar")
    used = used + b.width
  end
  assert(used < all.content_width, "five buttons do not fit one row")
end)

print("\n== the Z-library button ==")

check("there is a Z-library button only when there is something to hand the search to", function()
  local none = BookDetailDialog:new { detail = detail({ title = "T", description = "About it." }) }
  assert(none.zlibrary_button == nil, "a button that would do nothing")
  local got
  local d = BookDetailDialog:new {
    detail = detail({ title = "T", description = "About it." }),
    on_zlibrary = function(dialog) got = dialog end,
  }
  assert(d.zlibrary_button and d.zlibrary_button.text == "Z-library")
  assert(contains(d.content_group, d.zlibrary_button) == false, "the button should sit in a row, not loose in the page")
  d.zlibrary_button.callback()
  assert(got == d, "the handler was not given the dialog")
end)

check("it shares a row with Reviews, and both survive a rebuild", function()
  local d = BookDetailDialog:new {
    detail = detail(FULL), on_reviews = function() end, on_zlibrary = function() end,
  }
  assert(d.reviews_button and d.zlibrary_button)
  assert(d.reviews_button.width + d.zlibrary_button.width < d.content_width, "the two buttons do not fit one row")
  d:setSeries(nil, nil)
  assert(d.reviews_button and d.zlibrary_button, "the rebuild lost a button")
end)

print("\n== the shelf button ==")

check("Shelf is the filled first button of the action bar; Close is the title bar's X", function()
  local d = BookDetailDialog:new { detail = detail(FULL), on_reviews = function() end, on_zlibrary = function() end }
  assert(d.shelf_button and d.close_button and d.shelf_button ~= d.close_button)
  assert(contains(d.action_bar, d.shelf_button) and d.action_bar[1] == d.shelf_button, "Shelf is not first in the bar")
  assert(contains(d.content_group, d.action_bar), "the bar is not in the page")
  assert(d.close_button and d.title_bar, "Close is not the title bar's close button")
end)

check("the action bar adapts: one button, two, or three, filling the width exactly", function()
  local function widths(d)
    local total, n = 0, 0
    for _, child in ipairs(d.action_bar) do
      if child.kind == "TapRow" then n = n + 1; total = total + child.width end
    end
    return n, total
  end
  local one = BookDetailDialog:new { detail = detail(FULL) }
  local two = BookDetailDialog:new { detail = detail(FULL), on_reviews = function() end }
  local three = BookDetailDialog:new { detail = detail(FULL), on_reviews = function() end, on_zlibrary = function() end }
  for want, d in ipairs({ one, two, three }) do
    local n, total = widths(d)
    assert(n == want, want .. " buttons expected, got " .. n)
    assert(total <= d.content_width and d.content_width - total <= (want - 1) * Theme.space.s + want,
      "the bar does not fill the width: " .. total .. " of " .. d.content_width)
  end
end)

check("its label says where the book is, or invites adding it", function()
  assert(BookDetailDialog:new { detail = detail(FULL) }.shelf_button.text == "Shelf: Currently Reading")
  local bare = BookDetailDialog:new { detail = { book = FULL } }
  assert(bare.shelf_button.text == "Add to shelf", bare.shelf_button.text)
end)

check("tapping it calls the owner's handler with the dialog", function()
  local got
  local d = BookDetailDialog:new { detail = detail(FULL), on_shelf = function(x) got = x end }
  d.shelf_button.callback()
  assert(got == d)
  BookDetailDialog:new { detail = detail(FULL) }.shelf_button.callback() -- no handler: no error
end)

check("setStatus updates the status line and label, and keeps the cover", function()
  local loader = fakeLoader()
  local d = BookDetailDialog:new { detail = { book = FULL }, image_loader = loader }
  assert(d.status_text == nil)
  local fetches = #loader.batches
  local picture = { fake = true }
  d.cover_bb = picture
  d:setStatus(1, 55)
  assert(d.shelf_button.text == "Shelf: Want to Read", d.shelf_button.text)
  assert(d.status_text and pillWords(d.status_text).text == "Want to Read", "status pill missing")
  assert(d.detail.user_book_id == 55 and d.detail.status_id == 1)
  assert(d.cover_bb == picture, "the cover was thrown away")
  assert(#loader.batches == fetches, "the cover was fetched again")
  d:setStatus(3, 55)
  assert(pillWords(d.status_text).text == "Read" and d.shelf_button.text == "Shelf: Read")
end)

check("setStatus(nil) after a removal clears status, rating and the record", function()
  local d = BookDetailDialog:new { detail = { book = FULL, status_id = 3, user_book_id = 9, user_rating = 4 } }
  d:setStatus(nil, nil)
  assert(d.shelf_button.text == "Add to shelf" and d.status_text == nil, "label or status line kept")
  assert(d.detail.user_book_id == nil and d.detail.user_rating == nil)
end)

r.finish()
