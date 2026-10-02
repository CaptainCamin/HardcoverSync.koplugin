--[[--
The home screen scrolls, and a reader can tell and can do it: a real swipe moves the
page, so do the page buttons ("Page 1 of 2", previous and next), the label follows
either, and a page that is scrolled down stays where it is when the data arrives and
the screen is rebuilt (it used to jump back to the top, which looks like a page that
does not scroll).

Screens: home_page1, home_page2.
]]

local fixtures = require("fixtures")
local Goals = require("hardcover/lib/goals")
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
local Time = require("ui/time")

local PREV, NEXT = "\226\128\185", "\226\128\186"

local function find_button(root, label, seen)
  seen = seen or {}
  if type(root) ~= "table" or seen[root] then return end
  seen[root] = true
  if root.text == label and root.callback and root.dimen and root.dimen.w and root.dimen.w > 0 then return root end
  for _, child in pairs(root) do
    local found = find_button(child, label, seen)
    if found then return found end
  end
end

return {
  name = "home_swipe",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    local today = Goals.today()
    local rows = { { id = 3, goal = 70, metric = "book", description = "Year Reading Goal",
      start_date = Goals.dateString(today - 200), end_date = Goals.dateString(today + 165), progress = 46.0, archived = false } }
    fixtures.install({ settings = settings, goals_rows = rows })
    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_swipe.lua"
    os.remove(path)
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings, sync_queue = { finishedCount = function() return 0 end },
      shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end } }

    manager:showHome()
    emu:pump()
    emu:screenNodes() -- paint
    local home = manager.home_dialog
    local scroll = home.scroll
    assert(scroll, "Home with three books and a goal card should scroll at this size")
    assert(home.pager, "a scrolling Home has page buttons")
    local max = scroll._max_scroll_offset_y
    assert(max and max > 0, "nothing to scroll")
    assert(scroll._is_scrollable and scroll.ges_events and scroll.ges_events.ScrollableSwipe,
      "the scroll container registered no swipe handler (a touch device must)")

    local function offset() return scroll:getScrolledOffset().y end
    local function swipe(direction)
      local g = { ges = "swipe", pos = Geom:new { x = 600, y = 900, w = 0, h = 0 }, direction = direction, distance = 500, time = Time.now() }
      local consumed = UIManager:getTopmostVisibleWidget():handleEvent(emu.Event:new("Gesture", g))
      emu:pump()
      emu:screenNodes()
      return consumed
    end
    local function tap_button(label)
      emu:screenNodes()
      local b = find_button(UIManager:getTopmostVisibleWidget(), label)
      assert(b, "no button " .. label .. ":\n" .. emu:screenText())
      emu:tapExpecting(b.dimen.x + math.floor(b.dimen.w / 2), b.dimen.y + math.floor(b.dimen.h / 2))
      emu:pump()
      emu:screenNodes()
    end

    -- at the top: page 1 of 2, and "previous" does nothing
    assert(offset() == 0)
    emu:expectText("Page 1 of 2")
    emu:shot("home_page1")

    -- a real swipe moves the page, by a whole view (here: to the end)
    assert(swipe("north"), "the swipe was not taken by anything")
    assert(offset() == max, "a swipe up did not scroll to the end: " .. offset() .. " of " .. max)
    emu:expectText("Page 2 of 2")
    emu:shot("home_page2")
    assert(swipe("south"), "the swipe back was not taken")
    assert(offset() == 0, "a swipe down did not scroll back: " .. offset())
    emu:expectText("Page 1 of 2")

    -- the page buttons do the same
    tap_button(NEXT)
    assert(offset() == max, "the next button did not scroll: " .. offset())
    emu:expectText("Page 2 of 2")
    tap_button(PREV)
    assert(offset() == 0, "the previous button did not scroll back: " .. offset())
    emu:expectText("Page 1 of 2")

    -- a page scrolled down stays put when the screen is built again (data arrived)
    tap_button(NEXT)
    assert(offset() == max)
    home:setRows(home.rows) -- what the count request does when it lands
    emu:pump()
    emu:screenNodes()
    local again = home.scroll
    assert(again and again:getScrolledOffset().y == again._max_scroll_offset_y and again._max_scroll_offset_y > 0,
      "the page jumped back to the top when Home was rebuilt: " .. tostring(again and again:getScrolledOffset().y))
    emu:expectText("Page 2 of 2")

    -- what is on screen still takes taps
    local tile = home.library[3][1]
    emu:screenNodes()
    local d = tile.dimen
    assert(d and d.y >= 0 and d.y + d.h <= require("device").screen:getHeight(), "the tile is off screen after scrolling")
    emu:tapExpecting(d.x + 5, d.y + 5)
    assert(manager.shelf_dialog and UIManager:isWidgetShown(manager.shelf_dialog), "a tile did not open its shelf")
    emu:closeAll()
  end,
}
