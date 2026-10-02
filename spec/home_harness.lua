-- The home screen's data, its count query, its saved counts, and the wiring that
-- makes it launchable from outside the plugin.
--
-- Run with:  lua spec/home_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local function read(path)
  local f = assert(io.open(PLUGIN .. "/" .. path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local Home = require("hardcover/lib/home")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

print("\n== the rows ==")

check("the shelves come in a sensible order, reading first", function()
  local rows = Home.rows({})
  local ids = {}
  for i, row in ipairs(rows) do ids[i] = row.status_id end
  assert(table.concat(ids, ",") == table.concat({
    HARDCOVER.STATUS.READING, HARDCOVER.STATUS.TO_READ, HARDCOVER.STATUS.FINISHED, HARDCOVER.STATUS.DNF }, ","),
    "order: " .. table.concat(ids, ","))
end)

check("each row is named for its shelf", function()
  local rows = Home.rows({})
  assert(rows[1].title == "Currently Reading" and rows[2].title == "Want to Read", rows[1].title .. " / " .. rows[2].title)
end)

check("counts land on the right rows", function()
  local rows = Home.rows({ [HARDCOVER.STATUS.TO_READ] = 42, [HARDCOVER.STATUS.READING] = 3 })
  assert(rows[1].count == 3 and rows[2].count == 42)
end)

check("a shelf with no count has none, not zero", function()
  local rows = Home.rows({ [HARDCOVER.STATUS.READING] = 3 })
  assert(rows[2].count == nil, "invented a count: " .. tostring(rows[2].count))
  assert(Home.countText(rows[2].count) == "", "shows text for an unknown count")
end)

check("a real zero is shown as zero", function()
  assert(Home.countText(0) == "0")
  assert(Home.countText(1234) == "1234")
end)

check("no counts at all is fine", function()
  assert(#Home.rows(nil) == 4)
end)

print("\n== the count query ==")

package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
support.preload_ui_stubs()
support.preload_http_stubs()
support.preload_json(PLUGIN)
package.preload["ui/network/manager"] = function() return { isConnected = function() return true end } end
package.preload["ui/trapper"] = function() return { wrap = function(_, f) f() end } end
package.preload["ffi/util"] = function()
  local util = { template = function(t) return t end }
  setmetatable(util, { __call = function(_, s) return tostring(s) end })
  return util
end
package.preload["ffi"] = function() return {} end
package.preload["ffi/pointer"] = function() return {} end
package.preload["ffi/utf8"] = function() return { char = string.char, len = string.len } end
package.preload["blitbuffer"] = function() return {} end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end

local Api = require("hardcover/lib/hardcover_api")
local captured
local function answer(results, err)
  Api.query = function(_, q, vars) captured = { q = q, vars = vars }; return results, err end
end

check("one request counts every shelf", function()
  answer({ s2 = { aggregate = { count = 3 } }, s1 = { aggregate = { count = 42 } },
           s3 = { aggregate = { count = 120 } }, s5 = { aggregate = { count = 0 } } })
  local counts = Api:getShelfCounts(7, Home.statusIds())
  assert(counts[2] == 3 and counts[1] == 42 and counts[3] == 120, "counts wrong")
  assert(counts[5] == 0, "a real zero was lost")
  assert(captured.vars.userId == 7)
  for _, alias in ipairs({ "s1:", "s2:", "s3:", "s5:" }) do
    assert(captured.q:find(alias, 1, true), "no aggregate for " .. alias)
  end
end)

check("it stays within five top-level queries per request", function()
  answer({})
  assert(Api:getShelfCounts(7, { 1, 2, 3, 4, 5, 6 }) == nil, "asked for six at once")
  assert(Api:getShelfCounts(7, {}) == nil)
end)

check("a failed request returns nothing, not zeros", function()
  answer(nil, { completed = false })
  local counts, err = Api:getShelfCounts(7, Home.statusIds())
  assert(counts == nil and err ~= nil)
end)

check("a shelf the server did not report is left out", function()
  answer({ s2 = { aggregate = { count = 3 } } })
  local counts = Api:getShelfCounts(7, Home.statusIds())
  assert(counts[2] == 3 and counts[1] == nil, "invented a count")
end)

print("\n== saved counts ==")

local ShelfCache = require("hardcover/lib/shelf_cache")
local function newCache()
  local data, store = {}, { flushes = 0 }
  function store:readSetting(k) return data[k] end
  function store:saveSetting(k, v) data[k] = v end
  function store:flush() self.flushes = self.flushes + 1 end
  return ShelfCache:new { path = "/x", open = function() return store end }, store
end

check("saved counts come back", function()
  local c = newCache()
  assert(c:putCounts(1, { [1] = 42, [2] = 3 }))
  local counts = c:counts(1, { 1, 2, 3 })
  assert(counts[1] == 42 and counts[2] == 3 and counts[3] == nil)
end)

check("a fully loaded shelf stands in for a count", function()
  local c = newCache()
  c:put(1, 1, { { book_id = 1 }, { book_id = 2 } }, true)
  assert(c:counts(1, { 1 })[1] == 2)
end)

check("a partly loaded shelf is not a count", function()
  local c = newCache()
  c:put(1, 1, { { book_id = 1 } }, false)
  assert(c:counts(1, { 1 })[1] == nil, "a partial list was reported as the total")
end)

check("a saved count beats the length of a stale list", function()
  local c = newCache()
  c:put(1, 1, { { book_id = 1 } }, true)
  c:putCounts(1, { [1] = 50 })
  assert(c:counts(1, { 1 })[1] == 50)
end)

check("counts are per account and are cleared with the rest", function()
  local c = newCache()
  c:putCounts(1, { [1] = 42 })
  assert(c:counts(2, { 1 })[1] == nil, "another account saw these counts")
  c:clear()
  assert(c:counts(1, { 1 })[1] == nil, "sign out left counts behind")
end)

print("\n== the reading cards ==")

check("a card carries title, author, cover and progress", function()
  local cards = Home.cards({ {
    book_id = 9, title = "Nine", authors = "A. Writer", pages = 300, edition_pages = 250, progress_pages = 100,
    cached_image = { url = "https://x/9.jpg" },
  } })
  local c = cards[1]
  assert(c.book_id == 9 and c.title == "Nine" and c.author == "A. Writer" and c.cover_url == "https://x/9.jpg")
  assert(c.progress_text == "100 / 250", "text: " .. tostring(c.progress_text))
  assert(math.abs(c.fraction - 0.4) < 1e-9, "fraction: " .. tostring(c.fraction))
end)

check("the edition's pages win over the book's, and the book's stand in for them", function()
  assert(Home.cards({ { book_id = 1, pages = 200, progress_pages = 50 } })[1].total == 200)
  assert(Home.cards({ { book_id = 1, pages = 200, edition_pages = 100, progress_pages = 50 } })[1].total == 100)
end)

check("progress past the end is clamped to full, never beyond", function()
  local c = Home.cards({ { book_id = 1, edition_pages = 100, progress_pages = 250 } })[1]
  assert(c.fraction == 1, "fraction: " .. tostring(c.fraction))
end)

check("negative progress is clamped to empty", function()
  local c = Home.cards({ { book_id = 1, edition_pages = 100, progress_pages = -5 } })[1]
  assert(c.fraction == 0 and c.current == 0, "fraction: " .. tostring(c.fraction))
end)

check("no page count means no bar and no division by zero", function()
  for _, pages in ipairs({ 0, -1 }) do
    local c = Home.cards({ { book_id = 1, edition_pages = pages, progress_pages = 10 } })[1]
    assert(c.fraction == nil and c.progress_text == nil, "drew progress without a total")
  end
  local c = Home.cards({ { book_id = 1, progress_pages = 10 } })[1]
  assert(c.fraction == nil)
end)

check("a book with no progress yet shows its length but no bar", function()
  local c = Home.cards({ { book_id = 1, pages = 300 } })[1]
  assert(c.fraction == nil and c.progress_text == "300 pages", tostring(c.progress_text))
end)

check("a book with no cover has no cover url", function()
  assert(Home.cards({ { book_id = 1 } })[1].cover_url == nil)
  assert(Home.cards({ { book_id = 1, cached_image = {} } })[1].cover_url == nil)
  assert(Home.cards({ { book_id = 1, cached_image = { url = "" } } })[1].cover_url == nil)
end)

check("nil, empty and malformed lists are fine", function()
  assert(#Home.cards(nil) == 0 and #Home.cards({}) == 0)
  assert(#Home.cards({ "x", {}, { title = "no id" } }) == 0, "made a card with nothing to open")
  assert(Home.cards({ { book_id = 1 } })[1].title == "Unknown title")
end)

check("two lists that draw the same cards compare equal, a changed page does not", function()
  local a = { { book_id = 1, title = "T", edition_pages = 100, progress_pages = 10 } }
  local b = { { book_id = 1, title = "T", edition_pages = 100, progress_pages = 10, user_book_id = 5 } }
  local c = { { book_id = 1, title = "T", edition_pages = 100, progress_pages = 11 } }
  assert(Home.sameCards(a, b), "equal lists reported different")
  assert(not Home.sameCards(a, c), "a changed page was missed")
  assert(not Home.sameCards(a, {}), "a shorter list was missed")
  assert(Home.sameCards(nil, {}))
end)

check("counts compare only the shelves shown", function()
  assert(Home.sameCounts({ [1] = 2, [9] = 1 }, { [1] = 2, [9] = 7 }, { 1 }))
  assert(not Home.sameCounts({ [1] = 2 }, { [1] = 3 }, { 1 }))
  assert(not Home.sameCounts({}, { [1] = 3 }, { 1 }))
end)

check("a shelf button reads 'Name  middot  count', or just the name", function()
  assert(Home.rowLabel({ title = "Read", count = 130 }) == "Read  \194\183  130")
  assert(Home.rowLabel({ title = "Read", count = 0 }) == "Read  \194\183  0")
  assert(Home.rowLabel({ title = "Read" }) == "Read")
end)

print("\n== the reading query ==")

check("it asks for the reading shelf, newest first, five, with the latest read", function()
  answer({ user_books = {} })
  Api:getCurrentlyReading(7)
  assert(captured.vars.userId == 7 and captured.vars.statusId == 2 and captured.vars.limit == 5)
  local q = captured.q
  assert(q:find("order_by: { updated_at: desc }", 1, true), "not newest first")
  assert(q:find("user_book_reads(order_by: { id: desc }, limit: 1)", 1, true), "not the latest read")
  for _, field in ipairs({ "progress_pages", "cached_image", "contributions", "edition", "pages" }) do
    assert(q:find(field, 1, true), "query lacks " .. field)
  end
  Api:getCurrentlyReading(7, 3)
  assert(captured.vars.limit == 3, "limit not passed")
end)

check("rows come back as entries with progress and the edition's pages", function()
  answer({ user_books = { {
    id = 1, status_id = 2,
    book = { book_id = 9, title = "Nine", pages = 300, cached_image = { url = "u" },
             contributions = { { author = { name = "A. Writer" } } } },
    user_book_reads = { { progress_pages = 120, edition = { pages = 250 } } },
  }, {
    id = 2, status_id = 2, book = { book_id = 10, title = "Ten" }, user_book_reads = {},
  } } })
  local entries = Api:getCurrentlyReading(7)
  assert(#entries == 2)
  assert(entries[1].book_id == 9 and entries[1].authors == "A. Writer")
  assert(entries[1].progress_pages == 120 and entries[1].edition_pages == 250)
  assert(entries[2].progress_pages == nil and entries[2].edition_pages == nil, "invented progress")
  local c = Home.cards(entries)
  assert(c[1].fraction == 120 / 250 and c[2].fraction == nil)
end)

check("a failed request returns nothing", function()
  answer(nil, { completed = false })
  local entries, err = Api:getCurrentlyReading(7)
  assert(entries == nil and err ~= nil)
  answer({})
  assert(Api:getCurrentlyReading(7) == nil, "a reply with no list was taken as empty")
end)

check("an empty shelf is an empty list, not a failure", function()
  answer({ user_books = {} })
  local entries = Api:getCurrentlyReading(7)
  assert(type(entries) == "table" and #entries == 0)
end)

print("\n== the saved reading list ==")

check("a saved list comes back, per account, and empty is a real answer", function()
  local c = newCache()
  assert(c:reading(1) == nil, "invented a list")
  assert(c:putReading(1, { { book_id = 1, title = "T", description = "long", progress_pages = 5 } }))
  local got = c:reading(1)
  assert(got[1].title == "T" and got[1].progress_pages == 5)
  assert(got[1].description == nil, "kept a description the home screen never shows")
  assert(c:reading(2) == nil, "another account saw this list")
  c:putReading(1, {})
  assert(type(c:reading(1)) == "table" and #c:reading(1) == 0, "an emptied list was lost")
end)

check("saving does not alias the caller's entries", function()
  local c = newCache()
  local entries = { { book_id = 1, description = "d" } }
  c:putReading(1, entries)
  assert(entries[1].description == "d", "stripped the caller's table")
end)

check("sign out clears the reading list too", function()
  local c = newCache()
  c:putReading(1, { { book_id = 1 } })
  c:clear()
  assert(c:reading(1) == nil, "sign out left the reading list behind")
end)

check("a reading list is not mistaken for a shelf", function()
  local c = newCache()
  c:putReading(1, { { book_id = 1 } })
  assert(c:get(1, 2) == nil and c:counts(1, { 2 })[2] == nil)
end)

print("\n== launching it ==")

check("a Dispatcher action opens the home screen, for gestures and other plugins", function()
  local main = read("main.lua")
  assert(main:find('registerAction%("hardcover_home"'), "no hardcover_home action is registered")
  local block = main:match('registerAction%("hardcover_home".-%}%)')
  assert(block and block:find('event = "HardcoverHome"', 1, true), "the action sends the wrong event")
  assert(block:find("general = true", 1, true), "the action is not available everywhere")
  assert(main:find("function HardcoverApp:onHardcoverHome()", 1, true), "nothing handles HardcoverHome")
end)

check("the plugin menu has a Home entry", function()
  local menu = read("hardcover/lib/ui/hardcover_menu.lua")
  assert(menu:find('text = _%("Home"%)'), "no Home item in the menu")
  assert(menu:find("showHome", 1, true), "the Home item does not open the home screen")
end)

r.finish()
