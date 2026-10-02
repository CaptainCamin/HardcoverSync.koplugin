--[[--
Reading goals: the card on Home (the goal that is nearest to ending and not done), the
Goals screen (current goals as cards, past ones as rows), one goal opened, and the
same offline from the saved copy -- with a book finished offline counted.

"Today" is whatever the emulator's clock says, so the screens are checked by what
they say about the fixture goals relative to it, not by exact numbers.

Screens: goals_home, goals_screen, goals_one, goals_offline, goals_offline_one.
]]

local fixtures = require("fixtures")
local Goals = require("hardcover/lib/goals")
local UIManager = require("ui/uimanager")

local function new_manager(emu, settings, name, queue)
  local LuaSettings = require("luasettings")
  local ShelfCache = require("hardcover/lib/shelf_cache")
  local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_" .. name .. ".lua"
  local DialogManager = require("hardcover/lib/ui/dialog_manager")
  return DialogManager:new {
    settings = settings,
    sync_queue = queue,
    shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end },
  }, path
end

local function tap_widget(emu, widget)
  emu:screenNodes() -- paint: tap ranges are only real once painted
  local d = widget.dimen
  assert(d and d.w and d.w > 0, "the widget has no painted rectangle")
  emu:tapExpecting(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
  emu:pump()
end

-- Home scrolls when it is taller than the screen: bring the bottom into view
local function scroll_bottom(emu, home)
  emu:pump()
  emu:screenNodes()
  if home.scroll then
    home.scroll:scrollToRatio(0, 1)
    UIManager:setDirty(home, "ui")
    emu:screenNodes()
  end
end

-- the TapRow under a goal's heading text, found by what it says
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
  name = "goals",

  run = function(emu)
    local today = Goals.today()
    -- rewrite the fixture goals around today, so they are "current" whenever this runs
    local function around(days_ago_start, days_ahead_end)
      local function iso(d)
        local y, m, dd = os.date("*t", os.time() + d * 86400).year, os.date("*t", os.time() + d * 86400).month, os.date("*t", os.time() + d * 86400).day
        return string.format("%04d-%02d-%02d", y, m, dd)
      end
      return iso(-days_ago_start), iso(days_ahead_end)
    end
    local s1, e1 = around(200, 165)
    local s2, e2 = around(10, 20)
    local s3, e3 = around(500, -135)
    local rows = {
      { id = 3, goal = 70, metric = "book", description = "Year Reading Goal", start_date = s1, end_date = e1, progress = 46.0, archived = false },
      { id = 4, goal = 30, metric = "book", description = "Year Reading Goal", start_date = s1, end_date = e1, progress = 46.0, archived = false },
      { id = 5, goal = 3000, metric = "page", description = "Pages this month", start_date = s2, end_date = e2, progress = 150.0, archived = false },
      { id = 2, goal = 100, metric = "book", description = "Last Year Reading Goal", start_date = s3, end_date = e3, progress = 77.0, archived = false },
      { id = 1, goal = 5, metric = "book", description = "An archived goal", start_date = s3, end_date = e3, progress = 0.0, archived = true },
    }

    local settings = fixtures.real_settings(emu)
    local SETTING = require("hardcover/lib/constants/settings")
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    fixtures.install({ settings = settings, goals_rows = rows })

    local queue_finished = 0
    local queue = { finishedCount = function() return queue_finished end }
    local manager, cache_path = new_manager(emu, settings, "goals", queue)
    os.remove(cache_path)

    -- Home: the card appears once the goals are fetched; it is the 70-book goal (the
    -- unfinished one), not the one that is already done, and not the page goal
    manager:showHome()
    emu:pump()
    local home = manager.home_dialog
    scroll_bottom(emu, home)
    emu:expectText("Goals")
    emu:expectText("Year Reading Goal")
    emu:expectText("/ 70 books")
    for _, node in ipairs(emu:screenNodes()) do
      assert(not node.text:find("/ 30 books", 1, true), "Home showed the goal that is already done")
    end
    emu:shot("goals_home")

    -- tapping the card opens that goal; closing comes back to Home
    local card = find_tap(home, "Year Reading Goal")
    assert(card, "no tappable goal card on Home")
    tap_widget(emu, card)
    local one = UIManager:getTopmostVisibleWidget()
    assert(one and one.name == "hardcover_goal" and one.goal.target == 70, "the card did not open the 70-book goal: " .. tostring(one and one.name))
    emu:expectText("To finish")
    emu:expectText("Pace for today")
    emu:shot("goals_one")
    one:onClose()
    emu:pump()
    assert(UIManager:getTopmostVisibleWidget() == home)
    scroll_bottom(emu, home)

    -- the heading opens the Goals screen: current goals, then past; archived ones absent
    tap_widget(emu, find_tap(home, "Goals"))
    local screen = UIManager:getTopmostVisibleWidget()
    assert(screen and screen.name == "hardcover_goals", "the heading did not open the goals: " .. tostring(screen and screen.name))
    emu:expectText("Current")
    emu:expectText("Pages this month")
    emu:expectText("/ 3000 pages")
    emu:expectText("Past goals")
    emu:expectText("Last Year Reading Goal")
    for _, node in ipairs(emu:screenNodes()) do
      assert(not node.text:find("archived goal", 1, true), "an archived goal was shown")
    end
    emu:shot("goals_screen")
    screen:onClose()
    emu:pump()
    home:onClose()
    emu:pump()

    -- offline, from the saved copy, with a book finished offline counted
    local NetworkManager = require("ui/network/manager")
    local was = NetworkManager.isConnected
    NetworkManager.isConnected = function() return false end
    queue_finished = 1
    local before = 0
    for _, c in ipairs(fixtures.calls) do if c.name == "getGoals" then before = before + 1 end end
    manager, _ = new_manager(emu, settings, "goals", queue)
    manager:showGoals()
    emu:pump()
    emu:expectText("Offline.")
    emu:expectText("Showing your goals as of")
    emu:expectText("+1 finished offline")
    local after = 0
    for _, c in ipairs(fixtures.calls) do if c.name == "getGoals" then after = after + 1 end end
    assert(after == before, "asked for goals while offline")
    emu:shot("goals_offline")
    manager.goals_dialog:onClose()
    emu:pump()

    -- Home offline shows the same saved card
    manager:showHome()
    emu:pump()
    scroll_bottom(emu, manager.home_dialog)
    emu:expectText("Year Reading Goal")
    emu:expectText("+1 finished offline")
    manager.home_dialog:onClose()
    emu:pump()
    NetworkManager.isConnected = was

    -- never saved and offline: say so, no crash
    os.remove(cache_path)
    NetworkManager.isConnected = function() return false end
    manager = new_manager(emu, settings, "goals_none", queue)
    manager:showGoals()
    emu:pump()
    emu:expectText("need an internet connection")
    NetworkManager.isConnected = was
    emu:closeAll()
  end,
}
