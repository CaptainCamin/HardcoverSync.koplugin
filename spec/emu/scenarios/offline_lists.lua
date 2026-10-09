--[[--
Lists saved on the device, against the real SQLite file and KOReader's own JSON: the
store on its own, real saved rows through it unchanged, then the whole flow. Home online
saves every list without one being opened; offline the index, a list and a book's details
(with its synopsis) all open from the device; back online a list that has not changed
costs no request, and one that gained a book fetches only that book.

Screens: offline_lists_index, offline_lists_list, offline_lists_detail.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local T1 = "2026-10-08T15:22:25.183388+00:00"
local T2 = "2026-10-09T09:00:00.000001+00:00"

-- every list gets a time Hardcover last changed it and a counted size, as the real API
-- gives them; `changed` lists get T2 instead of T1
local function stamp(me, changed)
  changed = changed or {}
  local function one(list)
    list.updated_at = changed[list.id] and T2 or T1
    list.list_books_aggregate = { aggregate = { count = fixtures.list_sizes[list.id] or 0 } }
  end
  for _, list in ipairs(me[1].lists) do one(list) end
  for _, f in ipairs(me[1].followed_lists) do one(f.list) end
  return me
end

local function since(mark, name)
  local n = 0
  for i = mark + 1, #fixtures.calls do
    if fixtures.calls[i].name == name then n = n + 1 end
  end
  return n
end

local function tap_text(emu, needle)
  local node = emu:expectText(needle)
  emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
  emu:pump()
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

return {
  name = "offline_lists",

  run = function(emu)
    local SqliteStore = require("hardcover/lib/sqlite_store")
    local BookStore = require("hardcover/lib/book_store")
    local ListStore = require("hardcover/lib/list_store")
    local NetworkManager = require("ui/network/manager")

    local path = emu.DataStorage:getSettingsDir() .. "/hardcoversync_library_emu.sqlite3"
    for _, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do os.remove(path .. suffix) end

    -- ------------------------------------------------------------ the store, on its own
    local db = SqliteStore:new { path = path }
    assert(db:putRows({ { book_id = 1, row = '{"a":1}' }, { book_id = 2, row = '{"b":2}' } }, 100), "putRows")
    local got = db:getRows({ 1, 2, 3 })
    assert(got[1] == '{"a":1}' and got[2] == '{"b":2}' and got[3] == nil, "getRows")
    for id in pairs(got) do assert(type(id) == "number", "an id came back as " .. type(id)) end
    local known = db:knownIds({ 2, 3 })
    assert(known[2] and not known[3], "knownIds")
    assert(db:putDetail(1, 0, "plain", 10) and db:putDetail(1, 5, "edition", 20), "putDetail")
    assert(db:getDetail(1, 5) == "edition" and db:getDetail(1) == "plain" and db:anyDetail(1) == "edition", "details")
    assert(db:putOwned("list:1:7", { 1 }, "blob") and db:getBlob("list:1:7") == "blob", "putOwned")
    assert(db:putBlob("lists:1", "index") and db:getBlob("lists:1") == "index", "blobs")
    assert(db:evict(500), "evict")
    assert(db:getRows({ 2 })[2] == nil and db:getRows({ 1 })[1], "evict kept a book nothing holds, or dropped a held one")
    assert(db:dropOwned("list:1:") and db:getBlob("list:1:7") == nil and db:getBlob("lists:1") == "index", "dropOwned")
    -- more ids than SQLite binds in one statement
    local many, ids = {}, {}
    for i = 1, 1000 do many[i] = { book_id = 1000 + i, row = "{}" }; ids[i] = 1000 + i end
    assert(db:putRows(many, 1), "a big write")
    local n = 0
    for _ in pairs(db:knownIds(ids)) do n = n + 1 end
    assert(n == 1000, "knownIds over many ids found " .. n)
    assert(db:clear() and next(db:getRows({ 1 })) == nil, "clear")
    db:close()
    assert(next(db:getRows({ 1 })) == nil and db:putBlob("x", "y") == false, "a closed store raised or wrote")

    -- ------------------------------------------------------------ real rows, KOReader's JSON
    db = SqliteStore:new { path = path }
    local books = BookStore:new { db = db }
    local real = loadfile((os.getenv("HOME") or "") .. "/Library/Application Support/koreader/settings/hardcovershelf_cache.lua")
    local ok, saved = pcall(real or error)
    local count = 0
    if ok and type(saved) == "table" and type(saved.shelves) == "table" then
      for _, shelf in pairs(saved.shelves) do
        books:saveRows(shelf.entries or {})
        for _, e in ipairs(shelf.entries or {}) do
          local back = books:rows({ e.book_id })[e.book_id]
          assert(same(BookStore.rowOf(e), back), "book " .. tostring(e.book_id) .. " changed through KOReader's JSON")
          count = count + 1
        end
      end
    end
    print("  real rows round-tripped: " .. count)
    db:clear()

    -- ------------------------------------------------------------ the flow
    local SETTING = require("hardcover/lib/constants/settings")
    local settings = fixtures.real_settings(emu)
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    local lists_me = stamp(copy(fixtures.lists_me))
    fixtures.install({ settings = settings, lists_me = lists_me })

    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local shelf_path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_offline_lists.lua"
    os.remove(shelf_path)
    local list_store = ListStore:new { db = db, books = books }
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new {
      settings = settings,
      shelf_cache = ShelfCache:new { path = shelf_path, open = function(p) return LuaSettings:open(p) end },
      book_store = books,
      list_store = list_store,
    }

    -- online, Home: every list is saved without one being opened
    manager:showHome()
    emu:pump()
    local list_count = #lists_me[1].lists + #lists_me[1].followed_lists
    assert(since(0, "getLists") == 1, "Home did not fetch the lists")
    assert(since(0, "getListBooks") == list_count, "lists saved: " .. since(0, "getListBooks") .. " of " .. list_count)
    emu:closeAll()

    -- offline in both of the plugin's checks
    local was, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end
    local mark = #fixtures.calls

    manager:showLists()
    emu:pump()
    -- the note on top says when the lists are from; dismissed, the lists are under it
    emu:expectText("Offline: showing your lists as of")
    UIManager:close(UIManager:getTopmostVisibleWidget())
    emu:pump()
    emu:expectText("To Read - SciFi")
    emu:expectText("Top 25 Books to Unleash Your Creative Potential")
    emu:shot("offline_lists_index")

    tap_text(emu, "To Read - SciFi")
    emu:expectText("Offline: showing this list as of")
    UIManager:close(UIManager:getTopmostVisibleWidget())
    emu:pump()
    local top = UIManager:getTopmostVisibleWidget()
    assert(top and top.title == "To Read - SciFi" and #top.entries == 7, "the saved list did not open offline")
    assert(top.entries[1].rank == 1 and top.entries[1].title == fixtures.shelf_books[1].title, "order or rank lost")
    emu:shot("offline_lists_list")

    local first = fixtures.shelf_books[1]
    tap_text(emu, first.title)
    emu:expectText("Offline: showing saved details")
    UIManager:close(UIManager:getTopmostVisibleWidget())
    emu:pump()
    local detail = UIManager:getTopmostVisibleWidget()
    assert(detail and detail.name == "hardcover_book_detail", "the book did not open offline")
    local synopsis = detail.detail and detail.detail.book and detail.detail.book.description
    assert(synopsis and synopsis == first.description, "the synopsis did not come from the device")
    emu:shot("offline_lists_detail")
    assert(#fixtures.calls == mark, "offline, something was asked of the network")
    emu:closeAll()

    NetworkManager.isConnected, NetworkManager.getConnectionState = was, was_state

    -- back online: an unchanged list costs nothing
    mark = #fixtures.calls
    local row
    for _, r in ipairs(ListStore.allRows(list_store:index(fixtures.user_id or require("hardcover/lib/user"):getId()))) do
      if r.id == 2 then row = r end
    end
    assert(row, "the saved index has no list 2")
    manager:showList(row)
    emu:pump()
    assert(since(mark, "getListBooks") + since(mark, "getListMembers") == 0, "an unchanged list was downloaded again")
    emu:closeAll()

    -- a list that gained books on the website: Home's next check sees it and fetches which
    -- books the list holds, then only the one book no saved list has (the others are on
    -- the followed list already); opening the list then costs nothing
    local grown = 19
    assert(#fixtures.shelf_books >= grown, "the fixture has too few books")
    fixtures.list_sizes[2] = grown
    stamp(lists_me, { [2] = true })
    mark = #fixtures.calls
    manager:showHome()
    emu:pump()
    assert(since(mark, "getLists") == 1, "Home did not see the list change")
    assert(since(mark, "getListBooks") == 0 and since(mark, "getListMembers") == 1, "not a membership download")
    local asked
    for i = mark + 1, #fixtures.calls do
      if fixtures.calls[i].name == "getBooksByIds" then asked = fixtures.calls[i].args.ids end
    end
    assert(asked and #asked == 1 and asked[1] == fixtures.shelf_books[grown].book_id,
      "asked for books it had: " .. (asked and #asked or 0))
    emu:closeAll()

    mark = #fixtures.calls
    manager:showLists()
    emu:pump()
    tap_text(emu, "Books that made me grin")
    top = UIManager:getTopmostVisibleWidget()
    assert(top.title == "Books that made me grin" and #top.entries == grown, "the new books are not in the list")
    assert(#fixtures.calls == mark, "opening the updated list asked the network again")
    emu:closeAll()
    fixtures.list_sizes[2] = 4

    db:close()
  end,
}
