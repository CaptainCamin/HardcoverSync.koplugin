-- Api:getStats: the paged request for finished books, against a stubbed Api:query.
--
-- Run with:  lua spec/stats_api_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local function make()
  local t = {}
  return setmetatable(t, {
    __index = function() return make() end, __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end, __mul = function() return 0 end,
    __div = function() return 0 end, __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end
package.preload["ui/uimanager"] = function()
  return { show = function() end, close = function() end, isWidgetShown = function() return false end,
    setDirty = function() end, scheduleIn = function() end, unschedule = function() end, nextTick = function() end }
end
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn) local co = coroutine.create(fn); assert(coroutine.resume(co)) end }
end
package.preload["ui/network/manager"] = function() return { isConnected = function() return true end } end
package.preload["gettext"] = function() return setmetatable({}, { __call = function(_, s) return s end }) end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["logger"] = function() return { dbg = function() end, info = function() end, warn = function() end, err = function() end } end
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then return real_require(name) end
  return make()
end

local Vibes = real_require("hardcover/lib/vibes")
local Api = real_require("hardcover/lib/hardcover_api")

local sent, script
local function answers(...)
  Api.enabled = true
  sent, script = {}, { ... }
  Api.query = function(_, q, vars, background)
    sent[#sent + 1] = { q = q, vars = vars, background = background }
    local a = table.remove(script, 1) or {}
    return a.result, a.err
  end
end

local function rows(n, from)
  local list = {}
  for i = 1, n do
    list[i] = { id = (from or 0) + i, rating = 4, last_read_date = "2024-05-05", user_book_reads = {},
      book = { title = "B" .. i, pages = 100, contributions = {} } }
  end
  return list
end

check("a short library is one request, ordered by id, never cancelled by a touch; genres come with it", function()
  answers({ result = { me = { { cached_genres = { { tag = "Fantasy", count = 3 } } } }, user_books = rows(3) } })
  local stats = Api:getStats(7291)
  assert(stats and #stats.rows == 3 and stats.complete == true, "rows")
  assert(stats.genres[1].label == "Fantasy" and stats.genres[1].value == 3, "genres")
  assert(#sent == 1 and sent[1].background == true and sent[1].vars.userId == 7291 and sent[1].vars.offset == 0)
  assert(sent[1].q:find("order_by: [{ id: asc }]", 1, true), "unordered paging overlaps")
end)

check("a long library is paged by 500 until a short page", function()
  answers({ result = { me = {}, user_books = rows(500) } }, { result = { me = {}, user_books = rows(120, 500) } })
  local stats = Api:getStats(1)
  assert(#stats.rows == 620 and stats.complete == true)
  assert(#sent == 2 and sent[2].vars.offset == 500)
end)

check("a library past the page limit comes back marked incomplete, not endless", function()
  local pages = {}
  for i = 1, 20 do pages[i] = { result = { me = {}, user_books = rows(500, (i - 1) * 500) } } end
  answers(); script = pages
  local stats = Api:getStats(1)
  assert(stats.complete == false and #sent == 8 and #stats.rows == 4000, "sent " .. #sent)
end)

check("a failure is nil and the error, and a failure on a later page loses nothing silently", function()
  local err = { completed = false }
  answers({ err = err })
  local stats, e = Api:getStats(1)
  assert(stats == nil and e == err)
  answers({ result = { me = {}, user_books = rows(500) } }, { err = err })
  stats, e = Api:getStats(1)
  assert(stats == nil and e == err, "a partial library must not pass for a whole one")
end)

r.finish()
