--[[--
The shell: Home, Library, Goals and Stats as tabs of one screen with a navigation bar. Home (fixed, never
scrolls) and Goals are hosted bodies (Library and Stats are still placeholders). Checked for real:
tapping the bar changes the tab; a tab keeps its body (so its scroll position) when left and
reopened; an answer that arrives for a hidden tab is on screen when the tab is opened; a goal opened
from the Goals tab stacks over the shell and closing it reveals the shell, live; Back goes to the
first tab, then leaves; the registry reaches the hosted body while the shell is up.

Screens: shell_home, shell_goals, shell_goals_hidden_update.
]]

local fixtures = require("fixtures")
local Goals = require("hardcover/lib/goals")
local UIManager = require("ui/uimanager")
local Device = require("device")

local function find_tap(widget, label, seen)
  seen = seen or {}
  if type(widget) ~= "table" or seen[widget] then return end
  seen[widget] = true
  if widget.name == "hardcover_tap_row" and widget[1] then
    local found
    local function has(w, depth)
      if type(w) ~= "table" or depth > 12 then return end
      if type(w.text) == "string" and w.text:find(label, 1, true) then found = true return end
      for _, c in ipairs(w) do has(c, depth + 1) end
    end
    has(widget[1], 0)
    if found then return widget end
  end
  for _, c in ipairs(widget) do
    local r = find_tap(c, label, seen)
    if r then return r end
  end
end

return {
  name = "shell",

  run = function(emu)
    local function iso(d)
      local t = os.date("*t", os.time() + d * 86400)
      return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
    end
    local rows = {
      { id = 3, goal = 70, metric = "book", description = "Year Reading Goal", start_date = iso(-200), end_date = iso(165), progress = 46.0, archived = false },
      { id = 5, goal = 3000, metric = "page", description = "Pages this month", start_date = iso(-10), end_date = iso(20), progress = 150.0, archived = false },
    }
    local settings = fixtures.real_settings(emu)
    local SETTING = require("hardcover/lib/constants/settings")
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    settings:updateSetting(SETTING.NEW_NAVIGATION, true)
    fixtures.install({ settings = settings, goals_rows = rows })

    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_shell.lua"
    os.remove(path)
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local pending = 0
    local manager = DialogManager:new { settings = settings,
      sync_queue = { finishedCount = function() return 0 end, pendingCount = function() return pending end },
      shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end } }

    local W, H = Device.screen:getWidth(), Device.screen:getHeight()
    local function nav(i) -- tap the i-th of four destinations in the bar
      emu:screenNodes()
      emu:tapExpecting(math.floor((i - 0.5) * W / 4), H - Device.screen:scaleBySize(26))
      emu:pump()
    end

    manager:showHome()
    emu:pump()
    local shell = UIManager:getTopmostVisibleWidget()
    assert(shell and shell.name == "hardcover_shell", "Home did not open the shell: " .. tostring(shell and shell.name))
    assert(shell.active == "home", "the shell should open on Home")
    emu:screenNodes()
    emu:shot("shell_home")
    emu:expectText("Currently reading")
    emu:expectText("All synced")
    local home = shell.bodies.home
    assert(home and home.shell == shell and not home.scroll, "Home must be a body that never scrolls")
    pending = 2
    home:rebuild()
    emu:pump()
    emu:expectText("2 changes waiting to sync")
    pending = 0
    home:rebuild()

    -- books being read: the cards come first, as many as fit, and the page never scrolls; the
    -- shelves go before the last card does, then the sync line
    home:setReading(fixtures.currently_reading)
    home:rebuild()
    emu:pump()
    emu:expectText("The Dispossessed")
    emu:shot("shell_home_cards")
    local L = home.layout
    assert(not home.scroll, "Home scrolled with cards")
    assert(L.cards >= 1, "Home dropped every card")
    print(string.format("        home at %dx%d: %d cards, note=%s, shelves=%s", W, H, L.cards, tostring(L.note), tostring(L.shelves)))
    if H < 900 or W > H then
      assert(L.cards == 1 or not L.shelves, "a small screen kept the shelves over cards")
    end
    local bottom = home.dimen.y + home.dimen.h
    assert(bottom <= H - require("hardcover/lib/ui/components/nav_bar").HEIGHT, "Home reaches into the nav bar")

    -- to Goals: the saved copy is empty, so it loads; the answer comes in
    nav(3)
    assert(shell.active == "goals", "the Goals tab did not open: " .. shell.active)
    emu:pump()
    emu:expectText("Year Reading Goal")
    emu:shot("shell_goals")
    local body = shell.bodies.goals
    assert(body and body.shell == shell, "Goals is not hosted by the shell")
    assert(manager:screens():open("goals") == body, "the registry cannot reach the hosted body")

    -- away and back: the same body, not a rebuilt one
    nav(1)
    assert(shell.active == "home")
    nav(3)
    assert(shell.bodies.goals == body, "the Goals body was rebuilt on return")

    -- an answer for a hidden tab: shown when the tab is opened
    nav(1)
    body:setMessage("Updated while hidden")
    nav(3)
    emu:pump()
    emu:expectText("Updated while hidden")
    emu:shot("shell_goals_hidden_update")
    body:setGoals(require("hardcover/lib/goals").normalize(rows))
    emu:pump()

    -- a goal opened from the tab stacks over the shell; closing it reveals the live shell
    emu:screenNodes()
    local card = find_tap(body, "Year Reading Goal")
    assert(card, "no tappable goal card on the Goals tab")
    emu:tapExpecting(card.dimen.x + 10, card.dimen.y + 10)
    emu:pump()
    local one = UIManager:getTopmostVisibleWidget()
    assert(one and one.name == "hardcover_goal", "the card did not open the goal: " .. tostring(one and one.name))
    one:onClose()
    emu:pump()
    assert(UIManager:getTopmostVisibleWidget() == shell, "closing the goal did not reveal the shell")
    assert(require("hardcover/lib/ui/live").shown(body), "the body is not live after a screen closed over it")

    -- Back: a tab goes to the first tab, the first tab leaves
    shell:onBack()
    assert(shell.active == "home", "Back from a tab did not go to the first tab")
    emu:pump()
    shell:onBack()
    emu:pump()
    assert(UIManager:getTopmostVisibleWidget() ~= shell, "Back on the first tab did not leave")
    assert(not require("hardcover/lib/ui/live").shown(body), "the body is still live after its shell left")
  end,
}
