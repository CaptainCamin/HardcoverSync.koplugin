--[[--
The home screen: what you are reading now (cards), then your shelves with how
many books are on each.

Run through the plugin's own entry point (DialogManager:showHome), the way the
Hardcover: Home action and the menu item reach it, against the real Menu widget.

Screens: home (counts and cards known), home_no_counts (nothing saved, nothing
fetched), home_shelf (a shelf opened from it), home_book (a card tapped).
Taps go through the gesture path, at the coordinates the screen was drawn at.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function new_manager(emu, name)
  local settings = fixtures.real_settings(emu)
  local LuaSettings = require("luasettings")
  local ShelfCache = require("hardcover/lib/shelf_cache")
  -- a cache file of its own per run, so one screen's saved counts never leak
  -- into the next one
  local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_" .. name .. ".lua"
  os.remove(path)

  local DialogManager = require("hardcover/lib/ui/dialog_manager")
  return DialogManager:new {
    settings = settings,
    shelf_cache = ShelfCache:new {
      path = path,
      open = function(p) return LuaSettings:open(p) end,
    },
  }, settings
end

return {
  name = "home",

  run = function(emu)
    --[[--
    Counts known: the screen opens, then the count query lands and the numbers
    appear. Rows are in a fixed order, reading first.
    ]]
    local manager, settings = new_manager(emu, "counts")
    for _, id in ipairs({ 101, 102 }) do
      fixtures.seed_cover("https://covers.hardcover.app/fixture/" .. id .. ".jpg")
    end
    fixtures.install({ settings = settings })

    manager:showHome()
    emu:pump()

    local dialog = manager.home_dialog
    assert(dialog, "showHome did not produce a dialog")
    assert(UIManager:isWidgetShown(dialog), "the home screen was built but never shown")

    for _, expected in ipairs({
      "Currently Reading  \194\183  3", "Want to Read  \194\183  42",
      "Read  \194\183  130", "Did Not Finish  \194\183  2",
    }) do
      emu:expectText(expected)
    end
    for _, expected in ipairs({
      "The Dispossessed", "A Wizard of Earthsea", "The Hundred Thousand Kingdoms",
      "120 / 341", "20 / 183", "300 / 418", "Ursula K. Le Guin",
    }) do
      emu:expectText(expected)
    end

    local rows = dialog.rows
    assert(#rows == 4 and rows[1].title == "Currently Reading",
      "rows are not in the expected order")
    emu:shot("home")

    -- every cover the fixture has was drawn: two pictures, one placeholder
    assert(#dialog.cover_bbs == 2, "expected 2 covers drawn, got " .. #(dialog.cover_bbs or {}))

    --[[--
    A tap on empty space below the shelves opens nothing: the cards answer only
    inside what they draw.
    ]]
    local bottom = emu:expectText("Did Not Finish  \194\183  2")
    emu:tap(bottom.x + 5, bottom.y + 400)
    assert(UIManager:getTopmostVisibleWidget() == dialog, "a tap on empty space opened something")

    --[[--
    Tapping a card opens that book's details.
    ]]
    local title = emu:expectText("A Wizard of Earthsea")
    emu:tapExpecting(title.x + 5, title.y + 5)
    local top = UIManager:getTopmostVisibleWidget()
    assert(top and top.name == "hardcover_book_detail",
      "tapping a card did not open the book, top is " .. tostring(top and top.name))
    emu:shot("home_book")
    UIManager:close(top)
    emu:pump()

    --[[--
    Choosing a shelf opens it on top, so closing it comes back here. A real tap
    on its button, not a call to the callback.
    ]]
    local row = emu:expectText("Want to Read  \194\183  42")
    emu:tapExpecting(row.x + 5, row.y + 5)
    assert(manager.shelf_dialog and UIManager:isWidgetShown(manager.shelf_dialog),
      "tapping a shelf did not open it")
    assert(UIManager:isWidgetShown(dialog), "opening a shelf closed the home screen")
    emu:shot("home_shelf")
    emu:closeAll()

    --[[--
    Nothing saved and the count query failing (as when offline): the screen still
    opens, and shows no number rather than a made-up zero.
    ]]
    local bare, bare_settings = new_manager(emu, "bare")
    fixtures.install({
      settings = bare_settings,
      overrides = {
        getShelfCounts = function() return nil, { completed = false } end,
        getCurrentlyReading = function() return nil, { completed = false } end,
      },
    })

    bare:showHome()
    emu:pump()
    assert(bare.home_dialog, "the home screen did not open without counts")
    emu:expectText("Currently Reading")
    assert(not emu:screenText():find("The Dispossessed", 1, true), "showed cards that were never loaded")
    for _, row in ipairs(bare.home_dialog.rows) do
      assert(row.count == nil, "invented a count for " .. row.title)
    end
    emu:shot("home_no_counts")
    emu:closeAll()
  end,
}
