--[[--
The settings screen built from the plugin's real menu items (Sync, Account, then the grouped
options), not made-up ones: open, scrolled to the end, and with two groups folded.

Screens: settings_real, settings_real_end, settings_real_folded.
]]

local fixtures = require("fixtures")
local Device = require("device")

return {
  name = "settings_real",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
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

    manager:showSettings()
    emu:pump()
    emu:screenNodes()
    emu:shot("settings_real")

    local W, H = Device.screen:getWidth(), Device.screen:getHeight()
    for _ = 1, 4 do
      emu:tap(W - 10, H - 20) -- the scroll control's down triangle
      emu:pump()
      emu:screenNodes()
    end
    emu:shot("settings_real_end")
    emu:closeAll()

    local screen = manager:showSettings()
    emu:pump()
    emu:screenNodes()
    for _, name in ipairs({ "Books", "Home & display" }) do
      local head
      for _, t in ipairs(screen.taps) do
        if t.shows:find("section|" .. name .. "|", 1, true) then head = t.tap.dimen end
      end
      assert(head, "no heading for " .. name)
      emu:tapExpecting(head.x + 5, head.y + 5)
      emu:pump()
      emu:screenNodes()
    end
    emu:shot("settings_real_folded")
    emu:closeAll()
  end,
}
