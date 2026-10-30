--[[--
Stats: the dashboard of charts (all time, then a year through the period
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

    -- all time
    manager:showStats()
    for _ = 1, 6 do emu:pump() end
    local dialog = manager.stats_dialog
    assert(dialog and dialog.rows and #dialog.rows == 105, "the stats did not load")
    for _, expected in ipairs({ "Stats", "Books per year", "Your ratings", "Genres", "Most read authors", "Book length" }) do
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
    emu:expectText("Rating and length")

    -- one year, from its tab: All time, the two latest years, Earlier
    assert(dialog.chips and #dialog.chips == 4, "expected four period chips, got " .. tostring(dialog.chips and #dialog.chips))
    emu:screenNodes() -- paint: tap ranges are only real once painted
    local tab = dialog.chips[3].dimen
    emu:tapExpecting(tab.x + math.floor(tab.w / 2), tab.y + math.floor(tab.h / 2))
    emu:pump()
    assert(dialog.year == 2024, "the 2024 tab did not choose 2024: " .. tostring(dialog.year))
    emu:expectText("Books per month")
    emu:expectText("Pages per month")
    emu:expectText("Pace")
    emu:shot("stats_year")

    -- one month of that year, from the Month chip: the picker lists the months with a finish
    emu:screenNodes()
    tab = dialog.chips[5].dimen
    emu:tapExpecting(tab.x + math.floor(tab.w / 2), tab.y + math.floor(tab.h / 2))
    emu:pump()
    emu:expectText("All of 2024")
    local month_row
    for _, node in ipairs(emu:screenNodes()) do
      if not month_row and node.text:find(" · ", 1, true) then month_row = node end
    end
    assert(month_row, "no month with a finish in 2024")
    emu:tapExpecting(month_row.x + math.floor(month_row.w / 2), month_row.y + math.floor(month_row.h / 2))
    emu:pump()
    assert(dialog.month, "the month row did not choose a month")
    for _, node in ipairs(emu:screenNodes()) do
      assert(node.text ~= "Books per month", "a single month should not show the books-per-month chart")
    end
    emu:shot("stats_month")
    -- Earlier opens the picker with every year
    tab = dialog.chips[4].dimen
    emu:tapExpecting(tab.x + math.floor(tab.w / 2), tab.y + math.floor(tab.h / 2))
    emu:pump()
    emu:expectText("Period")
    emu:expectText("2023")
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
