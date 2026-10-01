--[[--
Journal entry: the dialog behind "Add a note".

The one screen with a keyboard in it, so it exercises the virtual keyboard and
the editable text box -- the paths where a widget can be built successfully and
still be unusable.

Screens: journal_entry.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

return {
  name = "journal",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })

    local DialogManager = require("hardcover/lib/ui/dialog_manager")

    local manager = DialogManager:new{ settings = settings }

    --[[--
    Build the dialog directly rather than through journalEntryForm: that
    wrapper prompts for wifi first, which is a networking concern and would
    make this scenario depend on a connection being faked too.
    ]]
    local JournalDialog = require("hardcover/lib/ui/journal_dialog")

    local dialog = JournalDialog:new {
      input = "A note typed on the emulator",
      event_type = "note",
      book_id = 106,
      edition_id = 10600,
      edition_format = "Paperback",
      page = 42,
      pages = 1200,
      save_dialog_callback = function() return true, "note saved" end,
      close_callback = function() end,
    }

    UIManager:show(dialog)
    emu:pump()

    assert(UIManager:isWidgetShown(dialog), "journal dialog was built but never shown")

    -- The typed text has to be in the input widget, or the dialog is a shell.
    assert(dialog._input_widget, "journal dialog has no input widget")
    assert(dialog._input_widget.text:find("emulator", 1, true),
      "input widget does not hold the text it was given: " ..
      tostring(dialog._input_widget.text))

    emu:shot("journal_entry")

    -- The keyboard, if it opened, must not cover the action buttons.
    local clashes = emu.Tree.overlapping_pairs(dialog, { Button = true })
    if #clashes > 0 then
      local lines = {}
      for _, c in ipairs(clashes) do
        lines[#lines + 1] = string.format("%s <-> %s (%dx%d px)",
          tostring(c.a), tostring(c.b), c.overlap_x, c.overlap_y)
      end
      error("buttons overlap:\n  " .. table.concat(lines, "\n  "), 2)
    end

    print("  journal entry dialog built, typed text present, buttons disjoint")
  end,
}
