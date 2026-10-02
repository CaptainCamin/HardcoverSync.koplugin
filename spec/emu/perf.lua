--[[--
Helpers for the refresh/decode scenarios (perf_*.lua).

The fixtures answer synchronously, which folds what is really several network
round trips into one tick. A device repaints between each, so `slow_network`
makes the named API calls wait one tick (the way a subprocess request yields to
the event loop) and `run_loop` does what UIManager's main loop does: run what is
due, then repaint, until nothing is left.
]]

local UIManager = require("ui/uimanager")

local M = {}

-- every listed API call yields to the event loop for one tick before answering
function M.slow_network(names)
  local Api = require("hardcover/lib/hardcover_api")
  for _, name in ipairs(names) do
    local fast = Api[name]
    Api[name] = function(...)
      local co = coroutine.running()
      if co then
        UIManager:nextTick(function() coroutine.resume(co) end)
        coroutine.yield()
      end
      return fast(...)
    end
  end
end

-- the main loop: tasks, then a repaint, until the queue is empty
function M.run_loop(rounds)
  -- timers (Home's wait for more data) are real time, so wait for them: sleep a
  -- little whenever nothing is due, until the queue is empty
  local usleep = require("ffi/util").usleep
  for _ = 1, rounds or 2000 do
    UIManager:_checkTasks()
    UIManager:_repaint()
    if not UIManager:getNextTaskTime() then break end
    usleep(2000)
  end
end

-- a DialogManager over a cache file of its own, optionally pre-filled
function M.new_manager(emu, fixtures, name, saved)
  local settings = fixtures.real_settings(emu)
  local LuaSettings = require("luasettings")
  local ShelfCache = require("hardcover/lib/shelf_cache")
  local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_" .. name .. ".lua"
  os.remove(path)
  local cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end }
  if saved then
    cache:putCounts(fixtures.USER_ID, saved.counts)
    cache:putReading(fixtures.USER_ID, saved.reading)
  end
  local DialogManager = require("hardcover/lib/ui/dialog_manager")
  return DialogManager:new { settings = settings, shelf_cache = cache }, settings, cache
end

-- Rectangles of the refreshes in a snapshot that are NOT the whole panel, as
-- "WxH" strings, for printing
function M.small_regions(snapshot)
  local out = {}
  for _, r in ipairs(snapshot.log) do
    if not r.full then out[#out + 1] = string.format("%s %dx%d", r.mode, r.w, r.h) end
  end
  return table.concat(out, ", ")
end

return M
