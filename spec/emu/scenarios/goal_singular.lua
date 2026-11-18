--[[--
A one-book goal: the card and the detail say "1 book", not "1 books" (issue #317).

Screens: goal_singular_card, goal_singular_detail.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

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
  name = "goal_singular",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    local SETTING = require("hardcover/lib/constants/settings")
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    local function iso(d)
      local t = os.date("*t", os.time() + d * 86400)
      return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
    end
    local rows = {
      { id = 9, goal = 1, metric = "book", description = "One book this month",
        start_date = iso(-10), end_date = iso(20), progress = 0.0, archived = false },
    }
    fixtures.install({ settings = settings, goals_rows = rows })

    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_goal_singular.lua"
    os.remove(path)
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new {
      settings = settings,
      shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end },
      sync_queue = { finishedCount = function() return 0 end },
    }

    manager:showGoals()
    emu:pump()
    emu:pump()
    local screen = UIManager:getTopmostVisibleWidget()
    assert(screen and screen.name == "hardcover_goals", "the goals did not open")
    emu:expectText("of 1 book")
    assert(not emu:screenText():find("of 1 books", 1, true), "the card says 1 books")
    emu:expectNoButtonOverlap()
    emu:shot("goal_singular_card")

    local card = find_tap(screen, "One book this month")
    assert(card, "no tappable goal card")
    emu:screenNodes()
    local d = card.dimen
    emu:tapExpecting(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
    emu:pump()
    local one = UIManager:getTopmostVisibleWidget()
    assert(one and one.name == "hardcover_goal" and one.goal.target == 1, "the card did not open the goal")
    emu:expectText("of 1 book")
    emu:expectText("1 book left in")
    assert(not emu:screenText():find("1 books", 1, true), "the detail says 1 books")
    emu:expectNoButtonOverlap()
    emu:shot("goal_singular_detail")
    emu:closeAll()
  end,
}
