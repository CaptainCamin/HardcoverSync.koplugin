--[[--
About, from the settings screen: the version, the project and the settings file
path, with the "latest release" note filled in (or dropped) afterwards.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

return {
  name = "about",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })

    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
    local menu = HardcoverMenu:new({
      settings = settings,
      enabled = true,
      sync_queue = { pendingCount = function() return 0 end, hasPending = function() return false end },
      auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
               statusText = function() return "Signed in" end },
    })
    local items = menu:getHomeSettingsItems()
    local about
    for _, item in ipairs(items) do
      if item.text == "About" then about = item end
    end
    assert(about, "no About item")

    about.callback({ updateItems = function() end })
    emu:pump()
    emu:expectText("Hardcover Sync")
    emu:expectText("HardcoverSync.koplugin")
    emu:shot("about")
    emu:closeAll()
  end,
}
