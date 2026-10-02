--[[--
The home screen: your shelves, with how many books are on each.

Run through the plugin's own entry point (DialogManager:showHome), the way the
Hardcover: Home action and the menu item reach it, against the real Menu widget.

Screens: home (counts known), home_no_counts (nothing saved, nothing fetched),
home_shelf (a shelf opened from it, to show it stacking on top).
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
    fixtures.install({ settings = settings })

    manager:showHome()
    emu:pump()

    local dialog = manager.home_dialog
    assert(dialog, "showHome did not produce a dialog")
    assert(UIManager:isWidgetShown(dialog), "the home screen was built but never shown")

    for _, expected in ipairs({ "Currently Reading", "Want to Read", "Read", "Did Not Finish" }) do
      emu:expectText(expected)
    end
    for _, count in ipairs({ "3", "42", "130", "2" }) do
      emu:expectText(count)
    end

    local rows = dialog.rows
    assert(#rows == 4 and rows[1].title == "Currently Reading",
      "rows are not in the expected order")
    emu:shot("home")

    --[[--
    Choosing a shelf opens it on top, so closing it comes back here.
    ]]
    dialog.select_cb(rows[2])
    emu:pump()
    assert(manager.shelf_dialog and UIManager:isWidgetShown(manager.shelf_dialog),
      "choosing a shelf did not open it")
    assert(UIManager:isWidgetShown(dialog), "opening a shelf closed the home screen")
    emu:expectText("Want to Read")
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
      },
    })

    bare:showHome()
    emu:pump()
    assert(bare.home_dialog, "the home screen did not open without counts")
    emu:expectText("Currently Reading")
    for _, row in ipairs(bare.home_dialog.rows) do
      assert(row.count == nil, "invented a count for " .. row.title)
    end
    emu:shot("home_no_counts")
    emu:closeAll()
  end,
}
