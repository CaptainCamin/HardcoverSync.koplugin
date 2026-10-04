--[[--
Stats, from Home: the tile, the dashboard of charts (all time, then a year through the period
chooser), the saved copy shown offline and kept when a refresh fails, the first-time
messages, and an empty library.

Screens: stats_all, stats_all_2, stats_all_3, stats_year, stats_offline, stats_empty.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function top() return UIManager:getTopmostVisibleWidget() end

return {
  name = "stats",

  run = function(emu)
    local SETTING = require("hardcover/lib/constants/settings")
    local settings = fixtures.real_settings(emu)
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    fixtures.install({ settings = settings })

    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_stats.lua"
    os.remove(path)
    os.remove((path:gsub("%.lua$", "")) .. "_home.lua")
    local cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end }
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings, shelf_cache = cache }

    -- the tile on Home
    manager:showHome()
    emu:pump()
    local found
    for _, t in ipairs(manager.home_dialog.tiles) do if t.key == "stats" then found = t.tile end end
    assert(found, "no Stats tile on Home")
    emu:closeAll()

    -- all time
    manager:showStats()
    for _ = 1, 6 do emu:pump() end
    local dialog = manager.stats_dialog
    assert(dialog and dialog.rows and #dialog.rows == 105, "the stats did not load")
    for _, expected in ipairs({ "Stats", "Period: All time", "Books per year", "Your ratings", "Genres", "Most read authors", "Book length" }) do
      emu:expectText(expected)
    end
    emu:shot("stats_all")
    assert(dialog.scroll, "a page of charts should scroll")
    dialog.scroll:scrollToRatio(0, 0.5)
    emu:pump()
    emu:shot("stats_all_2")
    dialog.scroll:scrollToRatio(0, 1)
    emu:pump()
    emu:shot("stats_all_3")

    -- one year
    dialog.year = 2024
    dialog:rebuild()
    emu:pump()
    emu:expectText("Books per month")
    emu:shot("stats_year")
    emu:closeAll()

    -- offline: the saved copy, with its note
    local Network = require("ui/network/manager")
    local was, was_state = Network.isConnected, Network.getConnectionState
    Network.isConnected = function() return false end
    Network.getConnectionState = function() return false end
    manager:showStats()
    for _ = 1, 4 do emu:pump() end
    assert(manager.stats_dialog.rows and #manager.stats_dialog.rows == 105, "saved copy not shown")
    assert(manager.stats_dialog.note and manager.stats_dialog.note:find("Offline"), "no offline note: " .. tostring(manager.stats_dialog.note))
    emu:shot("stats_offline")
    emu:closeAll()
    Network.isConnected, Network.getConnectionState = was, was_state

    -- nothing finished yet
    fixtures.stats_raw = {}
    manager.shelf_cache:clear()
    manager:showStats()
    for _ = 1, 4 do emu:pump() end
    emu:expectText("No finished books yet")
    emu:shot("stats_empty")
    emu:closeAll()
    fixtures.stats_raw = nil
  end,
}
