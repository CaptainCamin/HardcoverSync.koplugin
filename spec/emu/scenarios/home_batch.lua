--[[--
Data arriving in the background (counts, the reading list, the list count, goals)
is drawn together, not once each: opening Home asked for four things one after
another, and each redraw is a visible refresh on e-ink. Anything that waits is
drawn by the one rebuild that follows; a rebuild asked for outright draws it all
at once and leaves nothing waiting.
]]

local fixtures = require("fixtures")
local Home = require("hardcover/lib/home")

return {
  name = "home_batch",

  run = function(emu)
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local HomeDialog = require("hardcover/lib/ui/home_dialog")
    local UIManager = require("ui/uimanager")

    local dialog = HomeDialog:new { title = "Hardcover", rows = {}, entries = {} }
    UIManager:show(dialog)
    emu:pump()

    local builds = 0
    local build = HomeDialog.build
    HomeDialog.build = function(self, ...) builds = builds + 1 return build(self, ...) end

    dialog:setRows(Home.rows({ [3] = 4 }), true)
    dialog:setReading({}, true)
    dialog.list_count = 5
    dialog:rebuildSoon()
    assert(builds == 0, "a rebuild that can wait drew at once (" .. builds .. " builds)")

    emu:pump()
    assert(builds == 1, "three arrivals should be drawn by one rebuild, got " .. builds)

    -- a rebuild asked for outright draws now, and leaves nothing waiting
    dialog:setRows(Home.rows({ [3] = 9 }), true)
    dialog:rebuild()
    assert(builds == 2, "rebuild() should draw at once, got " .. builds)
    emu:pump()
    assert(builds == 2, "nothing should have been left waiting, got " .. builds)

    -- closing Home with a rebuild waiting draws nothing
    dialog:setRows(Home.rows({ [3] = 1 }), true)
    UIManager:close(dialog)
    emu:pump()
    assert(builds == 2, "a closed Home was rebuilt, got " .. builds)

    HomeDialog.build = build
    emu:closeAll()
  end,
}
