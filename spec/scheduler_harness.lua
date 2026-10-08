-- Scheduler:clear() has to cancel the retry loops that are running.
--
-- It used to loop over a table nothing ever wrote to, so on suspend or when the wifi
-- dropped it cancelled nothing, and a read-cache retry could fire after the plugin
-- instance was gone. UIManager is a fake that records what is scheduled.
--
-- Run with:  lua spec/scheduler_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
local r = support.reporter()

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

-- what is waiting to run: job -> { when = seconds or "tick" }
local waiting
package.preload["ui/uimanager"] = function()
  return {
    nextTick = function(_, fn) waiting[fn] = "tick" end,
    scheduleIn = function(_, seconds, fn) waiting[fn] = seconds end,
    unschedule = function(_, fn) waiting[fn] = nil end,
  }
end

local Scheduler = require("hardcover/lib/scheduler")

local function count()
  local n = 0
  for _ in pairs(waiting) do n = n + 1 end
  return n
end

-- run whatever is waiting once
local function fire()
  local jobs = {}
  for fn in pairs(waiting) do jobs[#jobs + 1] = fn end
  for _, fn in ipairs(jobs) do waiting[fn] = nil; fn() end
end

local function fresh()
  waiting = {}
  Scheduler.retries = {}
end

print("\n== clearing ==")

check("clear unschedules a loop that has been started and not yet run", function()
  fresh()
  Scheduler:withRetries(3, 2, function() end)
  assert(count() == 1)
  Scheduler:clear()
  assert(count() == 0, "still scheduled after clear")
end)

check("clear unschedules the next attempt of a loop that is waiting to retry", function()
  fresh()
  Scheduler:withRetries(3, 2, function(_, fail) fail() end)
  fire()  -- first attempt fails, the next is scheduled
  assert(count() == 1)
  Scheduler:clear()
  assert(count() == 0, "the retry survived clear")
end)

check("an attempt in flight when clear runs does not schedule another when it fails", function()
  fresh()
  local fail_later
  Scheduler:withRetries(3, 2, function(_, fail) fail_later = fail end)
  fire()  -- the attempt is running; its answer has not come
  Scheduler:clear()
  fail_later()  -- the answer arrives, a failure
  assert(count() == 0, "a failed attempt started a retry after clear")
end)

check("clear cancels every loop, not just one", function()
  fresh()
  Scheduler:withRetries(3, 2, function() end)
  Scheduler:withRetries(3, 2, function() end)
  Scheduler:clear()
  assert(count() == 0)
end)

check("clear with nothing running is fine", function()
  fresh()
  Scheduler:clear()
end)

print("\n== loops that end by themselves ==")

check("a loop that succeeds is forgotten, so clear has nothing of it to cancel", function()
  fresh()
  Scheduler:withRetries(3, 2, function(success) success() end)
  fire()
  assert(next(Scheduler.retries) == nil, "a finished loop is still registered")
end)

check("a loop that runs out of tries is forgotten and calls its fail callback", function()
  fresh()
  local failed = false
  Scheduler:withRetries(2, 2, function(_, fail) fail() end, nil, function() failed = true end)
  fire(); fire()
  assert(failed and next(Scheduler.retries) == nil)
end)

check("a failing loop retries with growing waits", function()
  fresh()
  Scheduler:withRetries(4, 2, function(_, fail) fail() end)
  fire()
  local first
  for _, secs in pairs(waiting) do first = secs end
  fire()
  local second
  for _, secs in pairs(waiting) do second = secs end
  assert(first == 8 and second == 16, tostring(first) .. "," .. tostring(second))
end)

print("\n== the cancel the caller is given ==")

check("calling the returned cancel stops the loop and forgets it", function()
  fresh()
  local cancel = Scheduler:withRetries(3, 2, function(_, fail) fail() end)
  fire()
  assert(count() == 1)
  cancel()
  assert(count() == 0 and next(Scheduler.retries) == nil)
end)

check("a loop that was cancelled does not retry when its attempt then fails", function()
  fresh()
  local fail_later
  local cancel = Scheduler:withRetries(3, 2, function(_, fail) fail_later = fail end)
  fire()
  cancel()
  fail_later()
  assert(count() == 0)
end)

r.finish()
