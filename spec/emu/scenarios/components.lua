--[[--
The MMD components (hardcover/lib/ui/components) drawn and tapped for real: a settings-style page with
a top bar, tabs, list items (switch, checkbox, radio, chevron) and a nav bar, then each overlay over a
shelf-like page: the popover, the choice sheet, the action sheet, the dialog and the snackbar. Every tap
is made with the real gesture path and checked against what it should do.

Screens: components_page, components_popover, components_choice, components_action, components_dialog,
components_snackbar.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")
local Device = require("device")

return {
  name = "components",

  run = function(emu)
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local Theme = require("hardcover/lib/ui/theme")
    local Draw = require("hardcover/lib/ui/components/draw")
    local ListItem = require("hardcover/lib/ui/components/list_item")
    local Switch = require("hardcover/lib/ui/components/switch")
    local Radio = require("hardcover/lib/ui/components/radio")
    local Checkbox = require("hardcover/lib/ui/components/checkbox")
    local TopBar = require("hardcover/lib/ui/components/top_bar")
    local Tabs = require("hardcover/lib/ui/components/tabs")
    local NavBar = require("hardcover/lib/ui/components/nav_bar")
    local Popover = require("hardcover/lib/ui/components/popover")
    local ChoiceSheet = require("hardcover/lib/ui/components/choice_sheet")
    local ActionSheet = require("hardcover/lib/ui/components/action_sheet")
    local Dialog = require("hardcover/lib/ui/components/dialog")
    local Snackbar = require("hardcover/lib/ui/components/snackbar")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local HorizontalGroup = require("ui/widget/horizontalgroup")

    local SW, SH = Device.screen:getWidth(), Device.screen:getHeight()
    local got = {}

    local state = { sync = true, covers = false, link = false, tab = 1 }
    local page
    local function build()
      local bar = TopBar.new { width = SW, title = "Settings", on_back = function() got.back = true end,
        actions = { { icon = "search", callback = function() got.search = true end },
                    { icon = "sort", callback = function()
                        got.sort = true
                        Popover.show { x = SW - Theme.px(12), y = Theme.mmd.top_bar.h + Theme.px(4),
                          items = { { label = "Date added", callback = function() got.popover = "added" end },
                                    { label = "Title", current = true, callback = function() got.popover = "title" end },
                                    { label = "Author", callback = function() got.popover = "author" end } } }
                      end } } }
      local tabs = Tabs.new { width = SW, tabs = {
        { label = "General", active = state.tab == 1, callback = function() state.tab = 1 end },
        { label = "Sync", active = state.tab == 2, callback = function() state.tab = 2 end },
        { label = "Account", active = state.tab == 3, count = 2, callback = function() state.tab = 3 end } } }
      local body = VerticalGroup:new { align = "left", bar, tabs, ListItem.section("Library", SW) }
      body[#body + 1] = ListItem.new { width = SW, label = "Track progress", support = "Send pages read to Hardcover",
        trailing = Switch.new { on = state.sync }, divider = "dotted", callback = function() state.sync = not state.sync; got.sync = state.sync end }
      body[#body + 1] = ListItem.new { width = SW, label = "Show covers in lists", support = "Uses more battery",
        trailing = Switch.new { on = state.covers }, divider = "dotted", callback = function() state.covers = not state.covers end }
      body[#body + 1] = ListItem.new { width = SW, label = "Automatic linking", support = "Not available offline",
        trailing = Switch.new { unavailable = true }, divider = "dotted" }
      body[#body + 1] = ListItem.new { width = SW, label = "Link by ISBN",
        trailing = Checkbox.new { checked = state.link }, divider = "dotted", callback = function() state.link = not state.link end }
      body[#body + 1] = ListItem.new { width = SW, label = "Sort by", support = "Title",
        trailing = Draw.chevron("right"), divider = "dotted", callback = function()
          ChoiceSheet.show { title = "Sort by", current = "title",
            options = { { key = "added_desc", label = "Date added" }, { key = "title", label = "Title" },
                        { key = "author", label = "Author" }, { key = "year_desc", label = "Newest first" } },
            on_choose = function(key) got.choice = key end }
        end }
      body[#body + 1] = ListItem.new { width = SW, label = "Radio row", trailing = Radio.new { selected = true } }
      local nav = NavBar.new { width = SW, items = {
        { label = "Home", icon = Draw.ICONS.info, active = true },
        { label = "Library", icon = Draw.ICONS.search },
        { label = "Goals", icon = Draw.ICONS.sort },
        { label = "Stats", icon = Draw.ICONS.back } } }
      local filler = SH - body:getSize().h - nav:getSize().h
      body[#body + 1] = Theme.span(math.max(0, filler))
      body[#body + 1] = nav
      body:resetLayout() -- the size was asked for before these were added
      return FrameContainer:new { width = SW, height = SH, background = Theme.WHITE, bordersize = 0,
        padding = 0, margin = 0, body }
    end

    page = build()
    UIManager:show(page)
    emu:pump()
    emu:screenNodes()
    emu:shot("components_page")
    local covers_row = emu:expectText("Show covers in lists")

    local function tapText(text)
      local node = emu:expectText(text)
      emu:tapExpecting(node.x + 5, node.y + 5)
      emu:pump()
    end

    -- a row toggles from anywhere on the row
    tapText("Track progress")
    assert(got.sync == false, "tapping a switch row did not toggle it")

    -- the sort icon opens the popover; a choice closes it and runs its callback
    emu:tapExpecting(SW - Theme.px(12) - Theme.px(24), Theme.px(33))
    assert(got.sort, "the sort action did not run")
    emu:pump()
    emu:expectText("Author")
    emu:shot("components_popover")
    tapText("Author")
    assert(got.popover == "author", "popover item did not run")
    assert(UIManager:getTopmostVisibleWidget() == page, "the popover stayed open after a choice")

    -- the choice sheet: radio rows, X, no Cancel; choosing closes it
    tapText("Sort by")
    emu:expectText("Newest first")
    for _, node in ipairs(emu:screenNodes()) do assert(node.text ~= "Cancel", "a choice sheet has no Cancel") end
    emu:shot("components_choice")
    tapText("Newest first")
    assert(got.choice == "year_desc", "choice sheet did not report the key")
    assert(UIManager:getTopmostVisibleWidget() == page, "the sheet stayed open after a choice")

    -- a tap outside a sheet dismisses it without choosing
    got.choice = nil
    tapText("Sort by")
    emu:screenNodes() -- paint: tap ranges are only real once painted
    emu:tapExpecting(SW / 2, Theme.px(40))
    assert(got.choice == nil, "tap outside chose " .. tostring(got.choice))
    assert(UIManager:getTopmostVisibleWidget() == page, "tap outside did not dismiss the sheet")

    -- action sheet
    local ran
    ActionSheet.show { title = "The Dispossessed", text = "On Want to read",
      actions = { { label = "Move to Read", callback = function() ran = "move" end },
                  { label = "Remove from shelf", callback = function() ran = "remove" end } } }
    emu:pump()
    emu:shot("components_action")
    emu:expectText("Cancel")
    tapText("Remove from shelf")
    assert(ran == "remove", "action sheet button did not run")
    assert(UIManager:getTopmostVisibleWidget() == page, "action sheet stayed open")

    -- dialog: two stacked buttons, the filled one first
    local answer
    Dialog.show { title = "Discard queued changes?", text = "Three changes have not reached Hardcover yet. They will be lost.",
      buttons = { { label = "Discard", primary = true, callback = function() answer = "discard" end },
                  { label = "Keep", callback = function() answer = "keep" end } } }
    emu:pump()
    emu:shot("components_dialog")
    tapText("Keep")
    assert(answer == "keep", "dialog button did not run")
    assert(UIManager:getTopmostVisibleWidget() == page, "dialog stayed open")

    -- the warning configurations: a single action, and the X with no buttons
    local acknowledged
    Dialog.show { warning = true, title = "Reset progress?", text = "This cannot be undone.",
      buttons = { { label = "Proceed with reset", callback = function() acknowledged = true end } } }
    emu:pump()
    emu:shot("components_dialog_warning")
    tapText("Proceed with reset")
    assert(acknowledged, "single-action button did not run")
    assert(UIManager:getTopmostVisibleWidget() == page, "warning dialog stayed open")
    Dialog.show { warning = true, title = "Sync is paused", text = "Changes will wait until you are online." }
    emu:pump()
    emu:shot("components_dialog_close")
    UIManager:getTopmostVisibleWidget():dismiss()
    assert(UIManager:getTopmostVisibleWidget() == page, "close-only dialog stayed open")

    -- input dialog: a field above the keyboard, the filled button runs with what was typed
    local InputDialog = require("hardcover/lib/ui/components/input_dialog")
    local typed
    local box
    box = InputDialog:new { title = "Goal name", text = "What you call it.", input = "Read more", hint = "Name",
      buttons = { { label = "Cancel", callback = function() UIManager:close(box) end },
                  { label = "Set", primary = true, callback = function() typed = box:getInputText(); UIManager:close(box) end } } }
    UIManager:show(box)
    emu:pump()
    emu:expectText("Goal name")
    emu:shot("components_input")
    -- the keyboard is a window of its own on top: look at it, then put it down to tap the dialog
    box:onShowKeyboard()
    emu:pump()
    emu:shot("components_input_keyboard")
    assert(box:isKeyboardVisible(), "the keyboard did not come up")
    box:onCloseKeyboard()
    emu:pump()
    box:setInputText("Twelve books")
    tapText("Set")
    assert(typed == "Twelve books", "the input dialog returned " .. tostring(typed))
    assert(UIManager:getTopmostVisibleWidget() == page, "the input dialog stayed open")

    -- progress dialog: a bar, a visible Stop that is acknowledged, and a tap outside does nothing
    local ProgressDialog = require("hardcover/lib/ui/components/progress_dialog")
    local stopped
    local job = ProgressDialog.show { title = "Saving book details...", text = "3 of 10 books", fraction = 0.3,
      stop = { callback = function() stopped = true end } }
    emu:pump()
    emu:shot("components_progress")
    local top = UIManager:getTopmostVisibleWidget()
    emu:tap(5, 5)
    assert(UIManager:getTopmostVisibleWidget() == top, "a tap outside closed the progress dialog")
    job:update { text = "4 of 10 books", fraction = 0.4 }
    emu:pump()
    emu:expectText("4 of 10 books")
    tapText("Stop")
    assert(stopped, "Stop did not run")
    emu:expectText("Stopping")
    job:close()
    assert(UIManager:getTopmostVisibleWidget() == page, "the progress dialog stayed open")

    -- snackbar: the rest of the screen keeps working; only the bar takes taps, and its action runs
    local undone
    Snackbar.show { message = "Moved to Read", action = { label = "Undo", callback = function() undone = true end } }
    emu:pump()
    emu:shot("components_snackbar")
    local snack = UIManager:getTopmostVisibleWidget()
    assert(snack.snackbar, "the snackbar is not on top")
    local covers = state.covers
    emu:tap(covers_row.x + 5, covers_row.y + 5)
    assert(state.covers ~= covers, "a tap on the page was blocked while the snackbar was up")
    assert(UIManager:getTopmostVisibleWidget() == snack, "a tap elsewhere closed the snackbar")
    local node = emu:expectText("Undo")
    emu:tap(node.x + 5, node.y + 5)
    assert(undone, "the snackbar action did not run")
    assert(UIManager:getTopmostVisibleWidget() == page, "the snackbar stayed after its action")

    -- a tap on the bar is spent there: a window under it (a row, a page-turn zone) never hears it
    local InputContainer = require("ui/widget/container/inputcontainer")
    local GestureRange = require("ui/gesturerange")
    local Geom = require("ui/geometry")
    local heard = 0
    local probe = InputContainer:new { dimen = Geom:new { x = 0, y = 0, w = SW, h = SH } }
    probe.ges_events = { Tap = { GestureRange:new { ges = "tap", range = probe.dimen } } }
    function probe:onTap() heard = heard + 1 return true end
    UIManager:show(probe)
    Snackbar.show { message = "Saved" }
    emu:pump()
    emu:tap(SW / 2, SH - Theme.px(10))
    assert(heard == 0, "a tap on the snackbar also reached the window under it")
    emu:tap(SW / 2, Theme.px(300))
    assert(heard == 1, "a tap off the snackbar did not reach the window under it")
    UIManager:close(UIManager:getTopmostVisibleWidget()) -- the snackbar
    UIManager:close(probe)
    emu:pump()
    assert(UIManager:getTopmostVisibleWidget() == page, "the snackbar did not close")

    UIManager:close(page)
    emu:pump()
  end,
}
