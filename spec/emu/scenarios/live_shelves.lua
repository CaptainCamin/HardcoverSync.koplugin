--[[--
Shelves kept on the device, against the real Hardcover API and the real SQLite file. Only
reads: nothing on the account is changed.

  1. Home saves every shelf without one being opened; each holds as many books as
     Hardcover counts.
  2. Home's next check, with nothing changed, downloads nothing; a shelf then opens with
     no request, and reading the biggest one back from the database is timed.
  3. A shelf the device thinks changed (done here by marking it) downloads only which
     books it holds, and no book.
  4. A book's details, fetched once, open again from the device with no request for the
     book; the similar-books request brings your status.

Opt in like live.lua:  KO_LIVE_TOKEN_FILE=/path/tokens.json spec/emu/run.sh live_shelves

Screens: live_shelves_read, live_shelves_detail.
]]

local UIManager = require("ui/uimanager")
local fixtures = require("fixtures")

local function settle(emu, manager, seconds)
  local deadline = os.time() + (seconds or 180)
  repeat
    emu:pump(200)
    local queue = manager._lists_queue
    local busy = queue and (queue.running or #queue.jobs > 0)
    if busy then os.execute("sleep 1") end
  until not busy or os.time() > deadline
  local queue = manager._lists_queue
  assert(not (queue and (queue.running or #queue.jobs > 0)), "the downloads did not finish in time")
end

return {
  name = "live_shelves",

  run = function(emu)
    local live = require("live_api").install()
    if not live then
      print("  live_shelves: KO_LIVE_TOKEN_FILE not set; skipping")
      return
    end
    local Api = require("hardcover/lib/hardcover_api")
    local Home = require("hardcover/lib/home")

    local counts = {}
    for _, name in ipairs({ "getShelfCounts", "getShelf", "getShelfMembers", "getBooksByIds", "getBookDetail",
                            "getSimilarBooks", "getLists", "getListBooks" }) do
      local original = Api[name]
      Api[name] = function(...)
        counts[name] = (counts[name] or 0) + 1
        return original(...)
      end
    end
    local function snapshot() local c = {} for k, v in pairs(counts) do c[k] = v end return c end
    -- the scenario's own checks wait out a rate limit, as the plugin's requests do
    local ShelfLoader = require("hardcover/lib/shelf_loader")
    local function prints_now(ids)
      local _, _, p = ShelfLoader.patient(function() return Api:getShelfCounts(require("hardcover/lib/user"):getId(), ids) end,
        function(s) os.execute("sleep " .. s) end)
      return p
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
    local ShelfStore = require("hardcover/lib/shelf_store")
    local db_path = emu.DataStorage:getSettingsDir() .. "/hardcoversync_library_live_shelves.sqlite3"
    for _, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do os.remove(db_path .. suffix) end
    local db = SqliteStore:new { path = db_path }
    local books = BookStore:new { db = db }
    local shelves = ShelfStore:new { db = db, books = books }

    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local cache_path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_live_shelves.lua"
    os.remove(cache_path)
    os.remove(cache_path:gsub("%.lua$", "_home.lua"))
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new {
      settings = settings,
      shelf_cache = ShelfCache:new { path = cache_path, open = function(p) return LuaSettings:open(p) end },
      book_store = books,
      list_store = ListStore:new { db = db, books = books },
      shelf_store = shelves,
    }
    manager.checkForUpdate = function() end

    -- ------------------------------------------------------------ 1. Home saves every shelf
    local bytes, t0 = live.bytes, os.time()
    manager:showHome()
    settle(emu, manager, 300)
    emu:closeAll()
    local prints = prints_now(Home.statusIds())
    assert(prints, "the shelf check failed")
    local total = 0
    for _, status_id in ipairs(Home.statusIds()) do
      local entries, meta = shelves:entries(user_id, status_id)
      assert(entries and meta and meta.complete, "shelf " .. status_id .. " was not saved whole")
      local count = tonumber(prints[status_id]:match("^(%d+)"))
      assert(#entries == count, string.format("shelf %d: %d saved, Hardcover counts %d", status_id, #entries, count))
      total = total + #entries
    end
    print(string.format("  live_shelves: 4 shelves, %d books saved by Home in %ds (%d getShelf, %d KB with the lists)",
      total, os.time() - t0, counts.getShelf or 0, math.floor((live.bytes - bytes) / 1024)))

    -- ------------------------------------------------------------ 2. nothing changed
    os.execute("sleep 12")
    local before = snapshot()
    bytes = live.bytes
    manager:checkShelves(prints_now(Home.statusIds()))
    settle(emu, manager, 60)
    assert(since(before, "getShelf") + since(before, "getShelfMembers") == 0, "an unchanged shelf was downloaded")
    print(string.format("  live_shelves: recheck with nothing changed: 1 request, %d bytes", live.bytes - bytes))

    local read_status = 3
    local clock = os.clock()
    for _ = 1, 10 do shelves:entries(user_id, read_status) end
    local read_entries = shelves:entries(user_id, read_status)
    print(string.format("  live_shelves: Read (%d books) read back from the database: %.1f ms",
      #read_entries, (os.clock() - clock) * 100))

    before = snapshot()
    manager:showShelf(read_status, "Read")
    emu:pump()
    local top = UIManager:getTopmostVisibleWidget()
    assert(top and top.entries and #top.entries == #read_entries, "Read did not open from the device")
    assert(since(before, "getShelfCounts") + since(before, "getShelf") + since(before, "getShelfMembers") == 0,
      "opening a shelf Home just checked asked the network")
    emu:shot("live_shelves_read")
    emu:closeAll()

    -- ------------------------------------------------------------ 3. a shelf marked changed
    shelves:markStale(user_id, read_status)
    before = snapshot()
    bytes = live.bytes
    manager:showShelf(read_status, "Read")
    settle(emu, manager, 60)
    assert(since(before, "getShelf") == 0, "Read was downloaded in full")
    assert(since(before, "getShelfMembers") >= 1 and since(before, "getBooksByIds") == 0, "books it had were asked for")
    print(string.format("  live_shelves: Read re-downloaded as membership only: %d KB",
      math.floor((live.bytes - bytes) / 1024)))
    emu:closeAll()

    -- ------------------------------------------------------------ 4. a book's details from the device
    local book
    for _, e in ipairs(read_entries) do
      if e.description and e.cached_image and e.release_year and e.release_year < 2025 then book = e break end
    end
    assert(book, "no settled book on Read")
    os.execute("sleep 5")
    manager:showBookDetail(book.book_id)
    settle(emu, manager, 30)
    for _ = 1, 20 do emu:pump(200) end
    emu:closeAll()
    assert(books:settledDetail(book.book_id), "the book's details were not kept as settled")
    before = snapshot()
    manager:showBookDetail(book.book_id)
    for _ = 1, 20 do emu:pump(200) end
    local detail = UIManager:getTopmostVisibleWidget()
    assert(since(before, "getBookDetail") == 0, "the book was asked for again")
    assert(detail and detail.detail and detail.detail.status_id == read_status, "status not from the shelves")
    assert(since(before, "getSimilarBooks") == 1, "the similar request did not go")
    print(string.format("  live_shelves: %q opened from the device, no request for the book", book.title))
    emu:shot("live_shelves_detail")
    emu:closeAll()

    db:close()
    local f = io.open(db_path, "rb")
    print(string.format("  live_shelves: database %d KB", math.floor((f and f:seek("end") or 0) / 1024)))
    if f then f:close() end
    live.close()
  end,
}
