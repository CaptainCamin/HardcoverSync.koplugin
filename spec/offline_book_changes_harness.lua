-- Putting a book on a shelf, and on and off lists, from its details screen without a
-- connection: the change is kept, shown at once (the screen, the saved shelves and lists,
-- the counts), sent once when the connection is back, and a saved list or shelf is never
-- downloaded over a change that has not been sent.
--
-- Drives DialogManager's flows against the real stores over the in-memory stand-in for the
-- SQLite file, the real queues, a switchable network and a recording API.
--
-- Run with:  lua spec/offline_book_changes_harness.lua [plugin-root]

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
local stack, ticks = {}, {}
package.preload["ui/uimanager"] = function()
  return {
    show = function(_, w) stack[#stack + 1] = w end,
    close = function(_, w) for i = #stack, 1, -1 do if stack[i] == w then table.remove(stack, i) end end end,
    isWidgetShown = function(_, w) for _, x in ipairs(stack) do if x == w then return true end end return false end,
    setDirty = function() end, scheduleIn = function() end, unschedule = function() end,
    forceRePaint = function() end,
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
  }
end
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn) assert(coroutine.resume(coroutine.create(fn))) end }
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
package.preload["hardcover/lib/ui/picker"] = function()
  local M = {}
  function M.new(o)
    o.is_picker = true
    for _, row in ipairs(o.rows) do row.enabled = true end
    return o
  end
  function M.setRow(picker, id, text, enabled, checked)
    for _, row in ipairs(picker.rows) do
      if row.id == id then
        row.text, row.enabled = text, enabled ~= false
        if checked ~= nil then row.checked = checked end
      end
    end
  end
  return M
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
local ListsSync = real_require("hardcover/lib/lists_sync")
local BookStore = real_require("hardcover/lib/book_store")
local ListStore = real_require("hardcover/lib/list_store")
local ShelfStore = real_require("hardcover/lib/shelf_store")
local ShelfCache = real_require("hardcover/lib/shelf_cache")
local ShelfQueue = real_require("hardcover/lib/shelf_queue")
local ListQueue = real_require("hardcover/lib/list_queue")
local RatingQueue = real_require("hardcover/lib/rating_queue")
local PendingChanges = real_require("hardcover/lib/pending_changes")
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
local MemoryStore = dofile(PLUGIN .. "/spec/lib/memory_store.lua")
User.getId = function() return 1 end

local UIM = real_require("ui/uimanager")

-- ------------------------------------------------------------ the API, recorded
local calls
local function count(name)
  local n = 0
  for _, c in ipairs(calls) do if c.name == name then n = n + 1 end end
  return n
end
local update_cb, remove_cb, add_cb, remove_list_cb
Api.updateUserBookAsync = function(_, book_id, status_id, _p, edition_id, cb)
  calls[#calls + 1] = { name = "updateUserBook", book_id = book_id, status_id = status_id, edition_id = edition_id }
  update_cb = cb
end
Api.removeUserBookAsync = function(_, id, cb)
  calls[#calls + 1] = { name = "removeUserBook", id = id }
  remove_cb = cb
end
Api.addToListAsync = function(_, book_id, list_id, position, cb)
  calls[#calls + 1] = { name = "addToList", book_id = book_id, list_id = list_id, position = position }
  add_cb = cb
end
Api.removeFromListAsync = function(_, list_book_id, cb)
  calls[#calls + 1] = { name = "removeFromList", id = list_book_id }
  remove_list_cb = cb
end
Api.getBookListsAsync = function(_, book_id, cb)
  calls[#calls + 1] = { name = "getBookLists", book_id = book_id }
  cb({}, nil)
end
-- the queues' own (synchronous) requests
local server_calls
local function serverApi()
  local api = {}
  function api:updateUserBook(book_id, status_id, _p, edition_id)
    server_calls[#server_calls + 1] = { name = "updateUserBook", book_id = book_id, status_id = status_id, edition_id = edition_id }
    return { id = 700 + book_id, status_id = status_id }
  end
  function api:setFinishedDate(user_book, date)
    server_calls[#server_calls + 1] = { name = "setFinishedDate", date = date }
    return user_book
  end
  function api:removeUserBook(id)
    server_calls[#server_calls + 1] = { name = "removeUserBook", id = id }
    return { id = id }
  end
  function api:addToList(book_id, list_id, position)
    server_calls[#server_calls + 1] = { name = "addToList", book_id = book_id, list_id = list_id, position = position }
    return { id = 5000 + book_id }
  end
  function api:removeFromList(id)
    server_calls[#server_calls + 1] = { name = "removeFromList", id = id }
    return { id = id }
  end
  function api:getBookLists() return {} end
  return api
end

local infos, retries, confirms
StatusDialogs.info = function(text) infos[#infos + 1] = text end
StatusDialogs.error = function(text) infos[#infos + 1] = text end
StatusDialogs.loading = function() return { __loading = true } end
StatusDialogs.close = function() end
StatusDialogs.retry = function(err, op, again) retries[#retries + 1] = { err = err, op = op, again = again } end
StatusDialogs.confirm = function(o) confirms[#confirms + 1] = o end
Api.auth = { hasScope = function() return nil end, usingOAuth = function() return true end, needsReauth = function() return false end }

-- ------------------------------------------------------------ a manager with real stores
local clock = 10000
local db, shelves, books, list_store, shelf_queue, list_queue, rating_queue
local T1 = "2026-10-08T15:22:25.183388+00:00"

local function memorySettings()
  local data = {}
  return {
    readSetting = function(_, k) return data[k] end,
    saveSetting = function(_, k, v) data[k] = v end,
    flush = function() end,
  }
end

local function bookRow(id)
  return { book_id = id, title = "Book " .. id, description = "Synopsis " .. id, release_year = 2001 }
end

local function newManager()
  calls, server_calls, infos, retries, confirms = {}, {}, {}, {}, {}
  stack, ticks, online = {}, {}, true
  db = MemoryStore.new()
  books = BookStore:new { db = db, now = function() return clock end }
  shelves = ShelfStore:new { db = db, books = books, now = function() return clock end }
  list_store = ListStore:new { db = db, books = books, now = function() return clock end }
  local settings = memorySettings()
  shelf_queue = ShelfQueue:new { settings = settings }
  list_queue = ListQueue:new { settings = settings }
  rating_queue = RatingQueue:new { settings = settings }

  local data = {}
  local cache_store = {
    readSetting = function(_, k) return data[k] end,
    saveSetting = function(_, k, v) data[k] = v end,
    flush = function() end,
  }
  local m = setmetatable({
    settings = {},
    book_store = books, shelf_store = shelves, list_store = list_store,
    shelf_queue = shelf_queue, list_queue = list_queue, rating_queue = rating_queue,
    shelf_cache = ShelfCache:new { path = "/x", open = function() return cache_store end },
  }, { __index = DialogManager })

  -- the shelves, saved whole: book 1 on Want to Read (1), book 3 on Read (3), nothing on 2 and 5
  books:saveRows({ bookRow(1), bookRow(3), bookRow(100), bookRow(101) })
  shelves:putMembers(1, 1, { { user_book_id = 51, book_id = 1, rating = 4 } }, true, "fp1")
  shelves:putMembers(1, 2, {}, true, "fp2")
  shelves:putMembers(1, 3, { { user_book_id = 53, book_id = 3 } }, true, "fp3")
  shelves:putMembers(1, 5, {}, true, "fp5")
  m.shelf_cache:putCounts(1, { [1] = 1, [2] = 0, [3] = 1, [5] = 0 })
  return m
end

local check = r.test

-- a details screen that records what it is told
local function detailScreen(m, detail)
  local d = { detail = detail, status_updates = {}, synced = {} }
  function d:setStatus(status_id, user_book_id)
    self.status_updates[#self.status_updates + 1] = { status_id, user_book_id }
    self.detail.status_id, self.detail.user_book_id = status_id, user_book_id
  end
  function d:setLists(rows) self.synced[#self.synced + 1] = rows end
  function d:setRating() end
  UIM:show(d)
  m:screens():track("book", d)
  return d
end

local shown
local function showing(fn)
  shown = nil
  local real_show = UIM.show
  UIM.show = function(self, w) if w.is_picker then shown = w end; return real_show(self, w) end
  fn()
  UIM.show = real_show
  return shown
end
local function tap(p, text)
  -- the row with exactly this text, else the first that starts with it ("Owned (1)")
  for _, row in ipairs(p.rows) do
    if row.text == text then row.callback(); return row end
  end
  for _, row in ipairs(p.rows) do
    if row.text:sub(1, #text) == text then row.callback(); return row end
  end
  error("no row " .. text)
end
local function hasRow(p, text)
  for _, row in ipairs(p.rows) do
    if row.text:find(text, 1, true) then return true end
  end
  return false
end
local function lastInfo() return infos[#infos] or "" end
local function countOf(m, status_id) return m.shelf_cache:counts(1, { status_id })[status_id] end

local NEW = function() return { book = { book_id = 100, title = "Book 100", edition_id = 10001 } } end
local SHELVED = function() return { book = { book_id = 1, title = "Book 1" }, status_id = 1, user_book_id = 51, user_rating = 4 } end

-- ============================================================ shelves
print("\n== a shelf, offline ==")

check("a book new to the library goes on a shelf offline: kept, shown, nothing requested", function()
  local m = newManager()
  online = false
  local d = detailScreen(m, NEW())
  local p = showing(function() m:chooseShelf(d) end)
  assert(p, "no picker offline")
  assert(not hasRow(p, "Remove from library"), "a book not in the library offered Remove")
  tap(p, "Read")
  assert(#calls == 0, "requested offline")
  local op = shelf_queue:get(100)
  assert(op and op.kind == "status" and op.status_id == 3 and op.edition_id == 10001, "not queued")
  assert(#d.status_updates == 1 and d.status_updates[1][1] == 3, "the screen did not change")
  assert(lastInfo():find("Offline"), "no visible acknowledgement: " .. lastInfo())
  local member = shelves:member(1, 100)
  assert(member and member.status_id == 3, "the saved shelf does not hold it")
  assert(shelves:meta(1, 3).fingerprint == "fp3", "the saved shelf was marked out of date")
  assert(countOf(m, 3) == 2, "Home's count did not follow: " .. tostring(countOf(m, 3)))
end)

check("a book moved between shelves offline: both counts follow, the rating stays", function()
  local m = newManager()
  online = false
  local d = detailScreen(m, SHELVED())
  tap(showing(function() m:chooseShelf(d) end), "Currently Reading")
  local op = shelf_queue:get(1)
  assert(op.status_id == 2 and op.user_book_id == 51 and op.from_status_id == 1)
  assert(countOf(m, 1) == 0 and countOf(m, 2) == 1, "counts: " .. tostring(countOf(m, 1)) .. "/" .. tostring(countOf(m, 2)))
  assert(shelves:member(1, 1).status_id == 2 and shelves:member(1, 1).rating == 4)
end)

check("removing from the library offline keeps a removal, and the screen goes back to 'not in your library'", function()
  local m = newManager()
  online = false
  local d = detailScreen(m, SHELVED())
  tap(showing(function() m:chooseShelf(d) end), "Remove from library")
  confirms[1].ok_callback()
  assert(#calls == 0)
  local op = shelf_queue:get(1)
  assert(op.kind == "remove" and op.user_book_id == 51 and op.from_status_id == 1)
  assert(d.detail.status_id == nil and shelves:member(1, 1) == nil)
  assert(countOf(m, 1) == 0)
end)

check("a book put on a shelf offline can be taken off again: nothing is left to send", function()
  local m = newManager()
  online = false
  local d = detailScreen(m, NEW())
  tap(showing(function() m:chooseShelf(d) end), "Want to Read")
  local p = showing(function() m:chooseShelf(d) end)
  assert(hasRow(p, "Remove from library"), "no way to take it off again")
  tap(p, "Remove from library")
  confirms[1].ok_callback()
  assert(shelf_queue:count() == 0 and shelves:member(1, 100) == nil)
  assert(countOf(m, 1) == 1, "the count did not come back: " .. tostring(countOf(m, 1)))
end)

check("with the connection back but the shelf change unsent, taking the book off sends nothing", function()
  local m = newManager()
  online = false
  local d = detailScreen(m, NEW())
  tap(showing(function() m:chooseShelf(d) end), "Want to Read")
  online = true
  local p = showing(function() m:chooseShelf(d) end)
  tap(p, "Remove from library")
  confirms[1].ok_callback()
  assert(#calls == 0, "asked Hardcover to remove a book it never had")
  assert(shelf_queue:count() == 0 and d.detail.status_id == nil)
  assert(lastInfo():find("nothing is left to send"), lastInfo())
end)

check("a book opened with an edition has no saved row: it gets one, so the shelf shows it", function()
  local m = newManager()
  online = false
  local d = detailScreen(m, { book = { book_id = 555, title = "Edition only", edition_id = 9 } })
  assert(#books:missing({ 555 }) == 1, "the fixture already had a row")
  tap(showing(function() m:chooseShelf(d) end), "Read")
  local entries = shelves:entries(1, 3)
  local found
  for _, e in ipairs(entries) do if e.book_id == 555 then found = e end end
  assert(found and found.title == "Edition only", "the book is missing from the shelf")
  assert(found.user_book_id == nil and found.status_id == 3)
end)

check("opening the book again offline shows what is waiting", function()
  local m = newManager()
  shelf_queue:queueStatus(1, 1, 3, { user_book_id = 51 })
  local d = m:withPending({ book = { book_id = 1 }, status_id = 1, user_book_id = 51 })
  assert(d.status_id == 3)
  shelf_queue:queueRemove(1, 1, 51, nil, 1)
  d = m:withPending({ book = { book_id = 1 }, status_id = 1, user_book_id = 51, user_rating = 4 })
  assert(d.status_id == nil and d.user_rating == nil)
end)

check("Hardcover's older word about the book does not overwrite a waiting change", function()
  local m = newManager()
  local d = detailScreen(m, { book = { book_id = 1 }, status_id = 3, user_book_id = 51 })
  shelf_queue:queueStatus(1, 1, 3, { user_book_id = 51, from_status_id = 1 })
  m:applyAbout(d, 1, { user_book = { id = 51, status_id = 1 } })
  assert(#d.status_updates == 0 and d.detail.status_id == 3, "overwritten")
  shelf_queue:cancel(1)
  m:applyAbout(d, 1, { user_book = { id = 51, status_id = 1 } })
  assert(#d.status_updates == 1, "not applied without a waiting change")
end)

check("rating a book before its first shelf sync is kept, restored and sent after the shelf", function()
  local m = newManager()
  online = false
  local d = detailScreen(m, NEW())
  tap(showing(function() m:chooseShelf(d) end), "Currently Reading")
  assert(d.detail.user_book_id == nil)
  local stepper = real_require("hardcover/lib/ui/components/stepper_dialog")
  local show, form = stepper.show
  stepper.show = function(opts) form = opts end
  m:rateBook(d)
  stepper.show = show
  assert(form, "rating is still blocked before the shelf sync")
  form.on_save(4.5)
  assert(rating_queue:get(nil, 100) == 4.5 and rating_queue:count() == 1)
  assert(m:withPending(NEW()).user_rating == 4.5, "reopening lost the pending rating")
  assert(#calls == 0 and #server_calls == 0, "requested while offline")

  local api, record = serverApi(), nil
  function api:findUserBook(book_id, user_id)
    assert(book_id == 100 and user_id == 1)
    return record
  end
  function api:updateRating(id, rating)
    assert(record and id == record.id and rating == 4.5, "rating sent before its record existed")
    return { id = id, book_id = 100, rating = rating }
  end
  assert(rating_queue:flush(api, nil, 1) == 1, "rating must wait for the shelf")
  online = true
  local result = shelf_queue:flush(api, { user_id = 1, on_sent = function(op, ub)
    record = ub
    m:shelfSent(op, ub)
  end })
  assert(result.sent == 1)
  assert(rating_queue:flush(api, nil, 1) == 0, "rating did not follow the shelf")
end)

print("\n== a shelf, when the connection is back ==")

check("the change is sent once, the shelves are marked out of date, the open screen gets the record", function()
  local m = newManager()
  online = false
  local d = detailScreen(m, NEW())
  tap(showing(function() m:chooseShelf(d) end), "Read")
  online = true
  local sent
  local res = shelf_queue:flush(serverApi(), { user_id = 1, on_sent = function(op, ub) sent = true; m:shelfSent(op, ub) end })
  assert(res.sent == 1 and #server_calls == 2, "sent " .. #server_calls)
  assert(server_calls[1].book_id == 100 and server_calls[1].status_id == 3 and server_calls[1].edition_id == 10001)
  -- finished: the day it was made goes along, so a later sync does not become the finish date
  assert(server_calls[2].name == "setFinishedDate" and server_calls[2].date == os.date("%Y-%m-%d"))
  assert(shelf_queue:count() == 0)
  assert(shelves:meta(1, 3).fingerprint == nil, "the shelf was not marked out of date")
  local last = d.status_updates[#d.status_updates]
  assert(last[1] == 3 and last[2] == 800, "the screen did not get the record: " .. tostring(last[2]))
  shelf_queue:flush(serverApi(), { user_id = 1 })
  assert(#server_calls == 2, "sent twice")
end)

check("a move is marked stale on the shelf it left too", function()
  local m = newManager()
  online = false
  local d = detailScreen(m, SHELVED())
  tap(showing(function() m:chooseShelf(d) end), "Read")
  online = true
  shelf_queue:flush(serverApi(), { user_id = 1, on_sent = function(op, ub) m:shelfSent(op, ub) end })
  assert(shelves:meta(1, 1).fingerprint == nil and shelves:meta(1, 3).fingerprint == nil)
end)

check("a removal is sent by the record, and the shelf it left is marked", function()
  local m = newManager()
  online = false
  local d = detailScreen(m, SHELVED())
  tap(showing(function() m:chooseShelf(d) end), "Remove from library")
  confirms[1].ok_callback()
  online = true
  shelf_queue:flush(serverApi(), { user_id = 1, on_sent = function(op, ub) m:shelfSent(op, ub) end })
  assert(server_calls[1].name == "removeUserBook" and server_calls[1].id == 51)
  assert(shelves:meta(1, 1).fingerprint == nil)
end)

check("changing the shelf online while a change is waiting sends the new one and drops the old", function()
  local m = newManager()
  shelf_queue:queueStatus(1, 1, 3, { user_book_id = 51, from_status_id = 1 })
  local d = detailScreen(m, SHELVED())
  tap(showing(function() m:chooseShelf(d) end), "Currently Reading")
  assert(count("updateUserBook") == 1)
  update_cb({ id = 51, status_id = 2 })
  assert(shelf_queue:count() == 0, "the older change is still waiting, and would undo this one")
end)

check("cancelling a waiting shelf change puts the screen, shelf and counts back", function()
  local m = newManager()
  online = false
  local d = detailScreen(m, SHELVED())
  tap(showing(function() m:chooseShelf(d) end), "Read")
  local rows = PendingChanges.list({ shelf_queue = shelf_queue })
  assert(#rows == 1 and rows[1].kind == "shelf" and rows[1].text:find("Book 1: move to Read", 1, true), rows[1] and rows[1].text)
  rows[1].cancel()
  m:pendingUndone(rows[1])
  assert(shelf_queue:count() == 0)
  assert(d.detail.status_id == 1 and shelves:member(1, 1).status_id == 1)
  assert(countOf(m, 1) == 1 and countOf(m, 3) == 1, "counts: " .. tostring(countOf(m, 1)) .. "/" .. tostring(countOf(m, 3)))
  assert(shelves:meta(1, 1).fingerprint == nil, "not asked about again when online")
end)

-- ============================================================ lists
local function saveLists(m, specs)
  local mine = {}
  for _, s in ipairs(specs) do
    local row = { id = s.id, source = "mine", name = s.name, count = #(s.books or {}), ranked = s.ranked or false,
                  updated_at = T1, covers = {} }
    row.fingerprint = Lists.fingerprint(row)
    mine[#mine + 1] = row
  end
  list_store:putIndex(1, { mine = mine, following = {} })
  for i, s in ipairs(specs) do
    if s.books then
      local entries = {}
      for pos, id in ipairs(s.books) do
        entries[#entries + 1] = { book_id = id, title = "Book " .. id, list_book_id = 3000 + id, position = pos - 1 }
      end
      list_store:putEntries(1, mine[i], entries, s.complete ~= false)
    end
  end
end

local function offlineLists(m, book_id)
  -- the book was opened while online, which keeps its row (an unheld row is evicted)
  books:saveDetail(book_id, nil, { book = bookRow(book_id) })
  online = false
  local d = detailScreen(m, { book = { book_id = book_id, title = "Book " .. book_id } })
  local p = showing(function() m:chooseLists(d) end)
  return d, p
end

print("\n== lists, offline ==")

check("the picker is built from the saved lists, with the lists that cannot be known left out", function()
  local m = newManager()
  saveLists(m, {
    { id = 5, name = "Favourites", ranked = true, books = { 1, 3 } },
    { id = 6, name = "Owned", books = { 100 } },
    { id = 7, name = "Partial", books = { 1 }, complete = false },
  })
  local d, p = offlineLists(m, 100)
  assert(p, "no picker offline: " .. lastInfo())
  assert(#calls == 0)
  assert(#d.detail.lists == 2, "rows: " .. #d.detail.lists)
  assert(hasRow(p, "Favourites (2)") and hasRow(p, "Owned (1)") and not hasRow(p, "Partial"))
  assert(d.detail.lists[1].on == false and d.detail.lists[2].on == true)
  local noted
  for _, i in ipairs(infos) do if i:find("not saved on this device") then noted = true end end
  assert(noted, "no note about the left out list")
end)

check("with no list saved the picker says so instead of offering nothing", function()
  local m = newManager()
  local d, p = offlineLists(m, 100)
  assert(p == nil and #calls == 0 and lastInfo():find("not saved on this device yet"), lastInfo())
end)

check("ticking a list offline keeps the add, patches the saved list and its size, asks nothing", function()
  local m = newManager()
  saveLists(m, { { id = 5, name = "Favourites", ranked = true, books = { 1, 3 } } })
  local before = list_store:contents(1, 5)
  local d, p = offlineLists(m, 100)
  local row = tap(p, "Favourites")
  assert(list_queue:count() == 0 and #infos == 0, "kept or said something before Done")
  tap(p, "Done")
  assert(#calls == 0, "requested offline")
  local op = list_queue:get(5, 100)
  assert(op and op.kind == "add" and op.position == 2, "not queued")
  assert(row.checked == true, "picker row not ticked")
  assert(list_store:memberOf(1, 5, 100), "the saved list does not hold it")
  local index_row = list_store:index(1).mine[1]
  assert(index_row.count == 3, "index count " .. tostring(index_row.count))
  assert(list_store:contents(1, 5).fingerprint == before.fingerprint, "the saved list was marked out of date")
  assert(list_store:index(1).checked_at ~= nil, "the index was marked out of date")
  assert(lastInfo():find("Offline"), lastInfo())
  local entries = list_store:entries(1, index_row)
  local e = entries[#entries]
  assert(e.book_id == 100 and e.rank == 3, "not last on a ranked list: n=" .. #entries .. " book=" .. tostring(e and e.book_id) .. " rank=" .. tostring(e and e.rank) .. " ranked=" .. tostring(index_row.ranked))
end)

check("a patched list is not mistaken for out of date when Hardcover has not changed", function()
  local m = newManager()
  saveLists(m, { { id = 5, name = "Favourites", books = { 1, 3 } } })
  local d, p = offlineLists(m, 100)
  tap(p, "Favourites"); tap(p, "Done")
  local index = list_store:index(1)
  local row = index.mine[1]
  assert(row.count == 3)
  assert(not ListsSync.needsDownload(row, list_store:contents(1, 5)), "would download over the change")
  local marks = { { id = 5, source = "mine", fingerprint = T1 .. "|2" } }
  assert(not ListsSync.indexChanged(index, marks), "would fetch the index over the change")
end)

check("unticking offline keeps the remove by its row, and a tick then untick cancels out", function()
  local m = newManager()
  saveLists(m, { { id = 6, name = "Owned", books = { 100, 101 } }, { id = 5, name = "Favourites", books = { 1 } } })
  local d, p = offlineLists(m, 100)
  tap(p, "Owned"); tap(p, "Done")
  local op = list_queue:get(6, 100)
  assert(op.kind == "remove" and op.list_book_id == 3100, "remove: " .. tostring(op and op.list_book_id))
  assert(list_store:memberOf(1, 6, 100) == false and list_store:index(1).mine[1].count == 1)
  p = showing(function() m:chooseLists(d) end)
  tap(p, "Favourites"); tap(p, "Done")
  assert(list_queue:get(5, 100) and list_queue:count() == 2)
  p = showing(function() m:chooseLists(d) end)
  tap(p, "Favourites"); tap(p, "Done")
  assert(list_queue:get(5, 100) == nil and list_queue:count() == 1, "an add and a remove did not cancel")
  assert(list_store:index(1).mine[2].count == 1)
end)

check("reopening the picker offline shows the book as on the list it was put on", function()
  local m = newManager()
  saveLists(m, { { id = 5, name = "Favourites", books = { 1 } } })
  local d, p = offlineLists(m, 100)
  tap(p, "Favourites"); tap(p, "Done")
  local d2 = detailScreen(m, { book = { book_id = 100, title = "Book 100" } })
  local p2 = showing(function() m:chooseLists(d2) end)
  assert(d2.detail.lists[1].on == true and d2.detail.lists[1].count == 2)
end)

print("\n== lists, when the connection is back ==")

check("each change is sent once, and the saved list is then marked out of date", function()
  local m = newManager()
  saveLists(m, { { id = 5, name = "Favourites", books = { 1 } }, { id = 6, name = "Owned", books = { 100 } } })
  local d, p = offlineLists(m, 100)
  tap(p, "Favourites"); tap(p, "Owned"); tap(p, "Done")
  online = true
  local res = list_queue:flush(serverApi(), { user_id = 1, on_sent = function(op, a) m:listChangeSent(op, a) end })
  assert(res.sent == 2 and #server_calls == 2)
  assert(server_calls[1].name == "addToList" and server_calls[1].list_id == 5 and server_calls[1].book_id == 100)
  assert(server_calls[2].name == "removeFromList" and server_calls[2].id == 3100)
  assert(list_store:contents(1, 5).fingerprint == nil and list_store:contents(1, 6).fingerprint == nil)
  assert(list_store:index(1).checked_at == nil, "the index will not be asked about again")
  list_queue:flush(serverApi(), { user_id = 1 })
  assert(#server_calls == 2, "sent twice")
end)

check("unticking online a list the book was put on offline just cancels it: Hardcover never had it", function()
  local m = newManager()
  saveLists(m, { { id = 5, name = "Favourites", books = { 1 } } })
  local d, p = offlineLists(m, 100)
  tap(p, "Favourites"); tap(p, "Done") -- waits: an add
  online = true
  p = showing(function() m:chooseLists(d) end)
  tap(p, "Favourites"); tap(p, "Done")
  assert(list_queue:count() == 0, "the add is still waiting")
  assert(#calls == 0, "asked Hardcover to remove a book it never had")
  assert(list_store:memberOf(1, 5, 100) == false and list_store:index(1).mine[1].count == 1)
end)

check("ticking online sends the change, and a different list's waiting change stays", function()
  local m = newManager()
  saveLists(m, { { id = 5, name = "Favourites", books = { 1 } }, { id = 6, name = "Owned", books = { 3 } } })
  local d, p = offlineLists(m, 100)
  tap(p, "Favourites"); tap(p, "Done")
  online = true
  p = showing(function() m:chooseLists(d) end)
  tap(p, "Owned"); tap(p, "Done")
  assert(count("addToList") == 1 and calls[1].list_id == 6)
  assert(list_queue:get(5, 100), "an unrelated waiting change was dropped")
end)

check("the online picker shows the changes still waiting over Hardcover's older answer", function()
  local m = newManager()
  list_queue:queueAdd(1, 100, 5, 1, {})
  list_queue:queueRemove(1, 100, 6, 3100, {})
  local rows = m:withPendingLists({
    { id = 5, count = 1, on = false }, { id = 6, count = 2, on = true, list_book_id = 3100 }, { id = 7, count = 1, on = false },
  }, 100)
  assert(rows[1].on == true and rows[1].count == 2 and rows[2].on == false and rows[3].on == false)
end)

check("cancelling a waiting list change puts the saved list and its size back", function()
  local m = newManager()
  saveLists(m, { { id = 5, name = "Favourites", books = { 1, 3 } } })
  local d, p = offlineLists(m, 100)
  tap(p, "Favourites"); tap(p, "Done")
  local rows = PendingChanges.list({ list_queue = list_queue })
  assert(#rows == 1 and rows[1].kind == "list" and rows[1].text:find("put on the list \"Favourites\"", 1, true), rows[1] and rows[1].text)
  rows[1].cancel()
  m:pendingUndone(rows[1])
  assert(list_queue:count() == 0)
  assert(list_store:memberOf(1, 5, 100) == false and list_store:index(1).mine[1].count == 2)
end)

print("\n== waiting changes ==")

check("held changes say why in the pending list", function()
  local m = newManager()
  shelf_queue:queueStatus(1, 1, 3, { title = "Book 1" })
  list_queue:queueAdd(1, 100, 5, 0, { title = "Book 100", list_name = "Favourites" })
  shelf_queue:get(1).held, shelf_queue:get(1).reason = true, "scope"
  list_queue:get(5, 100).held, list_queue:get(5, 100).reason = true, "refused"
  local rows = PendingChanges.list({ shelf_queue = shelf_queue, list_queue = list_queue })
  assert(#rows == 2)
  assert(PendingChanges.line(rows[1]):find("sign in again to send it", 1, true), PendingChanges.line(rows[1]))
  assert(PendingChanges.line(rows[2]):find("Hardcover refused it", 1, true), PendingChanges.line(rows[2]))
end)

r.finish()
