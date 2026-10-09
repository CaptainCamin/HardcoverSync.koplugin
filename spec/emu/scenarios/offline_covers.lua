--[[--
Settings > Download covers for offline, in the real KOReader: the item in the settings
screen with how many covers are missing, the question with how many and about how much,
and a run that keeps them (here the covers were already on the device from being seen, so
they are copied and nothing is downloaded). The real SQLite store and the real menu.

Screens: offline_covers_settings, offline_covers_question.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

return {
  name = "offline_covers",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })
    local User = require("hardcover/lib/user")
    local user_id = User:getId()

    local SqliteStore = require("hardcover/lib/sqlite_store")
    local BookStore = require("hardcover/lib/book_store")
    local ShelfStore = require("hardcover/lib/shelf_store")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcoversync_library_offline_covers.sqlite3"
    for _, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do os.remove(path .. suffix) end
    local db = SqliteStore:new { path = path }
    local books = BookStore:new { db = db }
    local shelves = ShelfStore:new { db = db, books = books }

    -- three books on Read whose covers were seen (in the cover space), none kept yet
    local loader = require("hardcover/lib/ui/image_loader")
    os.execute("rm -rf '" .. emu.DataStorage:getDataDir() .. "/cache/hardcover_covers_offline'")
    loader.pinned = nil
    local entries = {}
    for i = 1, 3 do
      local b = fixtures.shelf_books[i]
      fixtures.seed_cover(b.cached_image.url, i)
      entries[i] = { user_book_id = 900 + i, book_id = b.book_id, title = b.title, cached_image = b.cached_image }
    end
    shelves:putEntries(user_id, 3, entries, true, "3|T|")

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings, book_store = books, shelf_store = shelves }
    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
    local menu = HardcoverMenu:new({
      settings = settings,
      enabled = true,
      dialog_manager = manager,
      sync_queue = { pendingCount = function() return 0 end, hasPending = function() return false end },
      auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
               statusText = function() return "Signed in" end },
    })
    manager.settings_items = function() return menu:getHomeSettingsItems() end

    manager:showSettings()
    emu:pump()
    emu:expectText("Download covers for offline (3 missing)")
    emu:shot("offline_covers_settings")

    local item
    for _, it in ipairs(menu:getHomeSettingsItems()) do
      if it.text_func and it.text_func():find("Download covers") then item = it end
    end
    assert(item, "no Download covers item")
    item.callback()
    emu:pump()
    emu:expectText("Keep 3 covers for offline")
    emu:shot("offline_covers_question")

    local box = UIManager:getTopmostVisibleWidget()
    box.ok_callback()
    for _ = 1, 20 do emu:pump() end
    for i = 1, 3 do
      local key = loader:fetchUrl(fixtures.shelf_books[i].cached_image.url, "small")
      assert(loader:getPinned():has(key), "cover " .. i .. " was not kept for offline")
    end
    emu:expectText("Every cover is kept for offline (3).")
    assert(manager:coversMenuText() == "Download covers for offline", manager:coversMenuText())
    emu:closeAll()
    db:close()
  end,
}
