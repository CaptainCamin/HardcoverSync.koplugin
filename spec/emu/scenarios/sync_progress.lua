-- The sync progress bar on the plugin's own screen: Home's sync box says "Syncing…" and the toast
-- bar along the bottom edge fills as entries are verified and sent. It never takes the screen away.
--
-- Screens: sync_progress_start, sync_progress_verify, sync_progress_send.

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")
local Device = require("device")

return {
  name = "sync_progress",

  run = function(emu)
    local NetworkManager = require("ui/network/manager")
    local was_connected, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end

    local settings = fixtures.real_settings(emu)
    local SETTING = require("hardcover/lib/constants/settings")
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    fixtures.install({ settings = settings, goals_rows = {} })

    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_sync_progress.lua"
    os.remove(path)
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local pending = 12
    local manager = DialogManager:new {
      settings = settings,
      sync_queue = {
        finishedCount = function() return 0 end,
        pendingCount = function() return pending end,
        changeCount = function() return pending end,
        shelfOp = function() return nil end,
      },
      shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end },
      send_now = function() end,
      show_pending = function() end,
    }

    manager:showHome()
    emu:pump()
    local shell = UIManager:getTopmostVisibleWidget()
    assert(shell and shell.name == "hardcover_shell", "Home did not open the shell")

    -- the flush starts: the box says Syncing… and the bar shows its empty fill
    manager:syncingChanged(true)
    emu:pump()
    local SyncProgress = require("hardcover/lib/ui/components/sync_progress")
    local progress = SyncProgress.show { total = pending }
    emu:pump()
    emu:expectText("Your changes are on their way.")
    emu:expectText("Syncing 0 of 12")
    emu:shot("sync_progress_start")

    -- the slow part: Hardcover is asked about the book before anything is sent
    progress:update { phase = "verify", title = "Dune", kind = "page" }
    emu:pump()
    emu:expectText("Verifying page for Dune")
    emu:shot("sync_progress_verify")

    -- each entry sent moves the count and the fill
    progress:update { phase = "send" }
    progress:update { phase = "send" }
    progress:update { phase = "send" }
    emu:pump()
    emu:expectText("Syncing 3 of 12")
    emu:shot("sync_progress_send")

    -- the flush ends: the bar goes, the box goes back to saying what is waiting
    progress:close()
    manager:syncingChanged(false)
    emu:pump()

    emu:closeAll()
    emu:pump()
    NetworkManager.isConnected = was_connected
    NetworkManager.getConnectionState = was_state
  end,
}
