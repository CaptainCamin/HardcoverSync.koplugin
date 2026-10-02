--[[--
"Search in Z-library" on the book details screen.

The Z-library plugin is separate, so a stand-in with the two methods the button
relies on is placed where KOReader keeps plugin instances (the UI's array part).
Without it there is no button at all; with it, a real tap runs its search with
the book's title and first author.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

return {
  name = "zlibrary",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })
    for _, id in ipairs({ 103 }) do fixtures.seed_cover(fixtures.cover_url(id)) end

    local DialogManager = require("hardcover/lib/ui/dialog_manager")

    -- no Z-library plugin: no button
    local bare = DialogManager:new { settings = settings, ui = {} }
    bare:showBookDetail(103, 10301)
    emu:pump()
    local dialog = UIManager:getTopmostVisibleWidget()
    assert(dialog and dialog.zlibrary_button == nil, "a Z-library button without the plugin")
    emu:shot("zlibrary_absent")
    emu:closeAll()

    -- with it
    local plugin = { searched = {} }
    function plugin:performSearch(q) self.searched[#self.searched + 1] = q end
    function plugin:showMultiSearchDialog() end
    local manager = DialogManager:new { settings = settings, ui = { {}, plugin } }
    manager:showBookDetail(103, 10301)
    emu:pump()
    dialog = UIManager:getTopmostVisibleWidget()
    assert(dialog and dialog.zlibrary_button, "no Z-library button although the plugin is there")
    emu:expectText("Search in Z-library")
    emu:expectText("Reviews")
    emu:shot("zlibrary_button")

    local b = dialog.zlibrary_button.dimen
    emu:tapExpecting(b.x + math.floor(b.w / 2), b.y + math.floor(b.h / 2))
    assert(#plugin.searched == 1, "tapping the button did not search")
    assert(plugin.searched[1] == "The Left Hand of Darkness Ursula K. Le Guin",
      "searched for " .. tostring(plugin.searched[1]))
    emu:closeAll()
  end,
}
