--[[--
Stats: the dashboard of charts (all time, then a year through the period
chooser), the saved copy shown offline and kept when a refresh fails, the first-time
messages, and an empty library.

Screens: stats_all, stats_all_2, stats_all_3, stats_year, stats_offline, stats_empty.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function top() return UIManager:getTopmostVisibleWidget() end

-- the painted TapRow whose words contain `needle` (a bare text node has no position to tap)
local function find_tap(root, needle, seen)
  seen = seen or {}
  if type(root) ~= "table" or seen[root] then return end
  seen[root] = true
  if root.name == "hardcover_tap_row" and root.dimen and root.dimen.x then
    local function has(w, depth)
      if type(w) ~= "table" or depth > 12 then return false end
      if type(w.text) == "string" and w.text:find(needle, 1, true) then return true end
      for _, c in ipairs(w) do if has(c, depth + 1) then return true end end
      return false
    end
    if has(root[1], 0) then return root end
  end
  for _, c in pairs(root) do
    local r = find_tap(c, needle, seen)
    if r then return r end
  end
end

-- scroll the page of charts until the TapRow containing `needle` is wholly on screen
-- (text inside the scroll has no screen position; the row's dimen does)
local function scroll_to_row(emu, dialog, needle)
  for step = 0, 40 do
    dialog.scroll:scrollToRatio(0, step / 40)
    emu:pump()
    emu:screenNodes()
    local row = find_tap(dialog, needle)
    if row then
      local d, v = row.dimen, dialog.scroll.dimen
      if d.y >= v.y and d.y + d.h <= v.y + v.h then return row end
    end
  end
  error("never brought the row on screen: " .. needle)
end

-- the first chart canvas drawn after the section heading `heading`, in paint order
local function canvas_after(root, heading)
  local seen_heading, result
  local function walk(w, seen)
    if result or type(w) ~= "table" or seen[w] then return end
    seen[w] = true
    if w.text == heading then seen_heading = true end
    if seen_heading and type(w.draw) == "function" and w.dimen and w.dimen.x then
      result = w
      return
    end
    for _, c in ipairs(w) do walk(c, seen) end
  end
  walk(root, {})
  return result
end

-- scroll until the widget is wholly inside the scroll area
local function scroll_to_widget(emu, dialog, w)
  for step = 0, 80 do
    dialog.scroll:scrollToRatio(0, step / 80)
    emu:pump()
    emu:screenNodes()
    local d, v = w.dimen, dialog.scroll.dimen
    if d.y >= v.y and d.y + d.h <= v.y + v.h then return true end
  end
  return false
end

return {
  name = "stats",

  run = function(emu)
    local SETTING = require("hardcover/lib/constants/settings")
    local settings = fixtures.real_settings(emu)
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    -- the shortest book gets a long title, so the Shortest line is one that truncates
    local raw = fixtures.default_stats_raw()
    local shortest
    for _, row in ipairs(raw) do
      local pages = row.book and row.book.pages
      if pages and (not shortest or pages < shortest.book.pages) then shortest = row end
    end
    shortest.book.title = "The Time Machine / The Invisible Man and Other Stories: A Very Long Title Indeed, With Even More Words To Overflow The Line, And Yet More Words After That"
    fixtures.stats_raw = raw
    fixtures.install({ settings = settings })

    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_stats.lua"
    os.remove(path)
    os.remove((path:gsub("%.lua$", "")) .. "_home.lua")
    local cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end }
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings, shelf_cache = cache }

    -- all time
    manager:showStats()
    for _ = 1, 6 do emu:pump() end
    local dialog = manager.stats_dialog
    assert(dialog and dialog.rows and #dialog.rows == 105, "the stats did not load")
    for _, expected in ipairs({ "Stats", "Books per year", "Your ratings", "Genres", "Most read authors", "Book length" }) do
      emu:expectText(expected)
    end
    emu:shot("stats_all")
    assert(dialog.scroll, "a page of charts should scroll")
    dialog.scroll:scrollToRatio(0, 0.5)
    emu:pump()
    emu:shot("stats_all_2")
    dialog.scroll:scrollToRatio(0, 1)
    emu:pump()
    emu:shot("stats_all_3")
    emu:expectText("Rating and length")

    -- The Shortest line cuts a long title; holding it shows the whole title and its length.
    local row = scroll_to_row(emu, dialog, "Shortest:")
    local line_node
    for _, node in ipairs(emu:screenNodes()) do
      if node.text:find("Shortest:", 1, true) then line_node = node end
    end
    assert(line_node, "no Shortest line node")
    -- the node keeps the full string; truncation shows in its painted width
    local probe = require("hardcover/lib/ui/theme").text("Shortest: " .. shortest.book.title, "small")
    assert(probe:getSize().w > line_node.w, "the long shortest title was not cut")
    probe:free()
    emu:tapExpecting(row.dimen.x + 5, row.dimen.y + 5, { ges = emu.GESTURES.Hold })
    emu:pump()
    emu:expectText("And Yet More Words After That")
    emu:shot("stats_shortest_hold")
    local close = emu:expectText("Close")
    emu:tapExpecting(close.x + math.floor(close.w / 2), close.y + math.floor(close.h / 2))
    emu:pump()

    -- Average rating by year: a five-star metric on a 0..5 axis, not 0..6 (the scale itself is
    -- pinned in charts_harness; a canvas's drawn words are not in the widget tree, so the shot
    -- is the evidence here)
    local chart = canvas_after(dialog, "Average rating by year")
    assert(chart, "no rating-by-year chart")
    assert(scroll_to_widget(emu, dialog, chart), "the rating chart never came on screen")
    emu:shot("stats_rating_axis")

    -- one year, from its tab: All time, the two latest years, Earlier
    assert(dialog.chips and #dialog.chips == 4, "expected four period chips, got " .. tostring(dialog.chips and #dialog.chips))
    emu:screenNodes() -- paint: tap ranges are only real once painted
    local tab = dialog.chips[3].dimen
    emu:tapExpecting(tab.x + math.floor(tab.w / 2), tab.y + math.floor(tab.h / 2))
    emu:pump()
    assert(dialog.year == 2024, "the 2024 tab did not choose 2024: " .. tostring(dialog.year))
    emu:expectText("Books per month")
    emu:expectText("Pages per month")
    emu:expectText("Pace")
    emu:shot("stats_year")

    -- one month of that year, from the Month chip: the picker lists the months with a finish
    emu:screenNodes()
    tab = dialog.chips[5].dimen
    emu:tapExpecting(tab.x + math.floor(tab.w / 2), tab.y + math.floor(tab.h / 2))
    emu:pump()
    emu:expectText("All of 2024")
    local month_row
    for _, node in ipairs(emu:screenNodes()) do
      if not month_row and node.text:find(" · ", 1, true) then month_row = node end
    end
    assert(month_row, "no month with a finish in 2024")
    emu:tapExpecting(month_row.x + math.floor(month_row.w / 2), month_row.y + math.floor(month_row.h / 2))
    emu:pump()
    assert(dialog.month, "the month row did not choose a month")
    for _, node in ipairs(emu:screenNodes()) do
      assert(node.text ~= "Books per month", "a single month should not show the books-per-month chart")
    end
    emu:shot("stats_month")
    -- Earlier opens the picker with every year
    tab = dialog.chips[4].dimen
    emu:tapExpecting(tab.x + math.floor(tab.w / 2), tab.y + math.floor(tab.h / 2))
    emu:pump()
    emu:expectText("Period")
    emu:expectText("2023")
    emu:closeAll()

    -- offline: the saved copy, with its note
    local Network = require("ui/network/manager")
    local was, was_state = Network.isConnected, Network.getConnectionState
    Network.isConnected = function() return false end
    Network.getConnectionState = function() return false end
    manager:showStats()
    for _ = 1, 4 do emu:pump() end
    assert(manager.stats_dialog.rows and #manager.stats_dialog.rows == 105, "saved copy not shown")
    assert(manager.stats_dialog.note and manager.stats_dialog.note:find("Offline"), "no offline note: " .. tostring(manager.stats_dialog.note))
    emu:shot("stats_offline")
    emu:closeAll()

    -- first time offline: no saved copy, so say so instead of loading forever
    manager.shelf_cache:clear()
    manager:showStats()
    for _ = 1, 4 do emu:pump() end
    emu:expectText("Stats need an internet connection the first time.")
    assert(not (manager.stats_dialog and manager.stats_dialog.rows), "an empty save was shown as data")
    emu:shot("stats_first_offline")
    emu:closeAll()
    Network.isConnected, Network.getConnectionState = was, was_state

    -- nothing finished yet
    fixtures.stats_raw = {}
    manager.shelf_cache:clear()
    manager:showStats()
    for _ = 1, 4 do emu:pump() end
    emu:expectText("No finished books yet")
    emu:shot("stats_empty")
    emu:closeAll()
    fixtures.stats_raw = nil
  end,
}
