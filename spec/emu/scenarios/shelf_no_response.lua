--[[--
A shelf change whose answer never arrives: the change is kept like an offline one, shown at
once, and marked so a removal before the replay cannot drop a write that may have landed.

Screen: shelf_no_response_kept.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

return {
  name = "shelf_no_response",

  run = function(emu)
    local SqliteStore = require("hardcover/lib/sqlite_store")
    local BookStore = require("hardcover/lib/book_store")
    local ShelfStore = require("hardcover/lib/shelf_store")
    local SyncQueue = require("hardcover/lib/sync_queue")
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local Api = require("hardcover/lib/hardcover_api")
    local SETTING = require("hardcover/lib/constants/settings")

    local dir = emu.DataStorage:getSettingsDir()
    local path = dir .. "/hardcoversync_library_emu_shelf_no_response.sqlite3"
    for _, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do os.remove(path .. suffix) end
    local queue_path = dir .. "/hardcoversync_queue_emu_shelf_no_response.lua"
    os.remove(queue_path)
    local shelf_path = dir .. "/hardcovershelf_cache_shelf_no_response.lua"
    os.remove(shelf_path)

    local settings = fixtures.real_settings(emu)
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    fixtures.install({ settings = settings })
    Api.auth = fixtures.fake_auth(true)

    local db = SqliteStore:new { path = path }
    local books = BookStore:new { db = db }
    local sync_queue = SyncQueue:new { settings = LuaSettings:open(queue_path) }
    local manager = DialogManager:new {
      settings = settings,
      shelf_cache = ShelfCache:new { path = shelf_path, open = function(p) return LuaSettings:open(p) end },
      book_store = books,
      shelf_store = ShelfStore:new { db = db, books = books },
      sync_queue = sync_queue,
    }

    local function topmost() return UIManager:getTopmostVisibleWidget() end
    local function tapText(text)
      local node
      for _, n in ipairs(emu:screenNodes()) do
        if n.text:find(text, 1, true) then node = n end
      end
      assert(node, "no " .. text .. " on screen:\n" .. emu:screenText())
      emu:tapExpecting(node.x + 5, node.y + 5)
      emu:pump()
    end

    local book_id = 108 -- not in the library (fixtures.not_in_library)
    manager:showBookDetail(book_id)
    emu:pump()
    local dialog = topmost()
    assert(dialog and dialog.name == "hardcover_book_detail", "the details did not open")
    emu:expectText("The Obelisk Gate")

    -- the write is sent, but its answer is lost
    Api.updateUserBook = function() return nil, { completed = false } end
    UIManager:_repaint()
    local shelf = dialog.shelf_tap
    assert(shelf and shelf.dimen, "the shelf control is missing")
    local d = shelf.dimen
    emu:tapExpecting(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
    emu:pump()
    tapText("Paused")
    emu:pump()

    emu:expectText("Offline: the shelf change is kept")
    local op = sync_queue:shelfOp(book_id)
    assert(op and op.kind == "status" and op.status_id == 4, "the unanswered change was not kept")
    assert(dialog.detail.status_id == 4 and dialog.detail.user_book_id == nil, "the screen did not change")
    assert(sync_queue:get(book_id).maybe_remote == true, "the lost answer was not marked as possibly sent")
    emu:shot("shelf_no_response_kept")

    emu:closeAll()
    db:close()
  end,
}
