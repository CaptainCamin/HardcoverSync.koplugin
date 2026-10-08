-- Lists with and without a connection, through DialogManager: the index and a list open
-- from what is saved, a list that has not changed costs no request, one that changed
-- downloads only what it gained, every list is saved without being opened, and a book on
-- a saved list opens offline with its synopsis.
--
-- Fake dialogs and a recording API; the stores are the real ones over the in-memory
-- stand-in for the SQLite file.
--
-- Run with:  lua spec/offline_lists_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local json = dofile(PLUGIN .. "/spec/json.lua")
package.preload["json"] = function() return json end

local function make()
  return setmetatable({}, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end

local online = true
local stack = {}
package.preload["ui/uimanager"] = function()
  return {
    show = function(_, w) stack[#stack + 1] = w end,
    close = function(_, w) for i = #stack, 1, -1 do if stack[i] == w then table.remove(stack, i) end end end,
    isWidgetShown = function(_, w) for _, x in ipairs(stack) do if x == w then return true end end return false end,
    setDirty = function() end, scheduleIn = function() end, unschedule = function() end,
    nextTick = function(_, fn) fn() end,
  }
end
package.preload["ui/trapper"] = function()
  return {
    wrap = function(_, fn)
      local ok, err = coroutine.resume(coroutine.create(fn))
      if not ok then error("wrapped function raised: " .. tostring(err), 0) end
    end,
  }
end
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return online end }
end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["ffi/util"] = function()
  return { template = function(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
  end }
end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local Api = real_require("hardcover/lib/hardcover_api")
local User = real_require("hardcover/lib/user")
local StatusDialogs = real_require("hardcover/lib/ui/status_dialogs")
local Lists = real_require("hardcover/lib/lists")
local BookStore = real_require("hardcover/lib/book_store")
local ListStore = real_require("hardcover/lib/list_store")
local ShelfCache = real_require("hardcover/lib/shelf_cache")
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
local MemoryStore = dofile(PLUGIN .. "/spec/lib/memory_store.lua")
real_require("hardcover/lib/background").sleep = function() end
User.getId = function() return 1 end
User.refreshName = function() end

-- ------------------------------------------------------------ the API, recorded
local T1 = "2026-10-08T15:22:25.183388+00:00"
local T2 = "2026-10-09T09:00:00.000001+00:00"
local calls, server

local function call(name) calls[#calls + 1] = name end
local function named(name)
  local n = 0
  for _, c in ipairs(calls) do if c == name then n = n + 1 end end
  return n
end

local function book(id, extra)
  local b = { book_id = id, title = "Book " .. id, description = "Synopsis of book " .. id, release_year = 2001 }
  for k, v in pairs(extra or {}) do b[k] = v end
  return b
end

-- What Hardcover holds: lists by id, each { name, source, ranked, updated_at, books = ids }
local function listOf(id)
  local l = server.lists[id]
  local row = { id = id, source = l.source, name = l.name, count = #l.books, ranked = l.ranked or false,
                updated_at = l.updated_at, covers = {} }
  row.fingerprint = Lists.fingerprint(row)
  return row
end
local function index()
  local out = { mine = {}, following = {} }
  for _, id in ipairs(server.order) do
    local row = listOf(id)
    local group = row.source == "followed" and out.following or out.mine
    group[#group + 1] = row
  end
  return out
end

Api.getLists = function()
  call("getLists")
  if server.fail_index then return nil, { completed = false } end
  return index()
end
Api.getListCount = function()
  call("getListCount")
  local marks = {}
  for _, id in ipairs(server.order) do
    local row = listOf(id)
    marks[#marks + 1] = { id = id, source = row.source, fingerprint = row.fingerprint }
  end
  return #marks, marks
end
Api.getListBooks = function(_, id, _, ranked, offset)
  call("getListBooks")
  local out = {}
  if offset == 0 then
    for i, book_id in ipairs(server.lists[id].books) do
      out[#out + 1] = Lists.entry({ id = 1000 + book_id, position = i - 1, book = book(book_id) }, ranked)
    end
  end
  return out, nil, false
end
Api.getListMembers = function(_, id, _, offset)
  call("getListMembers")
  local out = {}
  if offset == 0 then
    for i, book_id in ipairs(server.lists[id].books) do
      out[#out + 1] = { list_book_id = 1000 + book_id, position = i - 1, book_id = book_id }
    end
  end
  return out, nil, false
end
Api.getBooksByIds = function(_, ids)
  call("getBooksByIds")
  server.asked_ids = ids
  local out = {}
  for i, id in ipairs(ids) do out[i] = book(id) end
  return out
end
local pending_detail
Api.getBookDetailAsync = function(_, _, _, _, cb) call("getBookDetail"); pending_detail = cb end
Api.getSeriesBooks = function() return nil end
Api.getSimilarBooksAsync = function() end
Api.getShelfCounts = function() call("getShelfCounts") return nil end
Api.getCurrentlyReading = function() call("getCurrentlyReading") return nil end
Api.getGoals = function() call("getGoals") return nil end

local infos, retries, loadings
StatusDialogs.info = function(text) infos[#infos + 1] = text end
StatusDialogs.loading = function() loadings = loadings + 1; return {} end
StatusDialogs.close = function() end
StatusDialogs.retry = function(err, op) retries[#retries + 1] = { err = err, op = op } end

-- ------------------------------------------------------------ fake screens
local shown = {}
local function fakeClass(path, kind)
  local class = real_require(path)
  class.new = function(_, o)
    o = o or {}
    o.kind = kind
    o.setEntries = function(self, entries, has_more) self.entries = entries; self.has_more = has_more; self.updates = (self.updates or 0) + 1 end
    o.setEmptyState = function(self, m) self.empty = m end
    o.setLists = function(self, mine, following) self.mine = mine; self.following = following; self.set_lists = (self.set_lists or 0) + 1 end
    o.setMessage = function(self, m) self.message = m end
    o.setDetail = function(self, d) self.detail = d end
    o.setRows = function() end
    o.setReading = function() end
    o.rebuildSoon = function() end
    o.rebuild = function(self) self.rebuilt = (self.rebuilt or 0) + 1 end
    o.free = function() end
    shown[kind] = o
    return o
  end
end
fakeClass("hardcover/lib/ui/lists_dialog", "lists")
fakeClass("hardcover/lib/ui/shelf_dialog", "shelf")
fakeClass("hardcover/lib/ui/book_detail_dialog", "detail")
fakeClass("hardcover/lib/ui/home_dialog", "home")

local clock = 10000
local db
local function newManager()
  calls, infos, retries, loadings, stack, shown = {}, {}, {}, 0, {}, {}
  pending_detail = nil
  online = true
  server = {
    order = { 10, 11, 20 },
    lists = {
      [10] = { name = "6 Stars", source = "mine", ranked = true, updated_at = T1, books = { 1, 2, 3 } },
      [11] = { name = "Owned", source = "mine", updated_at = T1, books = { 3, 4 } },
      [20] = { name = "Top 25", source = "followed", updated_at = T1, books = { 5 } },
    },
  }
  db = MemoryStore.new()
  local books = BookStore:new { db = db, now = function() return clock end }
  local shelf_data = {}
  return setmetatable({
    settings = { compatibilityMode = function() return false end, readSetting = function() end },
    shelf_cache = ShelfCache:new { path = "/x", open = function()
      return { readSetting = function(_, k) return shelf_data[k] end,
               saveSetting = function(_, k, v) shelf_data[k] = v end, flush = function() end }
    end },
    book_store = books,
    list_store = ListStore:new { db = db, books = books, now = function() return clock end },
  }, { __index = DialogManager })
end

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local function rowNamed(manager, name)
  for _, row in ipairs(ListStore.allRows(manager.list_store:index(1))) do
    if row.name == name then return row end
  end
end

-- open the lists online once, so everything is saved
local function primed()
  local m = newManager()
  m:showLists()
  calls = {}
  return m
end

print("\n== the lists screen ==")

check("the first time online, the index is fetched, shown, saved, and every list saved with it", function()
  local m = newManager()
  m:showLists()
  local d = shown.lists
  assert(d.message and d.message:find("Loading"), "no loading line")
  assert(named("getLists") == 1 and d.set_lists == 1 and #d.mine == 2 and #d.following == 1)
  assert(named("getListBooks") == 3, "lists saved without being opened: " .. named("getListBooks"))
  assert(#m.list_store:entries(1, rowNamed(m, "Top 25")) == 1)
end)

check("offline, the saved lists are on screen at once, with when they are from, and nothing is asked", function()
  local m = primed()
  online = false
  m:showLists()
  local d = shown.lists
  assert(#d.mine == 2 and d.mine[1].name == "6 Stars" and not d.message)
  assert(#calls == 0 and infos[1]:find("Offline: showing your lists as of"), tostring(infos[1]))
end)

check("offline with nothing saved, the screen says it needs a connection the first time", function()
  local m = newManager()
  online = false
  m:showLists()
  assert(shown.lists.message == "Lists need an internet connection the first time." and #calls == 0)
end)

check("checked a moment ago (Home did it): the saved lists, and no request", function()
  local m = primed()
  clock = clock + 60
  m:showLists()
  assert(#calls == 0 and #shown.lists.mine == 2, "asked: " .. table.concat(calls, ","))
end)

check("checked a while ago: asked again; an unchanged answer does not redraw the screen", function()
  local m = primed()
  clock = clock + 3600
  m:showLists()
  assert(named("getLists") == 1 and (shown.lists.set_lists or 0) == 0)
  assert(named("getListBooks") == 0 and named("getListMembers") == 0, "unchanged lists were downloaded")
end)

check("a list made on the website appears, and is saved", function()
  local m = primed()
  clock = clock + 3600
  server.order[#server.order + 1] = 12
  server.lists[12] = { name = "New", source = "mine", updated_at = T2, books = { 6 } }
  m:showLists()
  assert(shown.lists.set_lists == 1 and #shown.lists.mine == 3)
  assert(named("getListBooks") == 1 and m.list_store:contents(1, 12))
end)

check("the index failing with lists saved keeps them on screen, without a retry box", function()
  local m = primed()
  clock = clock + 3600
  server.fail_index = true
  m:showLists()
  assert(#shown.lists.mine == 2 and #retries == 0)
end)

check("the index failing with nothing saved offers a retry", function()
  local m = newManager()
  server.fail_index = true
  m:showLists()
  assert(#retries == 1 and retries[1].op == "Loading your lists")
end)

print("\n== one list ==")

check("a list that has not changed opens from the device, with no request at all", function()
  local m = primed()
  m:showList(rowNamed(m, "6 Stars"))
  local d = shown.shelf
  assert(#d.entries == 3 and d.entries[1].title == "Book 1" and d.entries[1].rank == 1)
  assert(#calls == 0, "asked: " .. table.concat(calls, ","))
end)

check("a list that gained a book downloads which books it holds, and only the new book", function()
  local m = primed()
  server.lists[11].books = { 3, 4, 7 }
  server.lists[11].updated_at = T2
  m:showList(listOf(11))
  local d = shown.shelf
  assert(named("getListMembers") == 1 and named("getBooksByIds") == 1 and named("getListBooks") == 0)
  assert(#server.asked_ids == 1 and server.asked_ids[1] == 7, "asked for books it had")
  assert(#d.entries == 3 and d.entries[3].book_id == 7)
end)

check("the saved copy is on screen before a changed list arrives", function()
  local m = primed()
  server.lists[11].updated_at = T2
  -- the download comes back later: hold the queue's request
  local held
  local orig = Api.getListMembers
  Api.getListMembers = function(...)
    held = { ... }
    coroutine.yield()
    return orig(...)
  end
  local ok, err = pcall(function()
    m:showList(listOf(11))
    assert(#shown.shelf.entries == 2 and loadings == 0, "the saved books were not shown first")
    assert(held, "the download did not start")
  end)
  Api.getListMembers = orig
  assert(ok, err)
end)

check("a list nothing is saved of loads with a loading line, rows as they come, then is saved", function()
  local m = newManager()
  m.list_store:putIndex(1, index())
  m:showList(listOf(20))
  assert(loadings == 1 and named("getListBooks") == 1 and #shown.shelf.entries == 1)
  assert(m.list_store:contents(1, 20).complete)
end)

check("an empty list says so", function()
  local m = primed()
  server.lists[20].books = {}
  server.lists[20].updated_at = T2
  m:showList(listOf(20))
  assert(shown.shelf.empty == "No books on this list yet")
end)

check("offline, a saved list opens with when it is from; one never saved says it needs a connection", function()
  local m = primed()
  online = false
  m:showList(rowNamed(m, "Owned"))
  assert(#shown.shelf.entries == 2 and infos[1]:find("Offline: showing this list as of"))
  local m2 = newManager()
  online = false
  m2:showList(listOf(11))
  assert(infos[1] == "Lists need an internet connection the first time.")
end)

check("Refresh downloads the list and its books again, in full", function()
  local m = primed()
  m:showList(rowNamed(m, "Owned"))
  local refresh = shown.shelf.actions[1]
  assert(refresh.text == "Refresh")
  refresh.callback()
  assert(named("getListBooks") == 1 and shown.shelf.updates >= 2)
end)

check("a manager with no stores still opens a list from the network", function()
  local m = newManager()
  m.book_store, m.list_store = nil, nil
  m:showList(listOf(11))
  assert(named("getListBooks") == 1 and #shown.shelf.entries == 2 and #retries == 0)
end)

check("a book put on a list from its details is in the list next time, however soon", function()
  local m = primed()
  -- what the details screen's tick box does once Hardcover has said yes
  server.lists[11].books = { 3, 4, 9 }
  server.lists[11].updated_at = T2
  m:refreshListsScreen(11, 3)
  clock = clock + 30 -- well inside the five minutes Home's check is trusted for
  m:showLists()
  assert(named("getLists") == 1, "the lists were trusted after a change made here")
  assert(named("getListMembers") == 1, "the changed list was not downloaded again")
  m:showList(rowNamed(m, "Owned"))
  assert(#shown.shelf.entries == 3 and shown.shelf.entries[3].book_id == 9)
end)

print("\n== a book from a saved list ==")

check("offline, a book on a saved list opens with its synopsis", function()
  local m = primed()
  online = false
  m:showBookDetail(4)
  local d = shown.detail.detail
  assert(d and d.book.title == "Book 4" and d.book.description == "Synopsis of book 4")
  assert(#calls == 0)
end)

check("a book opened online is kept, and opens offline with everything it showed", function()
  local m = newManager()
  m:showBookDetail(9)
  pending_detail({ book = book(9, { subtitle = "The subtitle", user_books = { { id = 1 } } }), user_book_id = 1 })
  online = false
  m:showBookDetail(9)
  local d = shown.detail.detail
  assert(d.book.subtitle == "The subtitle", "the opened book's details were not kept")
end)

print("\n== Home keeps the lists saved ==")

check("Home's check with nothing changed fetches nothing and notes the lists are current", function()
  local m = primed()
  clock = clock + 3600
  local _, marks = Api.getListCount()
  calls = {}
  m:checkLists(marks)
  assert(#calls == 0 and m.list_store:index(1).checked_at == clock)
end)

check("Home's check after a change fetches the index and only the list that changed", function()
  local m = primed()
  server.lists[20].books = { 5, 8 }
  server.lists[20].updated_at = T2
  local _, marks = Api.getListCount()
  calls = {}
  m:checkLists(marks)
  assert(named("getLists") == 1 and named("getListMembers") == 1 and named("getBooksByIds") == 1,
    "asked: " .. table.concat(calls, ","))
  assert(#m.list_store:entries(1, rowNamed(m, "Top 25")) == 2)
end)

check("opening Home runs the check after Home's own requests", function()
  local m = newManager()
  m.checkForUpdate = function() end
  m:showHome()
  local last_home = 0
  for i, c in ipairs(calls) do
    if c == "getListCount" or c == "getGoals" then last_home = i end
  end
  assert(named("getLists") == 1 and calls[last_home + 1] == "getLists",
    "the lists were not checked after Home: " .. table.concat(calls, ","))
  assert(named("getListBooks") == 3)
end)

r.finish()
