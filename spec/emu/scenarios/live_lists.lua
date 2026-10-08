--[[--
Lists kept on the device, against the real Hardcover API and the real SQLite file. Only
reads: nothing on the account is changed.

  1. Home saves every list (yours and followed) without one being opened; each saved
     list holds as many books as Hardcover counts.
  2. Home's next check, with nothing changed, downloads nothing.
  3. A list that lost a book since it was saved (done here by editing the saved copy)
     downloads which books it holds and only that one book.
  4. Offline: the index, a list and a book's details (with its synopsis) open from the
     device with no request.

Opt in like live.lua:  KO_LIVE_TOKEN_FILE=/path/tokens.json spec/emu/run.sh live_lists

Screens: live_lists_index, live_lists_list, live_lists_offline_detail.
]]

local UIManager = require("ui/uimanager")
local fixtures = require("fixtures")

-- Run the UI until the lists queue is idle (downloads happen in the background and a
-- rate-limited one waits in real time), up to `seconds`.
local function settle(emu, manager, seconds)
  local deadline = os.time() + (seconds or 120)
  repeat
    emu:pump(200)
    local queue = manager._lists_queue
    local busy = queue and (queue.running or #queue.jobs > 0)
    if busy then os.execute("sleep 1") end
  until not busy or os.time() > deadline
  local queue = manager._lists_queue
  assert(not (queue and (queue.running or #queue.jobs > 0)), "the list downloads did not finish in time")
end

return {
  name = "live_lists",

  run = function(emu)
    local live = require("live_api").install()
    if not live then
      print("  live_lists: KO_LIVE_TOKEN_FILE not set; skipping")
      return
    end
    local Api = require("hardcover/lib/hardcover_api")
    local NetworkManager = require("ui/network/manager")

    -- count the requests that matter here
    local counts = {}
    for _, name in ipairs({ "getLists", "getListCount", "getListBooks", "getListMembers", "getBooksByIds",
                            "getBookDetail" }) do
      local original = Api[name]
      Api[name] = function(...)
        counts[name] = (counts[name] or 0) + 1
        return original(...)
      end
    end
    local function snapshot()
      local copy = {}
      for k, v in pairs(counts) do copy[k] = v end
      return copy
    end
    local function since(before, name) return (counts[name] or 0) - (before[name] or 0) end

    local settings = fixtures.real_settings(emu)
    require("hardcover/lib/user").settings = settings
    local me = Api:me()
    assert(me and me.id, "the API did not return who you are: check the token")
    settings:updateSetting(require("hardcover/lib/constants/settings").USER_ID, me.id)
    local user_id = me.id

    local SqliteStore = require("hardcover/lib/sqlite_store")
    local BookStore = require("hardcover/lib/book_store")
    local ListStore = require("hardcover/lib/list_store")
    local db_path = emu.DataStorage:getSettingsDir() .. "/hardcoversync_library_live.sqlite3"
    for _, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do os.remove(db_path .. suffix) end
    local db = SqliteStore:new { path = db_path }
    local books = BookStore:new { db = db }
    local lists = ListStore:new { db = db, books = books }

    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local shelf_path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_live_lists.lua"
    os.remove(shelf_path)
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new {
      settings = settings,
      shelf_cache = ShelfCache:new { path = shelf_path, open = function(p) return LuaSettings:open(p) end },
      book_store = books,
      list_store = lists,
    }
    manager.checkForUpdate = function() end

    -- ------------------------------------------------------------ 1. Home saves every list
    local bytes_before = live.bytes
    manager:showHome()
    settle(emu, manager, 180)
    emu:closeAll()
    local index = lists:index(user_id)
    assert(index, "Home did not save the lists")
    local rows = ListStore.allRows(index)
    local total_books = 0
    for _, row in ipairs(rows) do
      local entries, saved = lists:entries(user_id, row)
      assert(saved and saved.complete, "list " .. row.name .. " was not saved whole")
      assert(#entries == row.count, string.format("list %q: %d books saved, Hardcover counts %d",
        row.name, #entries, row.count))
      assert(saved.fingerprint == row.fingerprint, "list " .. row.name .. " saved without its fingerprint")
      total_books = total_books + #entries
    end
    print(string.format("  live_lists: %d lists, %d books saved (%d getListBooks, %d KB received)",
      #rows, total_books, counts.getListBooks or 0, math.floor((live.bytes - bytes_before) / 1024)))

    -- ------------------------------------------------------------ 2. nothing changed
    os.execute("sleep 12") -- the burst allowance refills (10 requests, then one a second)
    local before = snapshot()
    bytes_before = live.bytes
    local count, marks = Api:getListCount()
    assert(count == #rows and marks, "the list check did not answer")
    manager:checkLists(marks)
    settle(emu, manager, 60)
    assert(since(before, "getLists") == 0, "an unchanged index was fetched again")
    assert(since(before, "getListBooks") + since(before, "getListMembers") == 0, "an unchanged list was downloaded")
    print(string.format("  live_lists: recheck with nothing changed: 1 request, %d bytes", live.bytes - bytes_before))

    -- ------------------------------------------------------------ 3. a list that lost a book
    -- the biggest list of yours with a book no other list holds
    local holders = {}
    for _, row in ipairs(rows) do
      for _, m in ipairs(lists:contents(user_id, row.id).members) do
        holders[m.book_id] = (holders[m.book_id] or 0) + 1
      end
    end
    local target, gone
    for _, row in ipairs(rows) do
      if row.count >= 2 and (not target or row.count > target.count) then
        for _, m in ipairs(lists:contents(user_id, row.id).members) do
          if holders[m.book_id] == 1 then target, gone = row, m.book_id break end
        end
      end
    end
    if target then
      local kept = {}
      for _, m in ipairs(lists:contents(user_id, target.id).members) do
        if m.book_id ~= gone then kept[#kept + 1] = m end
      end
      local stale = {}
      for k, v in pairs(target) do stale[k] = v end
      stale.fingerprint = "stale"
      lists:putMembers(user_id, stale, kept, true)
      assert(books:rows({ gone })[gone] == nil, "the book the list lost is still in the store")

      before = snapshot()
      bytes_before = live.bytes
      manager:showList(target)
      settle(emu, manager, 60)
      local shown = UIManager:getTopmostVisibleWidget()
      assert(shown and shown.entries and #shown.entries == target.count,
        "the list did not come back whole: " .. tostring(shown and shown.entries and #shown.entries))
      assert(since(before, "getListMembers") >= 1 and since(before, "getListBooks") == 0, "not a membership download")
      assert(since(before, "getBooksByIds") == 1, "asked for books it had")
      print(string.format("  live_lists: %q re-downloaded as membership + 1 book: %d bytes (a full download was %s)",
        target.name, live.bytes - bytes_before, "the first pass"))
      emu:shot("live_lists_list")
      emu:closeAll()
    else
      print("  live_lists: no list with a book of its own; step 3 skipped")
    end

    -- ------------------------------------------------------------ 4. offline
    local was, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end
    local requests = live.requests

    manager:showLists()
    emu:pump()
    UIManager:close(UIManager:getTopmostVisibleWidget()) -- the "as of" note
    emu:pump()
    emu:shot("live_lists_index")
    -- a list with a book that has a synopsis (some books on Hardcover have none)
    local first, book_with_synopsis
    for _, row in ipairs(rows) do
      for _, e in ipairs(lists:entries(user_id, row)) do
        if type(e.description) == "string" and #e.description > 0 then
          first, book_with_synopsis = row, e
          break
        end
      end
      if first then break end
    end
    assert(first, "no saved book has a synopsis")
    manager:showList(first)
    emu:pump()
    UIManager:close(UIManager:getTopmostVisibleWidget())
    emu:pump()
    local list_screen = UIManager:getTopmostVisibleWidget()
    assert(list_screen and #list_screen.entries == first.count, "a saved list did not open offline")
    local book = book_with_synopsis
    manager:showBookDetail(book.book_id)
    emu:pump()
    UIManager:close(UIManager:getTopmostVisibleWidget())
    emu:pump()
    local detail = UIManager:getTopmostVisibleWidget()
    assert(detail and detail.detail and detail.detail.book.title == book.title, "a saved book did not open offline")
    assert(detail.detail.book.description == book.description, "the synopsis did not come back whole")
    print(string.format("  live_lists: offline %q opened with its whole synopsis (%d characters)",
      book.title, #book.description))
    emu:shot("live_lists_offline_detail")
    assert(live.requests == requests, "offline, something was asked of the network")
    emu:closeAll()
    NetworkManager.isConnected, NetworkManager.getConnectionState = was, was_state

    -- measured after closing: until then the newest writes are in SQLite's -wal file
    db:close()
    local f = io.open(db_path, "rb")
    local size = f and f:seek("end") or 0
    if f then f:close() end
    print(string.format("  live_lists: database %d KB", math.floor(size / 1024)))
    live.close()
  end,
}
