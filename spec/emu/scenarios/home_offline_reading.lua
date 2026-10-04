--[[--
Home's Currently Reading while offline: the saved cards with the reading done offline laid
over them -- a page turned past the card's shows, a book finished offline is gone, a book
started offline appears first -- and the same once back online but before it is sent.

Screens: home_offline_reading.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

return {
  name = "home_offline_reading",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    for _, id in ipairs({ 101, 102 }) do
      fixtures.seed_cover("https://covers.hardcover.app/fixture/" .. id .. ".jpg")
    end
    fixtures.install({ settings = settings })

    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local SyncQueue = require("hardcover/lib/sync_queue")
    local HARDCOVER = require("hardcover/lib/constants/hardcover")
    local User = require("hardcover/lib/user")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_home_offline.lua"
    os.remove(path)
    local cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end }
    cache:putReading(User:getId(), fixtures.currently_reading)

    -- what was read offline: 101 to page 250, 102 finished, 200 started (page 12)
    local store = {}
    local queue = SyncQueue:new { settings = {
      readSetting = function(_, k) return store[k] end,
      saveSetting = function(_, k, v) store[k] = v end,
      flush = function() end,
    } }
    queue:enqueuePage("/books/101.epub", { mapped_page = 250, book_id = 101 })
    queue:enqueueStatus("/books/102.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 102 })
    queue:enqueueStatus("/books/200.epub", { status_id = HARDCOVER.STATUS.READING, book_id = 200, title = "Started Offline" })
    queue:enqueuePage("/books/200.epub", { mapped_page = 12, book_id = 200 })

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings, shelf_cache = cache, sync_queue = queue }

    local NetworkManager = require("ui/network/manager")
    local was, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end

    manager:showHome()
    emu:pump()
    local home = manager.home_dialog
    assert(home and UIManager:isWidgetShown(home), "home did not open")
    for _, expected in ipairs({ "Started Offline", "The Dispossessed", "250 / 341", "The Hundred Thousand Kingdoms" }) do
      emu:expectText(expected)
    end
    local screen = emu:screenText()
    assert(not screen:find("A Wizard of Earthsea", 1, true), "a book finished offline is still being read")
    assert(not screen:find("120 / 341", 1, true), "the saved page is shown over the offline one")
    assert(#home.entries == 3 and home.entries[1].book_id == 200, "cards: " .. #home.entries)
    emu:shot("home_offline_reading")
    emu:closeAll()

    -- back online, the queue not yet sent: the fetched list gets the same treatment, and the
    -- saved copy keeps what Hardcover said
    NetworkManager.isConnected, NetworkManager.getConnectionState = was, was_state
    manager:showHome()
    emu:pump()
    for _, expected in ipairs({ "250 / 341", "Started Offline" }) do emu:expectText(expected) end
    assert(not emu:screenText():find("A Wizard of Earthsea", 1, true), "the finished book came back with the fetch")
    assert(cache:reading(User:getId())[1].progress_pages == 120, "the saved copy was written with the offline page")
    emu:closeAll()
  end,
}
