-- Changing "Track every N minutes" must rebuild the page-update throttle at once.
--
-- Run with:  lua spec/track_frequency_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local KB = dofile(PLUGIN .. "/spec/sync_regressions/lib.lua")
local App = KB.load_main()
local r = KB.support.reporter()
local check = r.test

local SETTING = require("hardcover/lib/constants/settings")

check("changing the track frequency re-creates the page-update throttle", function()
  local rebuilt = 0
  local app = KB.new_app {
    cancelPendingUpdates = function() end,
    initializePageUpdate = function() rebuilt = rebuilt + 1 end,
  }
  app:onSettingsChanged(SETTING.TRACK_FREQUENCY, 10, 5)
  assert(rebuilt == 1, "rebuilt " .. rebuilt .. " times")
end)

r.finish()
