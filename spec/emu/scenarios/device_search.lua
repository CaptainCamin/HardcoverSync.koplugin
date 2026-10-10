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

    -- (the settings outlive a scene: forget any file left linked to the book by an earlier run)
    for file in pairs(settings:readSetting("books") or {}) do
      settings:updateBookSetting(file, { _delete = { "book_id", "title" } })
    end

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
    assert(details.find_button, "no Find on device button")
    emu:expectText("Find on device")
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

    -- a book the plugin has linked to a file that is still there: Open, and no search
    local file = os.tmpname()
    settings:updateBookSetting(file, { book_id = 103, title = "The Left Hand of Darkness" })
    local ReaderUI = require("apps/reader/readerui")
    local opened
    local show_reader = ReaderUI.showReader
    ReaderUI.showReader = function(_, f) opened = f end
    details = DialogManager:new { settings = settings, ui = ui }:showBookDetail(103, 10301)
    emu:pump()
    emu:expectText("Open")
    assert(details.open_button and details.find_button == nil, "Open does not replace Find on device")
    emu:shot("device_open_button")
    emu:screenNodes()
    local o = details.open_button.dimen
    emu:tap(o.x + math.floor(o.w / 2), o.y + math.floor(o.h / 2))
    emu:pump()
    assert(opened == file, "Open opened " .. tostring(opened))
    emu:closeAll()

    -- the file is gone: back to Find on device
    os.remove(file)
    details = DialogManager:new { settings = settings, ui = ui }:showBookDetail(103, 10301)
    emu:pump()
    assert(details.open_button == nil and details.find_button, "a deleted file is still offered")
    emu:closeAll()
    ReaderUI.showReader = show_reader
    settings:updateBookSetting(file, { _delete = { "book_id", "title" } })
  end,
}
