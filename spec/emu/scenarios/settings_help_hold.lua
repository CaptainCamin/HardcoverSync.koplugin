--[[--
A settings option's help is a single line under its label, cut with an ellipsis when it is longer, so
holding the row opens a dialog with all of it. A row with no help does nothing on a hold.

Screens: settings_help_line, settings_help_full.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local HELP = "Sends the page you are on to Hardcover every few minutes while you read, and again when you close the book, so your progress follows you to other devices."

return {
  name = "settings_help_hold",

  run = function(emu)
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local SettingsDialog = require("hardcover/lib/ui/settings_dialog")

    local items = {
      { text = "Update Hardcover as I read", help = HELP,
        checked_func = function() return true end, callback = function() end },
      { text = "Show covers in lists", checked_func = function() return false end, callback = function() end },
    }
    SettingsDialog.show { title = "Settings", items = items, on_close = function() end }
    emu:pump()
    emu:screenNodes()
    emu:shot("settings_help_line")

    -- holding a row with no help does nothing
    local plain = emu:expectText("Show covers in lists")
    local before = #UIManager._window_stack
    emu:tap(plain.x + 5, plain.y + 5, { ges = emu.GESTURES.Hold })
    assert(#UIManager._window_stack == before, "holding a row with no help opened something")

    -- holding a row with help shows all of it
    local row = emu:expectText("Update Hardcover as I read")
    emu:tap(row.x + 5, row.y + 5, { ges = emu.GESTURES.Hold })
    emu:pump()
    emu:screenNodes()
    emu:shot("settings_help_full")
    emu:expectText("every few minutes")
  end,
}
