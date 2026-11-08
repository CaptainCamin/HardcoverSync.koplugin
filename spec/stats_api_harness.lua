-- Api:getStats (the paged request for finished books) and which requests a tap must not cancel,
-- against a stubbed Api:query.
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
    list[i] = { id = (from or 0) + i, status_id = 3, read_count = 1, rating = 4,
      last_read_date = "2024-05-05", user_book_reads = {},
      book = { id = (from or 0) + i, title = "B" .. i, pages = 100, contributions = {} } }
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

check("history includes current rereads, every completion and primary coauthors; the dashboard is unchanged", function()
  local raw = rows(2)
  raw[1].rating = 5
  raw[1].user_book_reads = {
    { id = 3, finished_at = "2025-11-09", finished_at_precision = 1 },
    { id = 1, finished_at = "2023-11-01", finished_at_precision = 2 },
    { id = 2, finished_at = "2024-01-01", finished_at_precision = 3 },
  }
  raw[1].book.cached_contributors = {
    { primary = true, author = { id = 10, name = "A" } },
    { contributor_role_id = 1, author = { id = 11, name = "B" } },
    { primary = true, contribution = "Translator", author = { id = 12, name = "Translator" } },
    { primary = false, author = { id = 13, name = "Narrator" } },
    { contributor_role_id = 1, contributor_specialization_id = 2, author = { id = 14 } },
  }
  raw[2].status_id = 2 -- a previously finished book now being reread
  raw[2].rating = 4.5
  raw[2].user_book_reads = {
    { id = 5, started_at = "2026-10-01", progress = 60 }, -- not a completed reread
    { id = 4, finished_at = "2024-11-01", finished_at_precision = 0 }, -- completion, unknown date
  }
  answers({ result = { me = {}, user_books = raw,
    contributor_roles = { { id = 1, primary = true } },
    contributor_role_specializations = { { contributor_role_id = 1, contributor_specialization_id = 2, primary = false } },
  } })
  local stats = Api:getStats(1)
  assert(#stats.rows == 1 and stats.rows[1].date == "2025-11-09", "the existing dashboard population changed")
  assert(#stats.history == 2 and stats.history[1].book_id == 1)
  assert(stats.history[1].completions == 3 and stats.history[2].completions == 1, "an unfinished reread was counted")
  assert(#stats.history[1].authors == 2, "coauthors lost or non-authors counted")
  assert(stats.history[1].reads[2] == "2023-11" and stats.history[1].reads[3] == "2024", "date precision lost")
  assert(#stats.history[2].reads == 0, "unknown precision became a dated memory")
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

check("Home's requests are not cancelled by a tap (the reader scrolls Home while they run)", function()
  for _, call in ipairs({
    function() Api:getHomeSummary(1, 5) end,
    function() Api:getGoals() end,
    function() Api:getShelfCounts(1, { 1, 2 }) end,
    function() Api:getCurrentlyReading(1, 5) end,
    function() Api:getListCount() end,
  }) do
    answers({ result = { me = {} } })
    pcall(call)
    assert(#sent >= 1 and sent[1].background == true, "a Home request can be cancelled by a touch")
  end
end)

r.finish()
