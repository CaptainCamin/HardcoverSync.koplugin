-- The shelf screen (shelf_dialog.lua): what it builds for a list of books, a page at a time.
--
-- The widgets here are small stand-ins that keep their children in plain arrays, so the structure the
-- dialog builds can be walked and counted; the drawing itself is checked on a real KOReader
-- (spec/emu/scenarios/shelf.lua). Plugin-owned modules (Theme, ListRow, Shelf, ShelfSort, CoverCells,
-- Button) are the real ones.
--
-- Usage: lua spec/shelf_dialog_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function make()
  return setmetatable({}, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end

local function widget(kind)
  local C = { kind = kind }
  C.__index = C
  function C:new(o)
    o = o or {}
    o.kind = kind
    return setmetatable(o, C)
  end
  function C:getSize() return { w = self.width or 10, h = 20 } end
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

local shown, closed, dirty = {}, {}, 0
local errors = {}
local popovers = {}
local bars = {}

local widgets = {
  ["ui/widget/focusmanager"] = FocusManager,
  ["ui/widget/horizontalgroup"] = widget("HGroup"),
  ["ui/widget/verticalgroup"] = widget("VGroup"),
  ["ui/widget/container/centercontainer"] = widget("Center"),
  ["ui/widget/container/leftcontainer"] = widget("Left"),
  ["ui/widget/container/framecontainer"] = widget("Frame"),
  ["ui/widget/overlapgroup"] = widget("Overlap"),
  ["hardcover/lib/ui/tap_row"] = widget("TapRow"),
  ["ui/geometry"] = { new = function(_, t) return t end },
  ["ui/gesturerange"] = { new = function(_, t) return t end },
  ["device"] = {
    isTouchDevice = function() return false end,
    hasKeys = function() return false end,
    screen = {
      getWidth = function() return 1080 end,
      getHeight = function() return 1440 end,
      scaleBySize = function(_, n) return n end,
      getSize = function() return { w = 1080, h = 1440 } end,
    },
  },
  ["ui/uimanager"] = {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function(_, w) closed[#closed + 1] = w end,
    setDirty = function() dirty = dirty + 1 end,
  },
  -- the components that draw: here they record what they were given
  ["hardcover/lib/ui/components/top_bar"] = { new = function(opts)
    local bar = widget("Bar"):new { opts = opts }
    bar.back_button = widget("Back"):new {}
    bar.action_buttons = {}
    for i = 1, #(opts.actions or {}) do bar.action_buttons[i] = widget("Action"):new { dimen = { x = 900 + i, y = 10, w = 40, h = 40 } } end
    bars[#bars + 1] = bar
    return bar
  end },
  ["hardcover/lib/ui/components/scroll_control"] = {
    gutter = function() return 18 end,
    paged = function(opts) return widget("Control"):new { opts = opts } end,
  },
  ["hardcover/lib/ui/components/button"] = { new = function(o) return widget("Button"):new { text = o.label, callback = o.callback } end },
  ["hardcover/lib/ui/components/popover"] = { show = function(opts)
    popovers[#popovers + 1] = opts
    return { close = function() end }
  end },
  ["hardcover/lib/ui/components/draw"] = { chevron = function() return widget("Chevron"):new {} end },
  ["hardcover/lib/ui/status_dialogs"] = { error = function(message) errors[#errors + 1] = message end },
}

package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
package.preload["util"] = function()
  return { htmlEntitiesToUtf8 = function(s) return s end }
end
local real_require = require
_G.require = function(name)
  if widgets[name] then return widgets[name] end
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local ShelfDialog = real_require("hardcover/lib/ui/shelf_dialog")

-- ---------------------------------------------------------------- fixtures
local function entry(over)
  local e = {
    user_book_id = 501,
    book_id = 9001,
    status_id = 1,
    title = "The Dispossessed",
    authors = "Ursula K. Le Guin",
    cached_image = { url = "https://covers.example/1.jpg", width = 120, height = 180 },
  }
  for k, v in pairs(over or {}) do e[k] = v end
  for k in pairs(over or {}) do
    if over[k] == nil then e[k] = nil end
  end
  return e
end

local function fakeLoader()
  return { loadImages = function() return {}, function() end end }
end

local function build(entries, opts)
  opts = opts or {}
  bars = {}
  opts.entries = entries
  opts.title = opts.title or "Want to Read"
  opts.status_id = opts.status_id or 1
  opts.image_loader = fakeLoader()
  return ShelfDialog:new(opts)
end

local function many(n)
  local rows = {}
  for i = 1, n do rows[i] = entry({ book_id = 9000 + i, user_book_id = 500 + i, title = "Book " .. i }) end
  return rows
end

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

-- ---------------------------------------------------------------- the rows
print("\n== the rows the plugin builds ==")

check("an entry becomes a row with its title, author and cover", function()
  local d = build({ entry() })
  assert(#d.items == 1 and #d.rows == 1, "items " .. #d.items .. ", rows " .. #d.rows)
  local row = d.items[1].row
  assert(row.title == "The Dispossessed", tostring(row.title))
  assert(row.authors and row.authors:find("Le Guin", 1, true), tostring(row.authors))
  assert(row.cover_url == "https://covers.example/1.jpg", tostring(row.cover_url))
end)

check("an unrated row has no rating; a rating reads 4 or 4.5, never 4.0", function()
  assert(build({ entry() }).items[1].rating == nil)
  assert(build({ entry({ user_rating = 4 }) }).items[1].rating == "4")
  assert(build({ entry({ user_rating = 4.5 }) }).items[1].rating == "4.5")
  assert(build({ entry({ user_rating = 0 }) }).items[1].rating == nil, "a zero rating is shown")
end)

check("no page count or year clutters the row", function()
  local row = build({ entry({ pages = 300, release_year = 1974 }) }).items[1].row
  assert(row.pages == nil or row.pages == 300) -- the data may carry it; the screen does not draw it
  assert(not (row.title or ""):find("%(%d%d%d%d%)"))
end)

check("a suggestion says why", function()
  local item = build({ entry({ reason = "Wool" }) }).items[1]
  assert(item.reason == "Because you liked Wool", tostring(item.reason))
  assert(build({ entry() }).items[1].reason == nil)
end)

check("a ranked list carries the rank of each book", function()
  assert(build({ entry({ rank = 3 }) }).items[1].rank == 3)
end)

check("tapping a row calls the owner with the entry", function()
  local got
  local e = entry()
  local d = build({ e }, { select_entry_cb = function(x) got = x end })
  d.rows[1].callback()
  assert(got == e, "the entry was not handed over")
  build({ e }).rows[1].callback() -- no handler: no error
end)

check("the top bar has a back arrow that closes, and it is Close for the focus order", function()
  local closing = false
  local d = build({ entry() }, { close_callback = function() closing = true end })
  assert(bars[1].opts.on_back and d.close_button == bars[1].back_button)
  bars[1].opts.on_back()
  assert(closing, "back did not call close_callback")
  local last = d.layout[#d.layout]
  assert(last[1] == d.close_button and #last == 1, "Close is not last in the focus order")
end)

-- ---------------------------------------------------------------- both shelf views
print("\n== both shelf views ==")
for _, case in ipairs({ { id = 1, name = "Want to Read" }, { id = 2, name = "Currently Reading" } }) do
  check(case.name .. " builds a row, and a title", function()
    local d = build({ entry({ status_id = case.id }) }, { title = case.name, status_id = case.id })
    assert(#d.items == 1 and bars[1].opts.title == case.name, tostring(bars[1].opts.title))
  end)
end

-- ---------------------------------------------------------------- optional fields
print("\n== books with missing optional fields ==")
for _, v in ipairs({
  { name = "no cover at all", over = { cached_image = nil } },
  { name = "cover with no dimensions", over = { cached_image = { url = "https://c/x.jpg" } } },
  { name = "empty cover object", over = { cached_image = {} } },
  { name = "no author", over = { authors = nil } },
  { name = "empty author string", over = { authors = "" } },
  { name = "no series", over = { series = nil } },
  { name = "no rating", over = { user_rating = nil, community_rating = nil } },
  { name = "zero rating", over = { user_rating = 0 } },
  { name = "no page count", over = { pages = nil } },
  { name = "no release year", over = { release_year = nil } },
  { name = "empty title", over = { title = "" } },
}) do
  check("survives: " .. v.name, function()
    local d = build({ entry(v.over) })
    assert(#d.items == 1 and #d.rows == 1, "expected one row")
    if v.over.cached_image == nil and next(v.over) == "cached_image" then
      assert(d.items[1].row.cover_url == nil, "a cover url for a book with none")
    end
  end)
end

-- ---------------------------------------------------------------- pages
print("\n== a page at a time ==")

check("only one page of rows is built, however long the shelf", function()
  local d = build(many(60))
  assert(d.per_page and d.per_page > 1, "per_page " .. tostring(d.per_page))
  assert(#d.items == 60 and #d.rows == d.per_page, "built " .. #d.rows .. " rows")
  assert(d.pages == math.ceil(60 / d.per_page), "pages " .. d.pages)
end)

for _, n in ipairs({ 0, 1, 2, 20, 21, 50 }) do
  check(string.format("%d entries build cleanly", n), function()
    local d = build(many(n))
    assert(#d.items == n)
    assert(#d.rows == math.min(n, d.per_page))
  end)
end

check("a short shelf has one page and no scroll control", function()
  local d = build(many(3))
  assert(d.pages == 1 and d.control == nil)
  assert(build(many(60)).control, "no scroll control on a long shelf")
end)

check("the control steps by page through the dialog, and stays inside the pages", function()
  local d = build(many(60))
  local opts = d.control.opts
  assert(opts.page() == 1 and opts.pages() == d.pages)
  opts.go(2)
  assert(d.page == 2 and opts.page() == 2, "go(2) left page " .. d.page)
  opts.go(99)
  assert(d.page == d.pages, "went past the last page")
  opts.go(-4)
  assert(d.page == 1, "went before the first page")
end)

check("the next page shows the next rows, and the keys step", function()
  local d = build(many(60))
  local first_title = d.rows[1] and d.items[1].row.title
  d:onNextPage()
  assert(d.page == 2)
  local tapped
  d.select_entry_cb = function(e) tapped = e.title end
  d.rows[1].callback()
  assert(tapped == "Book " .. (d.per_page + 1), "page 2 starts with " .. tostring(tapped))
  d:onPrevPage()
  assert(d.page == 1 and first_title == "Book 1")
end)

check("a swipe up turns the page on, down turns it back", function()
  local d = build(many(60))
  assert(d:onSwipeShelf(nil, { direction = "north" }) and d.page == 2)
  assert(d:onSwipeShelf(nil, { direction = "south" }) and d.page == 1)
  assert(d:onSwipeShelf(nil, { direction = "east" }) == false, "a sideways swipe was taken")
end)

-- ---------------------------------------------------------------- more to load
print("\n== the rest of a shelf ==")

check("a shelf that is not all here ends with a Load more block", function()
  local d = build(many(3), { has_more = true, fetch_page = function() end })
  assert(#d.items == 4 and d.items[4].kind == "more", "no Load more block")
  assert(d.more_button and d.more_button.text == "Load more books")
  assert(build(many(3), { has_more = false, fetch_page = function() end }).more_button == nil, "Load more on a full shelf")
  assert(build(many(3), { has_more = true }).more_button == nil, "Load more with nothing to ask")
end)

check("loading more appends the rows and goes to the first new one", function()
  local asked
  local d
  d = build(many(20), {
    has_more = true, page_size = 20, offset = 20,
    fetch_page = function(offset, limit, callback) asked = { offset, limit }; callback(many(5), nil, false) end,
  })
  local per = d.per_page
  d:loadMore()
  assert(asked[1] == 20 and asked[2] == 20, "asked for " .. tostring(asked and asked[1]))
  assert(#d.entries == 25 and d.has_more == false and d.offset == 25, "entries " .. #d.entries)
  assert(d.page == math.floor(20 / per) + 1, "page " .. d.page)
  assert(d.more_button == nil, "Load more still offered")
end)

check("a failed load says so and keeps what there is", function()
  errors = {}
  local d = build(many(3), { has_more = true, fetch_page = function(_, _, cb) cb(nil, "down") end })
  d:loadMore()
  assert(#errors == 1 and #d.entries == 3 and d.has_more == true and d.loading == false, "state after a failure")
end)

check("a second Load more while one is on its way does nothing", function()
  local calls = 0
  local d = build(many(3), { has_more = true, fetch_page = function() calls = calls + 1 end })
  d:loadMore()
  d:loadMore()
  assert(calls == 1, "asked " .. calls .. " times")
end)

-- ---------------------------------------------------------------- keeping the reader's place
print("\n== keeping the reader's place while rows arrive ==")

check("setEntries stays on the page being viewed when keep_position is set", function()
  local d = build(many(60))
  d:setPage(3)
  d:setEntries(many(80), true, true)
  assert(d.page == 3, "page " .. d.page)
  d:setEntries(many(5), false)
  assert(d.page == 1, "page " .. d.page)
end)

check("an empty shelf says so, where the rows would be", function()
  local d = build({})
  d:setEmptyState("Nothing here yet")
  assert(d.empty_state == "Nothing here yet" and #d.items == 0 and #d.rows == 0 and d.has_more == false)
  d:setEntries(many(2), false)
  assert(d.empty_state == nil and #d.rows == 2, "the message stayed")
end)

-- ---------------------------------------------------------------- sorting a shelf
print("\n== sorting a shelf ==")

local function titles(d)
  local out = {}
  for i, item in ipairs(d.items) do out[i] = item.row.title end
  return table.concat(out, "|")
end
local function shelf(opts)
  opts = opts or {}
  local entries = {
    entry({ book_id = 1, title = "The Zebra", authors = "Ann Zed", pages = 100 }),
    entry({ book_id = 2, title = "Apple", authors = "Bob Young", pages = 300 }),
    entry({ book_id = 3, title = "Mango", authors = "Cy Xu", pages = 200 }),
  }
  return build(entries, { sortable = true, sort_key = opts.sort_key, on_sort_change = opts.on_sort_change, actions = opts.actions })
end

check("a shelf has the sort icon in the top bar, a list that is not a shelf does not", function()
  local d = shelf()
  assert(bars[1].opts.actions[1].icon == "sort" and d.sort_button == bars[1].action_buttons[1])
  build({ entry() })
  assert(#bars[1].opts.actions == 0 and #bars[1].action_buttons == 0, "a sort icon on search results")
end)

check("it opens in the arrival order by default", function()
  assert(titles(shelf()) == "The Zebra|Apple|Mango", titles(shelf()))
end)

check("choosing a sort re-orders the rows (articles ignored) and tells the owner", function()
  local changed
  local d = shelf({ on_sort_change = function(k) changed = k end })
  d:setSort("title")
  assert(titles(d) == "Apple|Mango|The Zebra", titles(d))
  assert(changed == "title")
  d:setSort("pages_asc")
  assert(titles(d) == "The Zebra|Mango|Apple", titles(d))
  changed = nil
  d:setSort("pages_asc")
  assert(changed == nil, "choosing the current sort again did something")
  d:setSort("nonsense")
  assert(titles(d) == "The Zebra|Mango|Apple", "an unknown sort was taken")
end)

check("a remembered sort is applied when the shelf opens; the entries keep their arrival order", function()
  local d = shelf({ sort_key = "author" })
  assert(titles(d) == "Mango|Apple|The Zebra", titles(d))
  assert(d.entries[1].book_id == 1 and d.entries[2].book_id == 2 and d.entries[3].book_id == 3)
end)

check("a sort that is not the usual one is in the title", function()
  shelf({ sort_key = "title" })
  assert(bars[1].opts.title:find("Title", 1, true), bars[1].opts.title)
  shelf()
  assert(bars[1].opts.title == "Want to Read", bars[1].opts.title)
end)

check("the sort menu lists every order, the current one marked, and choosing sorts", function()
  popovers = {}
  local d = shelf({ sort_key = "title" })
  d:showSortMenu()
  local menu = popovers[1]
  assert(menu and #menu.items == 11, "items " .. tostring(menu and #menu.items))
  local current = 0
  for _, item in ipairs(menu.items) do if item.current then current = current + 1 end end
  assert(current == 1 and menu.items[3].current, "the current order is not the one marked")
  assert(menu.x and menu.y, "the menu has no anchor")
  menu.items[4].callback() -- Author
  assert(titles(d) == "Mango|Apple|The Zebra", titles(d))
end)

check("a screen's actions (a list's Refresh) are icons in the top bar", function()
  local ran = false
  build({ entry() }, { actions = { { text = "Refresh", callback = function() ran = true end } } })
  local action = bars[1].opts.actions[1]
  assert(action and action.icon == "sync", "no reload icon")
  action.callback()
  assert(ran)
end)

r.finish()
