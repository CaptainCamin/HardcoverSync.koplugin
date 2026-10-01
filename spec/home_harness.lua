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
