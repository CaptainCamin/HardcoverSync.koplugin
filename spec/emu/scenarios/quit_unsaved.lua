--[[--
Quit with a goal form that has changes in it. The X closes a form with nothing changed,
and asks nothing. With a changed target it asks first ("Discard your changes and quit?"):
Cancel keeps the form and Goals open, and Discard closes every plugin screen.
]]

local fixtures = require("fixtures")
local perf = require("perf")
local UIManager = require("ui/uimanager")
local ScreenRegistry = require("hardcover/lib/screen_registry")

local function plugin_windows()
  local stack = {}
  for i = #UIManager._window_stack, 1, -1 do stack[#stack + 1] = UIManager._window_stack[i].widget end
  return ScreenRegistry.pluginWindows(stack)
end

local function top() return UIManager:getTopmostVisibleWidget() end

-- Tap the button whose painted text is exactly `label`. expectText matches a substring
-- and returns the first node containing it, which can be the question instead ("Discard"
-- is in "Discard your changes and quit?"), so the whole text is matched here.
-- `closes`: the button takes down everything it is on, so nothing is left to consume the
-- tap (emu:tapExpecting would fail); the caller checks what is left instead.
local function tap_label(emu, label, closes)
  emu:expectText(label)
  for _, node in ipairs(emu:screenNodes()) do
    if node.text == label then
      assert(node.x and node.w, "'" .. label .. "' is not painted")
      local x, y = node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2)
      if closes then
        emu:tap(x, y)
      else
        emu:tapExpecting(x, y)
      end
      perf.run_loop()
      return
    end
  end
  error("no button '" .. label .. "' on screen:\n" .. emu:screenText())
end

local function tap_row(emu, form, key)
  emu:screenNodes()
  local row = form.row_taps[key]
  assert(row and row.dimen, "no row " .. key)
  emu:tapExpecting(row.dimen.x + math.floor(row.dimen.w / 2), row.dimen.y + math.floor(row.dimen.h / 2))
  perf.run_loop()
end

-- The X of the form's title bar. Read after a paint: a change rebuilds the bar.
local function tap_x(emu, form)
  emu:screenNodes()
  local X = form.title_bar.right_button
  assert(X and X.dimen, "the X is not painted")
  emu:tap(X.dimen.x + math.floor(X.dimen.w / 2), X.dimen.y + math.floor(X.dimen.h / 2))
  perf.run_loop()
end

-- Goals, then New goal: the form opens over Goals. Returns the form and the Goals screen.
local function open_form(manager, emu)
  manager:showGoals()
  perf.run_loop()
  local goals = manager.goals_dialog
  assert(UIManager:isWidgetShown(goals), "goals did not open")
  tap_label(emu, "New goal")
  local form = top()
  assert(form and form.name == "hardcover_goal_form", "New goal did not open the form: " .. tostring(form and form.name))
  return form, goals
end

return {
  name = "quit_unsaved",

  run = function(emu)
    local manager, settings = perf.new_manager(emu, fixtures, "quit_unsaved")
    local SETTING = require("hardcover/lib/constants/settings")
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    fixtures.install({ settings = settings })

    -- nothing changed: the X closes the form and Goals under it, and asks nothing
    local form = open_form(manager, emu)
    assert(UIManager:isWidgetShown(form), "the form is not shown")
    assert(not form:unsavedChanges(), "a form with nothing changed reports changes")
    tap_x(emu, form)
    local left = plugin_windows()
    assert(#left == 0, string.format("the X left %d plugin screen(s) open", #left))
    for _, node in ipairs(emu:screenNodes()) do
      assert(not node.text:find("Discard your changes", 1, true), "a question was asked with nothing to lose")
    end

    -- a changed target: the form now has changes
    form, goals = open_form(manager, emu)
    tap_row(emu, form, "target")
    local input = top()
    assert(input and input.getInputText, "the target row did not open a text box: " .. tostring(input and input.name))
    input:setInputText("20")
    tap_label(emu, "Set")
    assert(form.form.target == 20, "target is " .. tostring(form.form.target))
    assert(form:unsavedChanges(), "a changed form does not report changes")

    -- the X asks first: the form and Goals stay, with the question on top
    tap_x(emu, form)
    assert(UIManager:isWidgetShown(form), "the X closed a form with changes")
    assert(UIManager:isWidgetShown(goals), "the X closed Goals before asking")
    emu:expectText("Discard your changes and quit?")
    assert(top() ~= form, "no question is on top of the form")

    -- Cancel: the question goes, and nothing else does
    tap_label(emu, "Cancel")
    assert(top() == form, "Cancel did not close the question")
    assert(UIManager:isWidgetShown(form), "Cancel closed the form")
    assert(UIManager:isWidgetShown(goals), "Cancel closed Goals")

    -- the X again, then Discard: every plugin screen goes
    tap_x(emu, form)
    emu:expectText("Discard your changes and quit?")
    tap_label(emu, "Discard", true)
    left = plugin_windows()
    assert(#left == 0, string.format("Discard left %d plugin screen(s) open", #left))
    for _, node in ipairs(emu:screenNodes()) do
      assert(not node.text:find("Discard your changes", 1, true), "the question is still on screen")
    end

    print("  quit: a form with changes asks first; Cancel keeps it, Discard quits")
    emu:closeAll()
  end,
}
