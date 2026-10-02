--[[--
The home screen when it is taller than the screen (many books being read, plus a
goal card): it scrolls, everything is reachable, and a tap goes to what is on
screen, not to something scrolled out of view.

Screens: home_scroll_top, home_scroll_bottom.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

return {
  name = "home_scroll",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_scroll.lua"
    os.remove(path)
    fixtures.install({ settings = settings })
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings,
      shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end } }
    manager:showHome()
    emu:pump()
    local home = manager.home_dialog
    assert(not home.scroll, "a page that fits should not scroll")

    -- six books being read, and a tappable card under the library
    local entries = {}
    for i = 1, 6 do
      local e = {}
      for k, v in pairs(fixtures.currently_reading[(i - 1) % 3 + 1]) do e[k] = v end
      e.book_id = 700 + i
      e.title = "Book number " .. i
      entries[i] = e
    end
    local opened_goal, goal_row = false, nil
    home.goal_card_fn = function(width, viewport)
      local Theme = require("hardcover/lib/ui/theme")
      local TapRow = require("hardcover/lib/ui/tap_row")
      goal_row = TapRow:new { viewport = viewport, callback = function() opened_goal = true end,
        Theme.box(width, Theme.BUTTON_H * 2, require("ui/widget/textwidget"):new { text = "Goal card", face = Theme.face("body") }, { radius = 10 }) }
      return goal_row
    end
    home:setReading(entries)
    emu:pump()
    assert(home.scroll, "six books and a card should make the page scroll")
    emu:screenNodes() -- paint: tap ranges are only real once painted

    -- at the top: the search field and the first book are reachable; the card is not on screen
    emu:expectText("Book number 1")
    emu:shot("home_scroll_top")
    local opened = nil
    manager.select_cb_probe = nil
    local first = emu:expectText("Book number 1")
    emu:tapExpecting(first.x + 5, first.y + 5)
    local top = UIManager:getTopmostVisibleWidget()
    assert(top and top.name == "hardcover_book_detail", "tapping the first card did not open it: " .. tostring(top and top.name))
    UIManager:close(top)
    emu:pump()

    -- scrolled to the bottom: the library tiles and the goal card are there and tappable
    home.scroll:scrollToRatio(0, 1)
    UIManager:setDirty(home, "ui")
    emu:screenNodes()
    emu:expectText("Want to Read")
    emu:expectText("Goal card")
    emu:shot("home_scroll_bottom")
    -- positions of scrolled content are the widget's own (its text nodes are reported
    -- relative to the scroll area)
    local d = goal_row.dimen
    assert(d and d.y >= 0 and d.y + d.h <= require("device").screen:getHeight(), "the goal card is not on screen after scrolling")
    emu:tapExpecting(d.x + 5, d.y + 5)
    assert(opened_goal, "the goal card did not take its tap when scrolled into view")

    -- a card scrolled OUT of view takes no tap: the first book is above the top edge now
    local nodes = emu:screenNodes()
    for _, node in ipairs(nodes) do
      assert(not (node.text == "Book number 1" and node.y >= 0 and node.y + node.h <= require("device").screen:getHeight()),
        "the first book should be scrolled out of view")
    end

    -- the shelf tile still opens its shelf
    -- the first tile (Want to Read): its own painted rectangle
    local tile = home.library[3][1]
    local td = tile.dimen
    assert(td and td.y >= 0 and td.y + td.h <= require("device").screen:getHeight(), "the tile is not on screen after scrolling")
    emu:tapExpecting(td.x + 5, td.y + 5)
    assert(manager.shelf_dialog and UIManager:isWidgetShown(manager.shelf_dialog), "the tile did not open its shelf")
    emu:closeAll()

    -- Scrolled down, the cards above the top edge keep tap ranges at shifted
    -- positions -- over the title bar's Close button. The Close must still work.
    manager:showHome()
    emu:pump()
    home = manager.home_dialog
    home.goal_card_fn = function(width, viewport)
      local Theme = require("hardcover/lib/ui/theme")
      return require("hardcover/lib/ui/tap_row"):new { viewport = viewport, callback = function() end,
        Theme.box(width, Theme.BUTTON_H * 2, require("ui/widget/textwidget"):new { text = "Goal card", face = Theme.face("body") }, { radius = 10 }) }
    end
    home:setReading(entries)
    emu:pump()
    emu:screenNodes() -- paint first: the scroll area knows its size once painted
    home.scroll:scrollToRatio(0, 1)
    UIManager:setDirty(home, "ui")
    emu:screenNodes()
    local close = home.title_bar.right_button
    local cd = close.dimen
    emu:tap(cd.x + math.floor(cd.w / 2), cd.y + math.floor(cd.h / 2))
    assert(not UIManager:isWidgetShown(home), "the Close button did not close the scrolled home screen")
    emu:closeAll()
  end,
}