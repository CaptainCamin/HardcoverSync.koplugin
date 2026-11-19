--[[--
Reader panel > Status > Remove with no route: the removal stays in the real queue,
Pending changes names it, the local shelf and panel lose the book, and reconnecting sends
exactly one delete after the queue rechecks the record.

Screens: offline_removal_confirm, offline_removal_queued, offline_removal_pending.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local FILE = "/books/offline-removal.epub"
local BOOK_ID = 424242
local USER_BOOK_ID = 500
local TO_READ = 1

return {
  name = "offline_removal",

  run = function(emu)
    local SqliteStore = require("hardcover/lib/sqlite_store")
    local BookStore = require("hardcover/lib/book_store")
    local ShelfStore = require("hardcover/lib/shelf_store")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local SyncQueue = require("hardcover/lib/sync_queue")
    local PendingChanges = require("hardcover/lib/pending_changes")
    local LuaSettings = require("luasettings")
    local NetworkManager = require("ui/network/manager")
    local Api = require("hardcover/lib/hardcover_api")
    local User = require("hardcover/lib/user")
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
    local SETTING = require("hardcover/lib/constants/settings")

    local dir = emu.DataStorage:getSettingsDir()
    local db_path = dir .. "/hardcoversync_library_emu_offline_removal.sqlite3"
    for _, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do os.remove(db_path .. suffix) end
    local queue_path = dir .. "/hardcoversync_queue_emu_offline_removal.lua"
    os.remove(queue_path)
    local shelf_path = dir .. "/hardcovershelf_cache_offline_removal.lua"
    os.remove(shelf_path)

    local ui = emu:stub_ui { file = FILE, pages = 320 }
    local settings = fixtures.real_settings(emu, ui)
    settings:updateSetting(SETTING.USER_ID, fixtures.USER_ID)
    settings:updateBookSetting(FILE, {
      book_id = BOOK_ID, title = "The Dispossessed", edition_id = 3, pages = 320, sync = true,
    })
    fixtures.install({ settings = settings })
    Api.auth = fixtures.fake_auth(true)

    local db = SqliteStore:new { path = db_path }
    local books = BookStore:new { db = db }
    local shelves = ShelfStore:new { db = db, books = books }
    local shelf_cache = ShelfCache:new {
      path = shelf_path, open = function(p) return LuaSettings:open(p) end,
    }
    local sync_queue = SyncQueue:new { settings = LuaSettings:open(queue_path) }
    local user_id = User:getId()
    books:saveRows({ { book_id = BOOK_ID, title = "The Dispossessed" } })
    shelves:putMembers(user_id, TO_READ,
      { { user_book_id = USER_BOOK_ID, book_id = BOOK_ID, rating = 4 } }, true, "fp")
    shelf_cache:putCounts(user_id, { [TO_READ] = 1 })

    local state = { book_status = { id = USER_BOOK_ID, book_id = BOOK_ID,
      status_id = TO_READ, rating = 4, user_book_reads = {} } }
    local manager = DialogManager:new {
      settings = settings, ui = ui, state = state,
      book_store = books, shelf_store = shelves, shelf_cache = shelf_cache,
      sync_queue = sync_queue,
    }
    local menu = HardcoverMenu:new {
      enabled = true, settings = settings, ui = ui, state = state,
      dialog_manager = manager, sync_queue = sync_queue,
      cache = { updateBookStatus = function() end, cacheUserBook = function() end },
      auth = Api.auth, hardcover = {},
    }

    local function tapText(text)
      local node
      for _, n in ipairs(emu:screenNodes()) do
        if n.text == text or n.text:find(text, 1, true) then node = n end
      end
      if not node then emu:expectText(text) end
      emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
      emu:pump()
    end
    local function count(name)
      local n = 0
      for _, c in ipairs(fixtures.calls or {}) do if c.name == name then n = n + 1 end end
      return n
    end

    -- Equivalent to the round-two test's no route plus fake Wi-Fi off: both the
    -- live check and KOReader's remembered connection state say "offline".
    local was_connected, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end

    menu:showReaderPanel()
    emu:pump()
    tapText("Status")
    tapText("Remove")
    emu:expectText("Remove \"The Dispossessed\" from your library?")
    emu:shot("offline_removal_confirm")
    assert(count("removeUserBook") == 0, "the confirmation sent a delete")
    tapText("Remove")

    emu:expectText("Offline: the removal is kept")
    emu:shot("offline_removal_queued")
    assert(count("removeUserBook") == 0, "the offline removal tried to send a delete")
    local op = sync_queue:shelfOp(BOOK_ID)
    assert(op and op.kind == "remove" and op.user_book_id == USER_BOOK_ID,
      "the reader's removal was not kept in the real queue")
    assert(state.book_status.id == nil, "the reader panel still holds the library record")
    assert(shelves:member(user_id, BOOK_ID) == nil, "the saved shelf still holds the book")

    local rows = PendingChanges.list({ sync_queue = sync_queue })
    assert(#rows == 1 and rows[1].text:find("remove from your library", 1, true),
      "Pending changes does not name the removal")
    menu:showPendingChanges()
    emu:pump()
    emu:expectText("remove from your library")
    emu:shot("offline_removal_pending")
    emu:closeAll()

    NetworkManager.isConnected, NetworkManager.getConnectionState = was_connected, was_state
    Api.findUserBookForRemoval = function()
      return { id = USER_BOOK_ID, book_id = BOOK_ID, status_id = TO_READ,
        rating = 4, has_review = false, user_book_reads = {} }
    end
    assert(sync_queue:flush(Api, { user_id = user_id }), "the queued removal was not sent")
    assert(count("removeUserBook") == 1, "the removal was not sent exactly once")
    assert(sync_queue:count() == 0, "the sent removal is still queued")

    emu:closeAll()
    db:close()
  end,
}
