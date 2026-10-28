-- Offline-sync behaviours that were probed while hunting bugs and turned out to be
-- correct. They are kept so a later change cannot quietly break them.
--
--   * the same book queued twice is replayed once, with the latest page;
--   * a replay is idempotent: flushing again sends nothing;
--   * a status and a page for one book go out status first, one read is created;
--   * a status that was sent is not sent again when the page behind it failed;
--   * a failure (or a throw) in the middle of a replay keeps the unsent entries
--     and the sent ones are cleared;
--   * Cache.syncPage / Cache.updateBookStatus queue when offline or when the
--     request fails, report `{ queued = true }`, and clear only what they sent.
--
-- Run with:  lua spec/sync_bugs_queue_behaviour_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local KB = dofile(PLUGIN .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local Api = require("hardcover/lib/hardcover_api")
local Cache = require("hardcover/lib/cache")
local SyncQueue = require("hardcover/lib/sync_queue")
local User = require("hardcover/lib/user")

local r = KB.support.reporter()
local check = r.test
local function eq(a, b, label)
  if a ~= b then error((label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local function reading(book_id, read_page)
  return { id = 500 + book_id, book_id = book_id, status_id = HARDCOVER.STATUS.READING,
    user_book_reads = { { id = 900 + book_id, progress_pages = read_page or 1, edition_id = 3 } } }
end

print("\n== replay ==")

check("the same book queued twice is sent once, with the latest page", function()
  local q = KB.newQueue()
  q:enqueuePage("/b/a.epub", { mapped_page = 10, book_id = 1, edition_id = 3 })
  q:enqueuePage("/b/a.epub", { mapped_page = 40, book_id = 1, edition_id = 3 })
  local api = KB.fakeApi { [1] = reading(1) }
  q:flush(api, { user_id = 1 })
  eq(api:count("updatePage"), 1, "page sends")
  eq(api.shelf[1].user_book_reads[1].progress_pages, 40, "page")
end)

check("flushing twice sends nothing the second time", function()
  local q = KB.newQueue()
  q:enqueuePage("/b/a.epub", { mapped_page = 10, book_id = 1, edition_id = 3 })
  local api = KB.fakeApi { [1] = reading(1) }
  q:flush(api, { user_id = 1 })
  local before = #api.calls
  eq(q:flush(api, { user_id = 1 }), true, "second flush")
  eq(#api.calls, before, "api calls on the second flush")
end)

check("status + page for a book not yet on the shelf: one insert, one read", function()
  local q = KB.newQueue()
  q:enqueueStatus("/b/a.epub", { status_id = HARDCOVER.STATUS.READING, book_id = 1, edition_id = 3 })
  q:enqueuePage("/b/a.epub", { mapped_page = 10, book_id = 1, edition_id = 3 })
  local api = KB.fakeApi()
  q:flush(api, { user_id = 1 })
  eq(api:count("updateUserBook"), 1, "inserts")
  eq(api:count("createRead"), 1, "created reads")
  eq(#api.shelf[1].user_book_reads, 1, "reads on the server")
  eq(q:hasPending(), false, "queue drained")
end)

check("a status already sent is not sent again when the page behind it failed", function()
  local q = KB.newQueue()
  q:enqueueStatus("/b/a.epub", { status_id = HARDCOVER.STATUS.READING, book_id = 1, edition_id = 3 })
  q:enqueuePage("/b/a.epub", { mapped_page = 10, book_id = 1, edition_id = 3 })
  local api = KB.fakeApi { [1] = reading(1) }
  local fail = true
  api.page_hook = function(read_id, page)
    if fail then return nil end
    api.shelf[1].user_book_reads[1].progress_pages = page
    return api.shelf[1]
  end
  q:flush(api, { user_id = 1 })
  eq(q:get("/b/a.epub").status_id, nil, "status kept in the entry after it was sent")
  eq(q:get("/b/a.epub").mapped_page, 10, "page kept for the retry")
  fail = false
  q:flush(api, { user_id = 1 })
  eq(api:count("updateUserBookStatus"), 1, "status sends over both flushes")
  eq(q:hasPending(), false, "queue drained")
end)

check("a failure and a throw mid-replay keep only the unsent entries", function()
  local q = KB.newQueue()
  q:enqueuePage("/b/1.epub", { mapped_page = 1, book_id = 1, edition_id = 3 })
  q:enqueuePage("/b/2.epub", { mapped_page = 2, book_id = 2, edition_id = 3 })
  q:enqueuePage("/b/3.epub", { mapped_page = 3, book_id = 3, edition_id = 3 })
  local api = KB.fakeApi { [1] = reading(1), [2] = reading(2), [3] = reading(3) }
  api.page_hook = function(read_id, page)
    if page == 2 then error("socket closed") end
    local ub = api.shelf[read_id - 900]
    ub.user_book_reads[1].progress_pages = page
    return ub
  end
  eq(q:flush(api, { user_id = 1 }), false, "flush result")
  eq(q:hasPending("/b/1.epub"), false, "first entry sent")
  eq(q:hasPending("/b/2.epub"), true, "second entry kept")
  eq(q:hasPending("/b/3.epub"), false, "third entry still attempted and sent")
  eq(q.flushing, false, "flushing flag released")
end)

print("\n== Cache queueing ==")

local function newCache(queue, state)
  local settings = {
    getFilePath = function() return "/b/a.epub" end,
    readBookSetting = function(_, _, key) return ({ book_id = 7, edition_id = 3 })[key] end,
    readBookSettings = function() return { book_id = 7, edition_id = 3 } end,
    saveBookSnapshot = function() end,
  }
  return Cache:new { settings = settings, sync_queue = queue, state = state or { book_status = reading(7, 10) } }
end

check("offline: syncPage queues and reports { queued = true }", function()
  KB.network.connected = false
  local q = KB.newQueue()
  local result = newCache(q):syncPage("/b/a.epub", 50)
  KB.network.connected = true
  eq(result.queued, true, "queued flag")
  eq(q:get("/b/a.epub").mapped_page, 50, "queued page")
  eq(q:get("/b/a.epub").book_id, 7, "queued book")
end)

check("online but the request fails: syncPage queues instead of losing the page", function()
  local q = KB.newQueue()
  Api.updatePage = function() return nil end
  local result = newCache(q):syncPage("/b/a.epub", 50)
  eq(result.queued, true, "queued flag")
  eq(q:get("/b/a.epub").mapped_page, 50, "queued page")
end)

check("online success clears the queued page but keeps a queued status", function()
  local q = KB.newQueue()
  q:enqueuePage("/b/a.epub", { mapped_page = 20, book_id = 7 })
  q:enqueueStatus("/b/a.epub", { status_id = HARDCOVER.STATUS.READING, book_id = 7 })
  Api.updatePage = function() return reading(7, 50) end
  local result = newCache(q):syncPage("/b/a.epub", 50)
  eq(result.id, 507, "result is the user book")
  eq(q:get("/b/a.epub").mapped_page, nil, "page")
  eq(q:get("/b/a.epub").status_id, HARDCOVER.STATUS.READING, "status")
end)

check("online status change updates the existing user book by its record id", function()
  local old_update_status, old_insert = Api.updateUserBookStatus, Api.updateUserBook
  local called
  Api.updateUserBookStatus = function(_, user_book_id, status_id)
    called = { user_book_id, status_id }
    return { id = user_book_id, book_id = 7, status_id = status_id, user_book_reads = {} }
  end
  Api.updateUserBook = function() error("insert used for an existing user book") end

  local ok, err = pcall(function()
    local state = { book_status = { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.TO_READ } }
    local result = newCache(KB.newQueue(), state):updateBookStatus("/b/a.epub", HARDCOVER.STATUS.READING)
    eq(called[1], 507, "user book id")
    eq(called[2], HARDCOVER.STATUS.READING, "new status")
    eq(result.status_id, HARDCOVER.STATUS.READING, "saved status")
  end)

  Api.updateUserBookStatus, Api.updateUserBook = old_update_status, old_insert
  assert(ok, err)
end)

check("online status change finds an existing user book when its id is not cached", function()
  local old_find, old_update_status = Api.findUserBook, Api.updateUserBookStatus
  local old_insert, old_user_id = Api.updateUserBook, User.getId
  local calls = {}
  Api.findUserBook = function(_, book_id, user_id)
    calls.find = { book_id, user_id }
    return { id = 507, book_id = book_id, status_id = HARDCOVER.STATUS.TO_READ, user_book_reads = {} }
  end
  Api.updateUserBookStatus = function(_, user_book_id, status_id)
    calls.update = { user_book_id, status_id }
    return { id = user_book_id, book_id = 7, status_id = status_id, user_book_reads = {} }
  end
  Api.updateUserBook = function() error("insert used for an existing user book") end
  User.getId = function() return 42 end

  local ok, err = pcall(function()
    local state = { book_status = { book_id = 7, status_id = HARDCOVER.STATUS.TO_READ } }
    local result = newCache(KB.newQueue(), state):updateBookStatus("/b/a.epub", HARDCOVER.STATUS.READING)
    eq(calls.find[1], 7, "looked-up book id")
    eq(calls.find[2], 42, "looked-up user id")
    eq(calls.update[1], 507, "updated user book id")
    eq(calls.update[2], HARDCOVER.STATUS.READING, "new status")
    eq(result.status_id, HARDCOVER.STATUS.READING, "saved status")
  end)

  Api.findUserBook, Api.updateUserBookStatus = old_find, old_update_status
  Api.updateUserBook, User.getId = old_insert, old_user_id
  assert(ok, err)
end)

check("online status change queues rather than inserting when shelf lookup fails", function()
  local old_find, old_update_status = Api.findUserBook, Api.updateUserBookStatus
  local old_insert, old_user_id = Api.updateUserBook, User.getId
  Api.findUserBook = function() return {}, { error = "network" } end
  Api.updateUserBookStatus = function() error("cannot update without a known record id") end
  Api.updateUserBook = function() error("cannot insert when the lookup is uncertain") end
  User.getId = function() return 42 end

  local ok, err = pcall(function()
    local queue = KB.newQueue()
    local state = { book_status = { book_id = 7, status_id = HARDCOVER.STATUS.TO_READ } }
    local result = newCache(queue, state):updateBookStatus("/b/a.epub", HARDCOVER.STATUS.READING)
    eq(result.queued, true, "queued result")
    eq(queue:get("/b/a.epub").status_id, HARDCOVER.STATUS.READING, "queued status")
  end)

  Api.findUserBook, Api.updateUserBookStatus = old_find, old_update_status
  Api.updateUserBook, User.getId = old_insert, old_user_id
  assert(ok, err)
end)

check("offline status change is queued; online success clears only the status", function()
  KB.network.connected = false
  local q = KB.newQueue()
  local cache = newCache(q)
  local result = cache:updateBookStatus("/b/a.epub", HARDCOVER.STATUS.FINISHED)
  KB.network.connected = true
  eq(result.queued, true, "queued flag")
  eq(q:get("/b/a.epub").status_id, HARDCOVER.STATUS.FINISHED, "queued status")
  q:enqueuePage("/b/a.epub", { mapped_page = 20, book_id = 7 })
  Api.updateUserBookStatus = function(_, user_book_id, status_id)
    return { id = user_book_id, status_id = status_id, user_book_reads = {} }
  end
  cache:updateBookStatus("/b/a.epub", HARDCOVER.STATUS.FINISHED)
  eq(q:get("/b/a.epub").status_id, nil, "status after the online send")
  eq(q:get("/b/a.epub").mapped_page, 20, "page untouched")
end)

r.finish()
