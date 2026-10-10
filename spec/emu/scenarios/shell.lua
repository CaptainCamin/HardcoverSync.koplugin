--[[--
The shell: Home, Library, Goals and Stats as tabs of one screen with a navigation bar. Home (fixed, never
scrolls) and Goals are hosted bodies ; Library (Shelves | Lists | Vibes) and Stats are hosted too. Checked for real:
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
    emu:expectText("CURRENTLY READING")
    emu:expectText("All synced")
    emu:expectText("Sync now")
    local home = shell.bodies.home
    assert(home and home.shell == shell and not home.scroll, "Home must be a body that never scrolls")
    pending = 2
    home:rebuild()
    emu:pump()
    emu:expectText("2 changes waiting")
    emu:expectText("Sync now")
    pending = 0
    home:rebuild()

    -- the book being read: one bordered card with a filled Open book; the page never scrolls, and
    -- the shelves give way before the card does
    home:setReading(fixtures.currently_reading)
    home:setRows(require("hardcover/lib/home").rows(fixtures.shelf_counts))
    home:rebuild()
    emu:pump()
    emu:expectText("The Dispossessed")
    emu:expectText("Open book")
    emu:expectText("35% · page 120 of 341")
    emu:shot("shell_home_cards")
    local L = home.layout
    if L.shelves > 0 then emu:expectText("Want to Read") end
    assert(not home.scroll, "Home scrolled with a card")
    assert(L.card, "Home dropped the card")
    if H > W or L.shelves > 0 then emu:expectText("books") end -- a shelf row shows its count
    print(string.format("        home at %dx%d: note=%s, shelf rows=%d", W, H, tostring(L.note), L.shelves))
    local bottom = home.dimen.y + home.dimen.h
    assert(bottom <= H - require("hardcover/lib/ui/components/nav_bar").HEIGHT, "Home reaches into the nav bar")
    -- Open book opens the book's details
    emu:tapExpecting(home.open_button.dimen.x + 10, home.open_button.dimen.y + 10)
    emu:pump()
    local details = UIManager:getTopmostVisibleWidget()
    assert(details and details.name == "hardcover_book_detail", "Open book did not open the details: " .. tostring(details and details.name))
    UIManager:close(details)
    emu:pump()
    assert(UIManager:getTopmostVisibleWidget() == shell, "closing the details did not reveal the shell")

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

    -- Library: Shelves | Lists | Vibes under a tab row, each built when first opened
    nav(2)
    assert(shell.active == "library", "the Library tab did not open")
    local library = shell.bodies.library
    emu:pump()
    emu:expectText("Want to Read")
    emu:shot("shell_library_shelves")
    assert(library.bodies.shelves and library.bodies.shelves.parent == library, "Shelves is not an inner body")
    local function sub(i)
      emu:screenNodes()
      emu:tapExpecting(math.floor((i - 0.5) * W / 3), Device.screen:scaleBySize(67 + 25))
      emu:pump()
    end
    sub(2)
    assert(library.sub == "lists" and library.bodies.lists and library.bodies.lists.shell == shell, "Lists did not open inside the Library")
    emu:shot("shell_library_lists")
    sub(3)
    assert(library.sub == "vibes" and library.bodies.vibes, "Vibes did not open inside the Library")
    -- the icon rows of mock 2v: For you first with no heading, then the two groups
    local Vibes = require("hardcover/lib/vibes")
    local sys, mine = Vibes.rows({
      { id = 1, title = "Top Picks", count = 6, ids = {}, system = true },
      { id = 2, title = "Recommendations", count = 3, ids = {}, system = true },
      { id = 3, title = "For Red Rising Withdrawl", count = 2, ids = {}, kind = "mine", private = true },
    }, {})
    table.insert(sys, 1, { name = "For you", for_you = true, covers = {} })
    library.bodies.vibes:setLists(sys, mine)
    emu:pump()
    emu:expectText("For you")
    emu:expectText("Based on what you read")
    emu:expectText("Top Picks")
    emu:shot("shell_library_vibes")
    sub(1)
    assert(library.sub == "shelves")
    assert(shell.bodies.library == library, "the Library body was rebuilt")

    -- Stats
    nav(4)
    assert(shell.active == "stats" and shell.bodies.stats and shell.bodies.stats.shell == shell, "Stats is not hosted")
    emu:pump()
    emu:shot("shell_stats")

    -- Back: a tab goes to the first tab, the first tab leaves
    shell:onBack()
    assert(shell.active == "home", "Back from a tab did not go to the first tab")
    emu:pump()
    shell:onBack()
    emu:pump()
    assert(UIManager:getTopmostVisibleWidget() ~= shell, "Back on the first tab did not leave")
    assert(not require("hardcover/lib/ui/live").shown(body), "the body is still live after its shell left")
    -- the emulator keeps its settings between scenes: leave the beta off for the ones that follow
    settings:updateSetting(SETTING.NEW_NAVIGATION, false)
  end,
}
