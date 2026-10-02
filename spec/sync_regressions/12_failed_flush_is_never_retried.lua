-- BUG: after a failed flush (429/5xx/timeout) while still online, nothing retries.
--
-- flushSyncQueue (main.lua) is only called from: onNetworkConnected,
-- onResume, the manual "Sync now", and from onSuspend / onDocumentClose --
-- the last two only when SETTING.ENABLE_WIFI is on. When the flush at
-- connect time fails (Hardcover answers 429 or 5xx, which is exactly when the
-- queue matters), the user sees at most a one-off "Sync failed ... will retry"
-- message on a manual sync, and then nothing is scheduled. A device that stays
-- connected keeps the queued entries (any status change, and every book other
-- than the open one) until the next network *connect* event or resume. Closing
-- the book or suspending while still connected does not flush either unless
-- Auto-wifi is enabled.
--
-- Expected: a failed flush while connected schedules a retry with backoff, and
-- suspend/close flush whenever the device is already online.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
local App, sched = KB.load_main()
local User = require("hardcover/lib/user")
User.settings = { readSetting = function() return 1 end, updateSetting = function() end }

print("\n== retrying a failed flush ==")

local function newApp(flushes)
  return KB.new_app {
    state = { book_status = {} },
    ui = {},
    settings = { readSetting = function() return false end, syncEnabled = function() return false end },
    sync_queue = {
      hasPending = function() return true end,
      pendingCount = function() return 1 end,
      flush = function() flushes[#flushes + 1] = true return false end, -- Hardcover is answering 5xx
    },
    wifi = { withWifi = function(_, fn) fn() end },
  }
end

KB.check("a failed flush on connect schedules a retry", function()
  local flushes = {}
  sched.scheduled = {}
  KB.network.connected = true
  newApp(flushes):onNetworkConnected()
  KB.eq(#flushes, 1, "flush attempts on connect")
  KB.eq(#sched.scheduled >= 1, true, "retries scheduled after the failure")
end)

KB.check("suspending while connected (Auto-wifi off) flushes what is queued", function()
  local flushes = {}
  KB.network.connected = true
  newApp(flushes):onSuspend()
  KB.eq(#flushes, 1, "flush attempts at suspend")
end)

KB.check("closing the book while connected (Auto-wifi off) flushes what is queued", function()
  local flushes = {}
  KB.network.connected = true
  newApp(flushes):onDocumentClose()
  KB.eq(#flushes, 1, "flush attempts at close")
end)

KB.finish("failed or skipped flushes must be retried while online")
