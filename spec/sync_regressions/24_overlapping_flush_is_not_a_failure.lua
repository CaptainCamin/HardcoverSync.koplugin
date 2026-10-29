-- BUG: a second flush trigger (Sync tap, reconnect, resume) while one is running got the
-- queues' "busy" answer (false), which read as "Sync failed" and armed a retry although
-- the running flush was fine.
--
-- Expected: the second trigger starts nothing, and hears the running flush's result.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
local App, sched = KB.load_main()
local User = require("hardcover/lib/user")
User.settings = { readSetting = function() return 1 end, updateSetting = function() end }

print("\n== overlapping flush ==")

KB.check("a flush started while one is running is not a failure", function()
  local flushes, app = 0, nil
  local results = {}
  app = KB.new_app {
    state = { book_status = {} },
    ui = {},
    settings = { readSetting = function() return false end, syncEnabled = function() return false end },
    sync_queue = {
      hasPending = function() return true end,
      pendingCount = function() return 1 end,
      flush = function()
        flushes = flushes + 1
        if flushes == 1 then app:flushSyncQueue(false, function(ok) results[#results + 1] = ok end) end
        return flushes == 1 -- a second real flush would answer busy: false
      end,
    },
    wifi = { withWifi = function(_, fn) fn() end },
  }
  sched.scheduled = {}
  KB.network.connected = true
  app:flushSyncQueue(false, function(ok) results[#results + 1] = ok end)
  KB.eq(flushes, 1, "only one flush ran")
  KB.eq(#results, 2, "both callers were answered")
  KB.eq(results[1], true, "the first")
  KB.eq(results[2], true, "the second hears the same result, not a failure")
  KB.eq(#sched.scheduled, 0, "no retry armed")
  KB.eq(app.flush_running, false, "released")
end)

KB.finish("an overlapping flush must not read as a failure")
