-- The "...Async" wrappers on the API: which exist, that each hands its arguments to the
-- blocking call it is named for (holes and all) and the callback the answer, and that a
-- call that raises still reaches the callback. They are generated from one list, so this
-- is the contract that list must keep.
--
-- Unlike api_async_harness this does not need LuaJIT: Trapper:wrap here just runs the
-- function, since what is checked is the wiring, not that the UI is not blocked.
--
-- Run with:  lua spec/api_wrappers_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_ui_stubs()
support.preload_http_stubs()
support.preload_json(PLUGIN)

local ticks = {}
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn) fn() end }
end
package.preload["ui/uimanager"] = function()
  return {
    show = function() end, setDirty = function() end, scheduleIn = function() end,
    unschedule = function() end,
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
  }
end
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return true end, isOnline = function() return true end }
end
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
Api.auth = nil

local r = support.reporter()
local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local function deliver_ticks()
  while #ticks > 0 do table.remove(ticks, 1)() end
end

-- the wrappers the screens rely on, with how many arguments the blocking call takes
local WRAPPERS = {
  saveGoal = 2, archiveGoal = 1, getGoals = 0, getLists = 0, getBookLists = 1, addToList = 3,
  removeFromList = 1, getListCount = 0, getShelf = 4, getStats = 1, getBooksByIds = 1,
  getVibes = 1, getForYou = 0, me = 0, getSimilarBooks = 1, getBookDetail = 3, getReviews = 3,
  updateUserBook = 4, removeUserBook = 1, findBooks = 3, findEditions = 2,
  findDefaultEdition = 2, findBookByIdentifiers = 2,
}

print("\n== which wrappers exist ==")

for name in pairs(WRAPPERS) do
  check(name .. "Async exists and " .. name .. " is a real method", function()
    assert(type(Api[name .. "Async"]) == "function", "no " .. name .. "Async")
    assert(type(Api[name]) == "function", "no " .. name .. " to wrap")
  end)
end

check("no wrapper exists that is not in the contract", function()
  for key, value in pairs(Api) do
    local base = type(key) == "string" and key:match("^(.+)Async$")
    if base and type(value) == "function" then
      assert(WRAPPERS[base] ~= nil, key .. " is not in the list of wrappers this checks")
    end
  end
end)

print("\n== what they pass on ==")

for name, arity in pairs(WRAPPERS) do
  check(name .. "Async passes its arguments, then delivers the answer", function()
    local original = Api[name]
    local seen
    Api[name] = function(self, ...)
      seen = { self = self, n = select("#", ...), ... }
      return "answer", "extra"
    end
    local args = {}
    for i = 1, arity do args[i] = "arg" .. i end
    local got
    args[#args + 1] = function(...) got = { n = select("#", ...), ... } end
    Api[name .. "Async"](Api, unpack(args))
    Api[name] = original
    deliver_ticks()
    assert(seen and seen.self == Api, "the blocking call did not get the API as self")
    assert(seen.n == arity, "arguments passed: " .. tostring(seen.n) .. ", expected " .. arity)
    for i = 1, arity do assert(seen[i] == "arg" .. i, "argument " .. i .. " changed") end
    assert(got and got.n == 2 and got[1] == "answer" and got[2] == "extra", "answer not delivered intact")
  end)
end

check("a nil in the middle of the arguments stays where it is", function()
  local original = Api.getBookDetail
  local seen
  Api.getBookDetail = function(_, book_id, user_id, edition_id) seen = { book_id, user_id, edition_id } end
  Api:getBookDetailAsync(7, nil, 3, function() end)
  Api.getBookDetail = original
  assert(seen[1] == 7 and seen[2] == nil and seen[3] == 3)
end)

check("a trailing nil argument is passed as nil, not dropped into the callback's place", function()
  local original = Api.getShelf
  local seen_n
  Api.getShelf = function(_, ...) seen_n = select("#", ...) end
  local called = false
  Api:getShelfAsync(1, 3, 0, nil, function() called = true end)
  Api.getShelf = original
  deliver_ticks()
  assert(seen_n == 4, "arguments: " .. tostring(seen_n))
  assert(called)
end)

check("the callback is not run inline, only on the next tick", function()
  local original = Api.getGoals
  Api.getGoals = function() return "goals" end
  local got
  Api:getGoalsAsync(function(g) got = g end)
  Api.getGoals = original
  assert(got == nil, "ran before the next tick")
  deliver_ticks()
  assert(got == "goals")
end)

check("the method is looked up when called, so a replaced one is the one that runs", function()
  local original = Api.getLists
  Api.getLists = function() return "first" end
  local got
  Api:getListsAsync(function(v) got = v end)
  deliver_ticks()
  assert(got == "first")
  Api.getLists = function() return "second" end
  Api:getListsAsync(function(v) got = v end)
  deliver_ticks()
  Api.getLists = original
  assert(got == "second")
end)

check("a call that raises still reaches the callback, with no results", function()
  local original = Api.getForYou
  Api.getForYou = function() error("boom") end
  local called, first = false, "unset"
  Api:getForYouAsync(function(v) called = true; first = v end)
  Api.getForYou = original
  deliver_ticks()
  assert(called and first == nil)
end)

r.finish()
