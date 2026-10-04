--[[--
"For you", from Home: a tile, the screen it opens (books suggested from your ratings, each
with why under it), the saved picks shown at once and kept when a refresh fails or there is
no connection, the empty state when nothing is rated 4 or more, and the setting that turns
the tile off.

Screens: for_you_home, for_you_list, for_you_empty.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function top() return UIManager:getTopmostVisibleWidget() end

return {
  name = "for_you",

  run = function(emu)
    local SETTING = require("hardcover/lib/constants/settings")
    local settings = fixtures.real_settings(emu)
    settings:updateSetting(SETTING.SHOW_FOR_YOU, true) -- the settings file outlives a run
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    for _, b in ipairs(fixtures.shelf_books) do
      local image = b.cached_image
      if image and image.url then fixtures.seed_cover(image.url, b.book_id % 3 + 1) end
    end
    fixtures.install({ settings = settings })
    fixtures.for_you_ids = { 9, 4, 7 }
    fixtures.for_you_reasons = { "Wool", "Dune", "Kindred" }

    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_for_you.lua"
    os.remove(path)
    os.remove((path:gsub("%.lua$", "")) .. "_home.lua")
    local cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end }
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings, shelf_cache = cache }

    -- the tile on Home
    manager:showHome()
    emu:pump()
    local home = manager.home_dialog
    -- the tile is the last one, below the first screenful (a tap there is not answered until
    -- the page is scrolled to it), so the tile's own action is run
    local tile
    for _, t in ipairs(home.tiles) do if t.key == "for_you" then tile = t.tile end end
    assert(tile, "no For you tile on Home")
    emu:shot("for_you_home")
    tile.callback()
    for _ = 1, 5 do emu:pump() end

    -- the screen: the picks, in order, with why
    local list = top()

    assert(list and list.entries and #list.entries == 3, "the picks did not open: " .. tostring(list and list.name))
    assert(list.title == "For you")
    emu:expectText("Because you liked Wool")
    emu:expectText("Because you liked Dune")
    emu:shot("for_you_list")
    local saved = cache:forYou(fixtures.USER_ID)
    assert(saved and #saved == 3 and saved[1].reason == "Wool", "the picks were not saved")
    emu:closeAll()

    -- offline: the saved picks, and the date they are from
    local NetworkManager = require("ui/network/manager")
    local was, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end
    local asked = #fixtures.calls
    manager:showForYou()
    emu:pump()
    assert(manager.for_you_dialog.entries and #manager.for_you_dialog.entries == 3, "the saved picks did not show offline")
    emu:expectText("Offline: showing your picks from")
    for _, c in ipairs({ table.unpack(fixtures.calls, asked + 1) }) do
      assert(c.name ~= "getForYou", "asked for picks while offline")
    end
    emu:closeAll()
    NetworkManager.isConnected, NetworkManager.getConnectionState = was, was_state

    -- a failed refresh keeps the saved picks, with no error
    fixtures.for_you_fail = true
    manager:showForYou()
    emu:pump()
    assert(#manager.for_you_dialog.entries == 3, "a failed refresh lost the saved picks")
    emu:closeAll()
    fixtures.for_you_fail = nil

    -- nothing saved and offline: it says so (no screen)
    os.remove(path)
    os.remove((path:gsub("%.lua$", "")) .. "_home.lua")
    cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end }
    manager = DialogManager:new { settings = settings, shelf_cache = cache }

    -- nothing rated 4 or more: the empty state
    fixtures.for_you_note = "no_ratings"
    manager:showForYou()
    emu:pump()
    emu:expectText("Rate a few books 4 or 5 stars")
    emu:shot("for_you_empty")
    emu:closeAll()
    fixtures.for_you_note = nil

    -- the setting turns the tile off
    settings:updateSetting(SETTING.SHOW_FOR_YOU, false)
    manager:showHome()
    emu:pump()
    for _, t in ipairs(manager.home_dialog.tiles) do assert(t.key ~= "for_you", "the tile is still there") end
    emu:closeAll()
  end,
}
