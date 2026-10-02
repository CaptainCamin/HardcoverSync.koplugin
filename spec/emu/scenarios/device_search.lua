--[[--
"On device" on a book's details: a button when KOReader's file search is there (it is in
both the file manager and the reader), none when it is not; tapping it opens that search
with the title filled in (the author and a subtitle left off).

Screens: device_search_button.
]]

local fixtures = require("fixtures")

return {
  name = "device_search",

  run = function(emu)
    local SETTING = require("hardcover/lib/constants/settings")
    local settings = fixtures.real_settings(emu)
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    fixtures.install({ settings = settings })
    local DialogManager = require("hardcover/lib/ui/dialog_manager")

    -- no file search on this UI: no button
    local bare = DialogManager:new { settings = settings }:showBookDetail(103, 10301)
    emu:pump()
    assert(bare.find_button == nil, "a button that would do nothing")
    emu:closeAll()

    -- with it: the button, and the tap passes the title on
    local asked
    local ui = { filesearcher = { onShowFileSearch = function(_, text) asked = text end } }
    local details = DialogManager:new { settings = settings, ui = ui }:showBookDetail(103, 10301)
    emu:pump()
    assert(details.find_button, "no On device button")
    emu:expectText("On device")
    emu:shot("device_search_button")
    local b = details.find_button
    emu:tapExpecting(b.dimen.x + math.floor(b.dimen.w / 2), b.dimen.y + math.floor(b.dimen.h / 2))
    assert(asked == "The Left Hand of Darkness", "the search was opened for " .. tostring(asked))
    emu:closeAll()

    -- a search that cannot open says so
    ui.filesearcher.onShowFileSearch = function() error("no") end
    details = DialogManager:new { settings = settings, ui = ui }:showBookDetail(103, 10301)
    emu:pump()
    emu:screenNodes() -- paints, so the button has a position
    b = details.find_button
    emu:tapExpecting(b.dimen.x + math.floor(b.dimen.w / 2), b.dimen.y + math.floor(b.dimen.h / 2))
    emu:expectText("Could not open the file search.")
    emu:closeAll()
  end,
}
