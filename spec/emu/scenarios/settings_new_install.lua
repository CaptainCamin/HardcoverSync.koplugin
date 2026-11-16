--[[--
The settings screen on a clean installation: tracking and exact-identifier
auto-linking are on, title/author auto-linking is off.

Screens: settings_new_install, settings_new_install_links.
]]

local fixtures = require("fixtures")
local Device = require("device")

return {
  name = "settings_new_install",

  run = function(emu)
    local path = emu.DataStorage:getSettingsDir() .. "/hardcoversync_new_install.lua"
    os.remove(path)
    local HardcoverSettings = require("hardcover/lib/hardcover_settings")
    local SETTING = require("hardcover/lib/constants/settings")
    local settings = HardcoverSettings:new(path, emu:stub_ui(), { new_install = true })
    settings:updateSetting(SETTING.USER_ID, fixtures.USER_ID)
    fixtures.install({ settings = settings })

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings }
    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
    local menu = HardcoverMenu:new({
      settings = settings,
      enabled = true,
      dialog_manager = manager,
      sync_queue = { pendingCount = function() return 0 end, changeCount = function() return 0 end,
        hasPending = function() return false end },
      auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
               statusText = function() return "Signed in" end },
    })
    manager.settings_items = function() return menu:getHomeSettingsItems() end

    local screen = manager:showSettings()
    emu:pump()
    emu:screenNodes()
    emu:shot("settings_new_install")
    local W, H = Device.screen:getWidth(), Device.screen:getHeight()
    emu:tap(W - 10, H - 20) -- the scroll control's down triangle
    emu:pump()
    emu:screenNodes()
    emu:shot("settings_new_install_links")

    local function shows(text)
      for _, t in ipairs(screen.taps) do
        if t.shows:find(text, 1, true) then return t.shows end
      end
    end

    assert(shows("Always track progress by default|true|nil"), "tracking is not on by default")
    assert(shows("Automatically link by ISBN|true|nil"), "ISBN auto-linking is not on by default")
    assert(shows("Automatically link by Hardcover identifiers|true|nil"),
      "Hardcover-id auto-linking is not on by default")
    assert(shows("Automatically link by title and author|false|nil"),
      "title auto-linking is on by default")

    emu:closeAll()
    os.remove(path)
  end,
}