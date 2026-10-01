-- Proves the "Async" API wrappers really are non-blocking.
--
-- Trapper:dismissableRunInSubprocess forks and yields to the UI only when it
-- runs inside Trapper:wrap. Outside one it logs "unwrapped
-- dismissableRunInSubprocess(), falling back to blocking in-process run" and
-- the whole UI freezes until the reply arrives. The wrappers used to call the
-- blocking function directly and merely delay the callback, so a screen shown
-- just before the call was never painted during the request.
--
-- The Trapper below behaves like KOReader's on that one point: inside a
-- coroutine a subprocess call yields, outside one it runs inline and is
-- counted as a blocking call.
--
-- Run with:  lua spec/api_async_harness.lua [plugin-root]

-- KOReader runs LuaJIT, which can yield across pcall; plain Lua 5.1 cannot, and
-- Trapper:wrap yields inside a pcall. Under 5.1 this would fail for a reason
-- that has nothing to do with the plugin, so say so and stop.
if not jit then
  print("  SKIPPED: needs LuaJIT (plain Lua 5.1 cannot yield across pcall)")
  print("\n  0 passed, 0 failed")
  os.exit(0)
end

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_ui_stubs()
support.preload_http_stubs()
support.preload_json(PLUGIN)

local blocking_calls = 0
local in_flight = {} -- coroutines waiting on their "subprocess"
local ticks = {}

package.preload["socket.http"] = function()
  return {
    request = function(req)
      req.sink('{"data":{"ok":true}}')
      return 1, 200, {}, "OK"
    end,
  }
end
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return true end, isOnline = function() return true end }
end
package.preload["ui/trapper"] = function()
  return {
    wrap = function(_, fn)
      local co = coroutine.create(fn)
      local ok, err = coroutine.resume(co)
      if not ok then io.stderr:write("wrapped function raised: " .. tostring(err) .. "\n") end
    end,
    dismissableRunInSubprocess = function(_, task)
      if not coroutine.running() then
        blocking_calls = blocking_calls + 1
        return true, task()
      end
      -- fork: hand control back to the UI, resume when the "child" finishes
      in_flight[#in_flight + 1] = { co = coroutine.running(), task = task }
      local result = coroutine.yield()
      return true, result
    end,
  }
end
package.preload["ui/uimanager"] = function()
  return {
    show = function() end, setDirty = function() end, scheduleIn = function() end,
    unschedule = function() end,
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
  }
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

-- let every "subprocess" finish, then deliver queued callbacks
local function pump()
  local guard = 0
  while (#in_flight > 0 or #ticks > 0) and guard < 100 do
    guard = guard + 1
    if #in_flight > 0 then
      local job = table.remove(in_flight, 1)
      local ok, err = coroutine.resume(job.co, job.task())
      if not ok then io.stderr:write("resume raised: " .. tostring(err) .. "\n") end
    else
      table.remove(ticks, 1)()
    end
  end
end

local function reset()
  blocking_calls, in_flight, ticks = 0, {}, {}
end

print("\n== Async wrappers do not block the UI ==")

-- Each wrapper paired with the blocking function it calls and its arguments.
local cases = {
  { "getShelfAsync", "getShelf", { 1, 3, 0, 20 } },
  { "getBookDetailAsync", "getBookDetail", { 7, 1, 3 } },
  { "findBooksAsync", "findBooks", { "title", "author", 1 } },
  { "findEditionsAsync", "findEditions", { 7, 1 } },
  { "findDefaultEditionAsync", "findDefaultEdition", { 7, 1 } },
  { "findBookByIdentifiersAsync", "findBookByIdentifiers", { { isbn = "1" }, 1 } },
}

for _, case in ipairs(cases) do
  local wrapper, target, args = case[1], case[2], case[3]
  check(wrapper .. " yields to the UI and delivers later", function()
    reset()
    local original = Api[target]
    -- the blocking function does one real request, as the real ones do
    Api[target] = function(self) local data = self:query("{ ok }"); return data and "result", nil, false end
    local got
    local function done(...) got = { n = select("#", ...), ... } end
    local call = { unpack(args) }
    call[#call + 1] = done
    Api[wrapper](Api, unpack(call))
    Api[target] = original

    assert(blocking_calls == 0, "ran the request inline (blocking), " .. blocking_calls .. " time(s)")
    assert(#in_flight == 1, "the request was not handed to a subprocess")
    assert(got == nil, "callback ran before the request finished")
    pump()
    assert(got and got[1] == "result", "callback never delivered the result")
  end)
end

check("an error reaches the callback instead of leaving it waiting", function()
  reset()
  local original = Api.getShelf
  Api.getShelf = function() error("boom") end
  local called = false
  Api:getShelfAsync(1, 3, 0, 20, function(entries) called = true; assert(entries == nil) end)
  Api.getShelf = original
  pump()
  assert(called, "callback never fired, so a loading dialog would wait forever")
end)

check("results and an error both come through", function()
  reset()
  local original = Api.getShelf
  Api.getShelf = function() return nil, { status = 500 }, false end
  local a, b, c
  Api:getShelfAsync(1, 3, 0, 20, function(x, y, z) a, b, c = x, y, z end)
  Api.getShelf = original
  pump()
  assert(a == nil and b and b.status == 500 and c == false, "arguments were not passed through intact")
end)

r.finish()
