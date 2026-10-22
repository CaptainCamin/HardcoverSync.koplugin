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

    local saved
    local dialog = JournalDialog:new {
      input = "A note typed on the emulator",
      event_type = "note",
      book_id = 106,
      edition_id = 10600,
      edition_format = "Paperback",
      page = 42,
      pages = 1200,
      save_dialog_callback = function(entry) saved = entry; return true, "note saved" end,
      close_callback = function() end,
    }

    UIManager:show(dialog)
    emu:pump()

    assert(UIManager:isWidgetShown(dialog), "journal dialog was built but never shown")
    emu:expectText("Add a note")
    -- The typed text has to be on the form, or the dialog is a shell.
    emu:expectText("A note typed on the emulator")
    emu:expectText("Paperback")
    emu:expectText("Page 42 of 1200")
    emu:shot("journal_entry")

    local function tapText(text)
      local node = emu:expectText(text)
      emu:tapExpecting(node.x + 5, node.y + 5)
      emu:pump()
    end

    -- the text is written in the input dialog, over the keyboard
    local d = dialog.row_taps.text.dimen
    emu:tapExpecting(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
    emu:pump()
    local top = UIManager:getTopmostVisibleWidget()
    local editor
    for _, w in ipairs(UIManager._window_stack) do
      if w.widget.name == "hardcover_input_dialog" then editor = w.widget end
    end
    assert(editor, "tapping the text did not open the editor")
    emu:shot("journal_editor")
    editor:onCloseKeyboard()
    emu:pump()
    editor:setInputText("Rewritten on the emulator")
    tapText("Done")
    assert(UIManager:getTopmostVisibleWidget() == dialog, "the editor stayed open: " .. tostring(top and top.name))
    emu:expectText("Rewritten on the emulator")

    -- the type is chosen from a list, and the title follows it
    tapText("Type")
    emu:expectText("Quote")
    tapText("Quote")
    emu:expectText("Add a quote")

    -- Save hands everything over
    tapText("Save")
    assert(saved and saved.text == "Rewritten on the emulator" and saved.event_type == "quote"
      and saved.page == 42 and saved.edition_id == 10600,
      "the entry was not handed over whole")

    print("  journal form built, text edited, type chosen, entry saved")
  end,
}
