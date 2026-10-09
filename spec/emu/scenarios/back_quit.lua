--[[--
Back and Quit. Home, then Goals over it: the arrow at the left of Goals' title bar leaves
Goals and Home shows again. Lists opened over Goals, then the X at the right quits the
plugin: none of its screens is left on KOReader's window stack.
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

local function tap_button(emu, button)
  assert(button and button.dimen, "the title bar button is not painted")
  emu:tapExpecting(button.dimen.x + math.floor(button.dimen.w / 2), button.dimen.y + math.floor(button.dimen.h / 2))
  perf.run_loop()
end

return {
  name = "back_quit",

  run = function(emu)
    local manager, settings = perf.new_manager(emu, fixtures, "back_quit")
    local SETTING = require("hardcover/lib/constants/settings")
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    fixtures.install({ settings = settings })

    manager:showHome()
    perf.run_loop()
    local home = manager.home_dialog
    assert(UIManager:isWidgetShown(home), "home did not open")

    manager:showGoals()
    perf.run_loop()
    local goals = manager.goals_dialog
    assert(UIManager:isWidgetShown(goals), "goals did not open over home")
    assert(goals.title_bar.left_button, "goals has no arrow at the left: it is not a root screen")

    -- Back leaves goals; home is what shows again
    tap_button(emu, goals.title_bar.left_button)
    assert(not UIManager:isWidgetShown(goals), "back did not leave goals")
    assert(UIManager:isWidgetShown(home), "back did not show home again")

    -- Lists over goals, then X: the whole plugin goes, so nothing of it is left
    manager:showGoals()
    perf.run_loop()
    manager:showLists()
    perf.run_loop()
    local lists = manager.lists_dialog
    assert(UIManager:isWidgetShown(lists), "lists did not open")
    assert(#plugin_windows() >= 2, "expected lists and home on the window stack")

    -- the X closes the window it is in, so the tap is not "consumed" by a screen that is still
    -- there: judge it by what is left on the stack
    local X = lists.title_bar.right_button
    assert(X and X.dimen, "the X is not painted")
    emu:tap(X.dimen.x + math.floor(X.dimen.w / 2), X.dimen.y + math.floor(X.dimen.h / 2))
    perf.run_loop()
    local left = plugin_windows()
    assert(#left == 0, string.format("the X left %d plugin screen(s) open", #left))
    print("  quit: the X closed every plugin screen")
  end,
}
