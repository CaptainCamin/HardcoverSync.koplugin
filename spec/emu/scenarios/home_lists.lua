--[[--
Preview of the home screen with the "More lists" tile: the heading "Currently
reading" is a button, every reading card is the same size, and the Library tiles
are Want to Read, Read, Did Not Finish and More lists. (The lists screen itself is
not built yet: the tile is switched on here by hand.)
]]

local fixtures = require("fixtures")

return {
  name = "home_lists",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_lists.lua"
    os.remove(path)
    for _, id in ipairs({ 101, 102 }) do
      fixtures.seed_cover("https://covers.hardcover.app/fixture/" .. id .. ".jpg")
    end
    fixtures.install({ settings = settings })
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new {
      settings = settings,
      shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end },
    }
    manager:showHome()
    emu:pump()
    local dialog = manager.home_dialog
    dialog.lists_cb = function() end
    dialog.list_count = 8
    dialog:rebuild()
    emu:pump()
    emu:expectText("More lists")
    emu:shot("home_lists")
    emu:closeAll()
  end,
}
