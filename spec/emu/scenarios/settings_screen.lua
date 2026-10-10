--[[--
The settings screen in the MMD style: a top bar with a back arrow, the Sync and Account tiles as the
first two rows, switches for on/off options, a chevron into a submenu, a hollow-knob switch for an option
that is unavailable, dotted dividers. Taps are real: a row toggles from anywhere on it, a submenu
opens, the back arrow goes up one level and then leaves the screen, and an unavailable row does
nothing.

Screens: settings_screen, settings_screen_sub, settings_screen_scrolled.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")
local Device = require("device")

return {
  name = "settings_screen",

  run = function(emu)
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local SettingsDialog = require("hardcover/lib/ui/settings_dialog")

    local state = { track = true, covers = false, wifi = false, closed = false, synced = 0, linked = false }
    local items = {
      { tile = "Sync", text = "Sync: 2 changes waiting", callback = function() state.synced = state.synced + 1 end },
      { tile = "Account", text = "Account: Signed in as captaincamin", callback = function() end },
      { text = "Update Hardcover as I read", checked_func = function() return state.track end,
        callback = function() state.track = not state.track end },
      { text = "Show covers in lists", checked_func = function() return state.covers end,
        callback = function() state.covers = not state.covers end },
      { text = "Enable wifi on demand", checked_func = function() return state.wifi end,
        callback = function() state.wifi = not state.wifi end, separator = true },
      { text = "Automatically link by ISBN", checked_func = function() return state.linked end,
        enabled_func = function() return false end, callback = function() state.linked = true end },
      { text = "Track progress settings", sub_item_table = {
          { text = "Track by percentage", checked_func = function() return true end, callback = function() end },
          { text = "Track by pages", checked_func = function() return false end, callback = function() end },
        } },
      { text = "Sign out", callback = function() end },
    }
    local screen = SettingsDialog.show { title = "Settings", items = items,
      on_close = function() state.closed = true end }
    emu:pump()
    emu:screenNodes() -- paint
    emu:shot("settings_screen")
    emu:expectText("Update Hardcover as I read")

    -- a switch row toggles from the middle of the row, not only on the switch
    local node = emu:expectText("Update Hardcover as I read")
    emu:tapExpecting(node.x + 5, node.y + 5)
    emu:pump()
    assert(state.track == false, "tapping the row did not flip the switch")
    emu:screenNodes()

    -- an unavailable option does nothing
    local dim = emu:expectText("Automatically link by ISBN")
    emu:tapExpecting(dim.x + 5, dim.y + 5)
    assert(state.linked == false, "an unavailable option ran")

    -- a submenu opens, and the back arrow goes up one level
    local sub = emu:expectText("Track progress settings")
    emu:tapExpecting(sub.x + 5, sub.y + 5)
    emu:pump()
    emu:expectText("Track by percentage")
    emu:shot("settings_screen_sub")
    emu:tapExpecting(Device.screen:scaleBySize(30), Device.screen:scaleBySize(30))
    emu:pump()
    emu:expectText("Update Hardcover as I read")
    assert(not state.closed, "back inside a submenu left the screen")

    -- at the top, back leaves the screen
    emu:screenNodes()
    emu:tap(Device.screen:scaleBySize(30), Device.screen:scaleBySize(30)) -- nothing is left to take it
    emu:pump()
    assert(state.closed, "back at the top did not leave the screen")

    -- a long page scrolls by whole pages with the control
    local many = {}
    for i = 1, 24 do
      many[i] = { text = "Option number " .. i, checked_func = function() return i % 2 == 0 end, callback = function() end }
    end
    local long = SettingsDialog.show { title = "Settings", items = many }
    emu:pump()
    assert(long.scroll, "a long page should scroll")
    emu:screenNodes()
    local W, H = Device.screen:getWidth(), Device.screen:getHeight()
    emu:tapExpecting(W - 10, H - 20) -- the control's down triangle
    emu:pump()
    emu:screenNodes()
    assert(long.scroll:getScrolledOffset().y > 0, "the down triangle did not scroll")
    emu:shot("settings_screen_scrolled")
    UIManager:close(long)
    emu:pump()
  end,
}
