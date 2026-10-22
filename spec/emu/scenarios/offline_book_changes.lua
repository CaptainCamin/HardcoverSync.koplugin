--[[--
A book put on a shelf, and on and off lists, from its details screen with no connection,
against the real SQLite file: the picker opens from what is saved, each tap is kept and
shown at once (the button, the tick, the list's size) with a message saying so, nothing is
requested, and when the connection is back each change is sent exactly once.

Screens: offline_book_changes_lists, offline_book_changes_detail.
]]

local fixtures = require("fixtures")
local perf = require("perf")
local UIManager = require("ui/uimanager")

local T1 = "2026-10-08T15:22:25.183388+00:00"

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

-- every list gets a time Hardcover last changed it and a counted size, as the real API gives them
local function stamp(me)
  local function one(list)
    list.updated_at = T1
    list.list_books_aggregate = { aggregate = { count = fixtures.list_sizes[list.id] or 0 } }
  end
  for _, list in ipairs(me[1].lists) do one(list) end
  for _, f in ipairs(me[1].followed_lists) do one(f.list) end
  return me
end

return {
  name = "offline_book_changes",

  run = function(emu)
    local SqliteStore = require("hardcover/lib/sqlite_store")
    local BookStore = require("hardcover/lib/book_store")
    local ListStore = require("hardcover/lib/list_store")
    local ShelfStore = require("hardcover/lib/shelf_store")
    local ShelfQueue = require("hardcover/lib/shelf_queue")
    local ListQueue = require("hardcover/lib/list_queue")
    local PendingChanges = require("hardcover/lib/pending_changes")
    local NetworkManager = require("ui/network/manager")
    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local User = require("hardcover/lib/user")
    local Api = require("hardcover/lib/hardcover_api")
    local SETTING = require("hardcover/lib/constants/settings")

    local dir = emu.DataStorage:getSettingsDir()
    local path = dir .. "/hardcoversync_library_emu_book_changes.sqlite3"
    for _, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do os.remove(path .. suffix) end
    local queue_path = dir .. "/hardcoversync_queue_emu_book_changes.lua"
    os.remove(queue_path)
    local shelf_path = dir .. "/hardcovershelf_cache_offline_book_changes.lua"
    os.remove(shelf_path)

    local settings = fixtures.real_settings(emu)
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    fixtures.install({ settings = settings, lists_me = stamp(copy(fixtures.lists_me)) })
    Api.auth = fixtures.fake_auth(true)
    -- Home loads in the background from inside the shell's own build, before the shell is on
    -- screen, and stops when it is not shown. A device's first request yields to the event loop
    -- (so the shell is up when it answers) and the fixtures do not: make it yield.
    perf.slow_network({ "getShelfCounts" })

    local db = SqliteStore:new { path = path }
    local books = BookStore:new { db = db }
    local queue_settings = LuaSettings:open(queue_path)
    local shelf_queue = ShelfQueue:new { settings = queue_settings }
    local list_queue = ListQueue:new { settings = queue_settings }
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new {
      settings = settings,
      shelf_cache = ShelfCache:new { path = shelf_path, open = function(p) return LuaSettings:open(p) end },
      book_store = books,
      list_store = ListStore:new { db = db, books = books },
      shelf_store = ShelfStore:new { db = db, books = books },
      shelf_queue = shelf_queue,
      list_queue = list_queue,
    }
    local list_store = manager.list_store

    local function count(name)
      local n = 0
      for _, c in ipairs(fixtures.calls or {}) do if c.name == name then n = n + 1 end end
      return n
    end
    local function topmost() return UIManager:getTopmostVisibleWidget() end
    local function nodeWith(text)
      local found
      for _, n in ipairs(emu:screenNodes()) do
        if n.text:find(text, 1, true) then found = n end
      end
      return found
    end
    local function tapText(text)
      local node = nodeWith(text)
      assert(node, "no " .. text .. " on screen:\n" .. emu:screenText())
      emu:tapExpecting(node.x + 5, node.y + 5)
      emu:pump()
    end
    local function tapButton(button)
      UIManager:_repaint()
      local d = button.dimen
      emu:tapExpecting(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
      emu:pump()
    end
    -- Shelf and Lists are buttons of their own: `row` is "Lists", or a shelf row's text for Shelf
    local function tapAdd(dialog, row)
      tapButton(row == "Lists" and dialog.lists_button or dialog.add_button)
    end
    -- close the message on top (an InfoMessage waits for its timeout, which does not run here)
    local function dismiss(expected_under)
      local top = topmost()
      assert(top ~= expected_under, "no message was on top")
      UIManager:close(top)
      emu:pump()
      assert(topmost() == expected_under, "the message did not leave the expected screen on top")
    end

    -- online: Home saves every list, and the book's details are opened (and so kept)
    manager:showHome()
    perf.run_loop()
    emu:closeAll()
    local book = fixtures.shelf_books[1] -- on lists 1, 2 and 3; not on list 4 ("Someday", empty)
    local book_id = book.book_id
    assert(list_store:memberOf(User:getId(), 1, book_id), "the book is not on the saved list 1")
    assert(list_store:memberOf(User:getId(), 4, book_id) == false, "list 4 should be saved whole, without the book")

    manager:showBookDetail(book_id)
    emu:pump()
    local dialog = topmost()
    assert(dialog and dialog.name == "hardcover_book_detail", "the details did not open")

    -- offline in both of the plugin's checks
    local was, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end
    local mark = #fixtures.calls

    -- ---------------------------------------------------------------- a list
    tapAdd(dialog, "Lists")
    local picker = topmost()
    assert(picker ~= dialog and picker.rows, "the lists picker did not open offline: " .. emu:screenText())
    emu:expectText("Someday (0)")
    emu:expectText("To Read - SciFi (7)")
    emu:shot("offline_book_changes_lists")

    tapText("Someday (0)")
    -- a tick only marks the row: nothing is kept or said until Done
    assert(list_queue:count() == 0, "a tick kept the change before Done")
    emu:shot("offline_book_changes_lists_ticked")
    tapText("Done")
    -- one message says what happened
    emu:expectText("Offline: added to")
    assert(#fixtures.calls == mark, "ticking a list offline asked the network")
    assert(list_queue:count() == 1 and list_queue:get(4, book_id).kind == "add", "the add was not kept")
    assert(list_store:memberOf(User:getId(), 4, book_id), "the saved list does not hold the book")
    local row4
    for _, row in ipairs(list_store:index(User:getId()).mine) do if row.id == 4 then row4 = row end end
    assert(row4 and row4.count == 1, "the list's size did not follow")
    UIManager:close(topmost())
    emu:pump()
    assert(topmost() == dialog, "the message did not leave the details on top")
    emu:expectText("Someday")

    -- ---------------------------------------------------------------- a shelf
    tapAdd(dialog, dialog.detail.status_id and "Change shelf" or "Add to shelf")
    picker = topmost()
    assert(picker ~= dialog and picker.rows, "the shelf picker did not open offline: " .. emu:screenText())
    tapText("Want to Read")
    assert(#fixtures.calls == mark, "choosing a shelf offline asked the network")
    local op = shelf_queue:get(book_id)
    assert(op and op.status_id == 1, "the shelf change was not kept")
    emu:expectText("Offline: the shelf change is kept")
    assert(dialog.detail.status_id == 1, "the screen did not change")
    dismiss(dialog)
    emu:expectText("Want to Read")
    emu:shot("offline_book_changes_detail")

    -- both are in the pending list, and say what they are
    local rows = PendingChanges.list({ shelf_queue = shelf_queue, list_queue = list_queue })
    assert(#rows == 2, "pending rows: " .. #rows)
    for _, r in ipairs(rows) do print("  pending: " .. PendingChanges.line(r)) end

    -- ---------------------------------------------------------------- the connection is back
    NetworkManager.isConnected, NetworkManager.getConnectionState = was, was_state
    local user_id = User:getId()
    local sent_shelf = shelf_queue:flush(Api, { user_id = user_id, on_sent = function(o, ub) manager:shelfSent(o, ub) end })
    local sent_list = list_queue:flush(Api, { user_id = user_id, on_sent = function(o, a) manager:listChangeSent(o, a) end })
    assert(sent_shelf.sent == 1 and sent_list.sent == 1, "sent " .. sent_shelf.sent .. " and " .. sent_list.sent)
    assert(count("updateUserBook") == 1 and count("addToList") == 1,
      "one write each: " .. count("updateUserBook") .. ", " .. count("addToList"))
    shelf_queue:flush(Api, { user_id = user_id })
    list_queue:flush(Api, { user_id = user_id })
    assert(count("updateUserBook") == 1 and count("addToList") == 1, "a change was sent twice")
    assert(shelf_queue:count() == 0 and list_queue:count() == 0, "something is still waiting")
    assert(dialog.detail.user_book_id == 9000 + book_id, "the open screen did not get the library record")
    assert(list_store:contents(user_id, 4).fingerprint == nil, "the saved list is not marked for a fresh download")

    emu:closeAll()
    db:close()
  end,
}
