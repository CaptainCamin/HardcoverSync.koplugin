-- Proves the offline queue behaves correctly.
--
-- This queue is the whole of feature 1. If it loses a page, double-sends a
-- status, or replays a refresh, the user's reading history is wrong on
-- Hardcover and they have no way to tell. It is also the part with no
-- observable behaviour on the device until something goes wrong, so it is
-- worth pinning hard here.
--
-- Run with:  lua spec/sync_queue_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local HARDCOVER_ROOT = PLUGIN
package.path = HARDCOVER_ROOT .. "/?.lua;" .. HARDCOVER_ROOT .. "/?/init.lua;" .. package.path

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SyncQueue = require("hardcover/lib/sync_queue")

-- Referencing a constant that does not exist yields nil, and a comparison
-- against nil fails in a way that looks like a plugin bug rather than a typo in
-- the test. This bit STATUS.READ (the real name is FINISHED) and quietly
-- neutered five assertions. Fail loudly at load time instead.
for _, name in ipairs({ "TO_READ", "READING", "FINISHED", "DNF" }) do
  if HARDCOVER.STATUS[name] == nil then
    error("HARDCOVER.STATUS." .. name .. " does not exist -- fix the harness, not the plugin")
  end
end

local results = { passed = 0, failed = 0 }

local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    results.passed = results.passed + 1
    print("  [ok  ] " .. name)
  else
    results.failed = results.failed + 1
    print("  [FAIL] " .. name .. "\n         " .. tostring(err))
  end
end

local function eq(a, b, label)
  if a ~= b then
    error((label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
  end
end

-- A settings double backed by a plain table, mirroring the LuaSettings surface
-- SyncQueue actually uses. Backed by a real table rather than a no-op so a test
-- can prove the queue persisted, not merely that it did not crash.
--
-- readSetting returns the LIVE table by reference, which is what KOReader's
-- LuaSettings does. Returning a copy here is a trap: SyncQueue:pending() hands
-- the table back to callers who then mutate entries in place, so a copy means
-- every mutation is silently discarded and the queue appears to lose entries.
-- Real LuaSettings:readSetting is `return self.data[key]`.
local function fakeSettings()
  local store = {}
  return {
    store = store,
    readSetting = function(_, key)
      local v = store[key]
      if v == nil then return nil end
      return v
    end,
    saveSetting = function(_, key, value) store[key] = value return true end,
    flush = function() return true end,
  }
end

local function newQueue()
  local settings = fakeSettings()
  return SyncQueue:new { settings = settings }, settings
end

-- ---------------------------------------------------------------- enqueueing

print("\n== enqueueing ==")

check("a page update is queued", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 42, book_id = 7, edition_id = 3 })
  local entry = q:get("/books/a.epub")
  eq(entry.mapped_page, 42, "mapped_page")
  eq(entry.book_id, 7, "book_id")
end)

check("a status change is queued", function()
  local q = newQueue()
  q:enqueueStatus("/books/b.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 8 })
  eq(q:get("/books/b.epub").status_id, HARDCOVER.STATUS.FINISHED, "status_id")
end)

check("repeated page turns coalesce into one entry", function()
  -- Otherwise every page turn during a long offline session would enqueue a
  -- separate flush, and the queue would grow without bound.
  local q = newQueue()
  for page = 10, 60, 10 do
    q:enqueuePage("/books/a.epub", { mapped_page = page, book_id = 7 })
  end
  eq(q:pendingCount(), 1, "pending file count")
  eq(q:get("/books/a.epub").mapped_page, 60, "latest page wins")
end)

check("different books queue separately", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 10, book_id = 1 })
  q:enqueuePage("/books/b.epub", { mapped_page = 20, book_id = 2 })
  eq(q:pendingCount(), 2, "pending file count")
end)

check("a page and a status for one book share an entry", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 10, book_id = 1 })
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.READING })
  eq(q:pendingCount(), 1, "pending file count")
  eq(q:changeCount(), 2, "pending change count")
  local e = q:get("/books/a.epub")
  eq(e.mapped_page, 10, "page survives")
  eq(e.status_id, HARDCOVER.STATUS.READING, "status recorded")
end)

-- ---------------------------------------------------------------- emptiness

print("\n== what counts as pending ==")

check("an entry with neither page nor status is empty", function()
  local q = newQueue()
  q:save("/books/a.epub", { book_id = 1 })
  eq(q:isEmpty(q:get("/books/a.epub")), true, "isEmpty")
  eq(q:hasPending(), false, "hasPending")
end)

check("page zero is real progress, not emptiness", function()
  -- A falsy check here would silently drop the very first page of a book.
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 0, book_id = 1 })
  eq(q:hasPending(), true, "hasPending")
  eq(q:pendingCount(), 1, "pendingCount")
end)

check("hasPending can be asked about one file", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 5, book_id = 1 })
  eq(q:hasPending("/books/a.epub"), true, "the queued file")
  eq(q:hasPending("/books/other.epub"), false, "an untouched file")
end)

check("get on no file is nil rather than an error", function()
  local q = newQueue()
  eq(q:get("/nope.epub"), nil, "get")
  eq(q:get(nil), nil, "get(nil)")
end)

-- ---------------------------------------------------------------- when to sync a page

print("\n== shouldFlushPage ==")

check("a page with no status flushes", function()
  -- Progress is only meaningful once the book is on the shelf, and a page with
  -- no status at all is the offline-first case.
  local q = newQueue()
  eq(q:shouldFlushPage({ mapped_page = 10 }), true, "no status")
end)

check("a page on a currently-reading book flushes", function()
  local q = newQueue()
  eq(q:shouldFlushPage({ mapped_page = 10, status_id = HARDCOVER.STATUS.READING }), true, "reading")
end)

check("a page on a finished book does not flush", function()
  -- Syncing progress onto a book the user marked Read would drag the shelf
  -- status backwards.
  local q = newQueue()
  eq(q:shouldFlushPage({ mapped_page = 10, status_id = HARDCOVER.STATUS.FINISHED }), false, "read")
end)

check("a page on a want-to-read book does not flush", function()
  local q = newQueue()
  eq(q:shouldFlushPage({ mapped_page = 10, status_id = HARDCOVER.STATUS.TO_READ }), false, "want to read")
end)

check("no page means nothing to flush", function()
  local q = newQueue()
  eq(q:shouldFlushPage({}), false, "empty entry")
  eq(q:shouldFlushPage(nil), false, "nil entry")
end)

-- ---------------------------------------------------------------- applying locally

print("\n== applying a pending entry over server state ==")

check("a queued page updates the latest read", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 99, book_id = 1, edition_id = 3 })
  local status = { user_book_reads = { { id = 55, progress_pages = 10, edition_id = 3 } } }
  local out = q:applyPending("/books/a.epub", status)
  eq(out.user_book_reads[1].progress_pages, 99, "progress_pages")
  eq(out.user_book_reads[1].id, 55, "the read id is preserved")
end)

check("a queued page creates a read when none exists", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 99, book_id = 1, edition_id = 3, read_id = 77, started_at = "2026-01-01" })
  local out = q:applyPending("/books/a.epub", { user_book_reads = {} })
  eq(#out.user_book_reads, 1, "read count")
  eq(out.user_book_reads[1].progress_pages, 99, "progress_pages")
  eq(out.user_book_reads[1].id, 77, "read id")
  eq(out.user_book_reads[1].started_at, "2026-01-01", "started_at")
end)

check("a queued status overrides the server status", function()
  local q = newQueue()
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 1 })
  local out = q:applyPending("/books/a.epub", { status_id = HARDCOVER.STATUS.READING })
  eq(out.status_id, HARDCOVER.STATUS.FINISHED, "status_id")
end)

check("no pending entry leaves server state untouched", function()
  local q = newQueue()
  local out = q:applyPending("/books/clean.epub", { status_id = HARDCOVER.STATUS.READING })
  eq(out.status_id, HARDCOVER.STATUS.READING, "status_id")
end)

check("applyPending with no status is harmless", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 5, book_id = 1 })
  eq(q:applyPending("/books/a.epub", nil), nil, "returns the nil it was given")
end)

-- ---------------------------------------------------------------- flushing

print("\n== flushing ==")

-- An API double that records what the queue asked it to do.
local function fakeApi(opts)
  opts = opts or {}
  local calls = {}
  return {
    calls = calls,
    findUserBook = function(_, book_id, user_id)
      calls[#calls + 1] = { op = "findUserBook", book_id = book_id, user_id = user_id }
      if opts.no_user_book then return nil end
      return {
        id = 500,
        status_id = HARDCOVER.STATUS.READING,
        user_book_reads = { { id = 900, edition_id = 3, started_at = "2026-01-01" } },
      }
    end,
    updateUserBook = function(_, book_id, status_id, privacy, edition_id)
      calls[#calls + 1] = { op = "updateUserBook", book_id = book_id, status_id = status_id }
      if opts.update_fails then return nil end
      return { id = 500, status_id = status_id, user_book_reads = {} }
    end,
    updateUserBookStatus = function(_, user_book_id, status_id)
      calls[#calls + 1] = { op = "updateUserBookStatus", user_book_id = user_book_id, status_id = status_id }
      if opts.update_fails then return nil end
      return { id = user_book_id, status_id = status_id, user_book_reads = {} }
    end,
    setFinishedDate = function(_, user_book, date)
      calls[#calls + 1] = { op = "setFinishedDate", date = date }
      return user_book
    end,
    updatePage = function(_, read_id, edition_id, page, started_at, action_at)
      calls[#calls + 1] = { op = "updatePage", read_id = read_id, edition_id = edition_id, page = page, action_at = action_at }
      if opts.page_fails then return nil end
      return { id = 500, status_id = HARDCOVER.STATUS.READING, user_book_reads = {} }
    end,
    createRead = function(_, user_book_id, edition_id, page, started_at, action_at)
      calls[#calls + 1] = { op = "createRead", user_book_id = user_book_id, page = page, action_at = action_at }
      return { id = 500, status_id = HARDCOVER.STATUS.READING, user_book_reads = {} }
    end,
  }
end

check("nothing queued flushes cleanly and calls nothing", function()
  local q = newQueue()
  local api = fakeApi()
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  eq(#api.calls, 0, "api calls made")
end)

check("an entry queued by another account is dropped, not sent to the signed-in one", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 77, book_id = 1, edition_id = 3, user_id = 1 })
  local api = fakeApi()
  eq(q:flush(api, { user_id = 2 }), true, "flush result")
  eq(#api.calls, 0, "api calls made for the other account")
  eq(q:hasPending(), false, "the other account's entry is gone")
end)

check("an entry with no user id (an older version) is sent as the signed-in user", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 77, book_id = 1, edition_id = 3 })
  local api = fakeApi()
  eq(q:flush(api, { user_id = 2 }), true, "flush result")
  eq(api.calls[1].user_id, 2, "looked up as")
end)

check("queueing as another account does not take over the first account's entry", function()
  local q = newQueue()
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 1, user_id = 1 })
  q:enqueuePage("/books/a.epub", { mapped_page = 5, book_id = 1, user_id = 2 })
  local entry = q:get("/books/a.epub")
  eq(entry.user_id, 2, "owner")
  eq(entry.status_id, nil, "the first account's status")
end)

check("a queued page is sent and then cleared", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 77, book_id = 1, edition_id = 3 })
  local api = fakeApi()
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  eq(q:hasPending(), false, "queue drained")
  local saw_page = false
  for _, c in ipairs(api.calls) do
    if c.op == "updatePage" and c.page == 77 then saw_page = true end
  end
  eq(saw_page, true, "the page reached the api")
end)

-- Reading over several days offline: one dated progress entry per day, oldest first.
local function atTimes(times, fn)
  -- queue calls os.time() more than once per page, so the clock moves only when the test says
  local real, now = os.time, times[1]
  os.time = function(t) if t then return real(t) end return now end
  local ok, err = pcall(fn, function(i) now = times[i] end)
  os.time = real
  if not ok then error(err, 0) end
end

local DAY = 86400
local T0 = 1760000000 -- 2025-10-09, mid-afternoon UTC

check("pages read on separate days are sent one per day, each with the time it was read", function()
  local q = newQueue()
  atTimes({ T0, T0 + DAY, T0 + 2 * DAY }, function(at)
    q:enqueuePage("/books/a.epub", { mapped_page = 30, book_id = 1, edition_id = 3 })
    at(2)
    q:enqueuePage("/books/a.epub", { mapped_page = 80, book_id = 1, edition_id = 3 })
    at(3)
    q:enqueuePage("/books/a.epub", { mapped_page = 120, book_id = 1, edition_id = 3 })
  end)
  local api = fakeApi()
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  local sent = {}
  for _, c in ipairs(api.calls) do if c.op == "updatePage" then sent[#sent + 1] = c end end
  eq(#sent, 3, "one write per day")
  eq(sent[1].page, 30, "oldest day first")
  eq(sent[2].page, 80, "next day")
  eq(sent[3].page, 120, "the latest page last")
  eq(sent[1].action_at, os.date("!%Y-%m-%dT%H:%M:%SZ", T0), "first day's time")
  eq(sent[3].action_at, os.date("!%Y-%m-%dT%H:%M:%SZ", T0 + 2 * DAY), "last day's time")
  eq(q:hasPending(), false, "queue drained")
end)

check("several pages on one day are sent as the last of that day", function()
  local q = newQueue()
  atTimes({ T0, T0 + 60, T0 + 120 }, function(at)
    q:enqueuePage("/books/a.epub", { mapped_page = 10, book_id = 1, edition_id = 3 })
    at(2)
    q:enqueuePage("/books/a.epub", { mapped_page = 11, book_id = 1, edition_id = 3 })
    at(3)
    q:enqueuePage("/books/a.epub", { mapped_page = 12, book_id = 1, edition_id = 3 })
  end)
  eq(#q:get("/books/a.epub").page_days, 1, "one entry for the day")
  local api = fakeApi()
  q:flush(api, { user_id = 1 })
  local sent = {}
  for _, c in ipairs(api.calls) do if c.op == "updatePage" then sent[#sent + 1] = c end end
  eq(#sent, 1, "one write")
  eq(sent[1].page, 12, "the last page of the day")
  eq(sent[1].action_at, os.date("!%Y-%m-%dT%H:%M:%SZ", T0 + 120), "dated when it was read")
end)

check("an earlier day Hardcover is already past is not sent", function()
  local q = newQueue()
  atTimes({ T0, T0 + DAY }, function(at)
    q:enqueuePage("/books/a.epub", { mapped_page = 5, book_id = 1, edition_id = 3 })
    at(2)
    q:enqueuePage("/books/a.epub", { mapped_page = 50, book_id = 1, edition_id = 3 })
  end)
  local api = fakeApi()
  local find = api.findUserBook
  api.findUserBook = function(self, ...)
    local ub = find(self, ...)
    ub.user_book_reads[1].progress_pages = 20
    return ub
  end
  q:flush(api, { user_id = 1 })
  local sent = {}
  for _, c in ipairs(api.calls) do if c.op == "updatePage" then sent[#sent + 1] = c.page end end
  eq(table.concat(sent, ","), "50", "only the page that moves the read forward")
end)

check("a day that was sent is not sent again after a failure later in the trail", function()
  local q = newQueue()
  atTimes({ T0, T0 + DAY }, function(at)
    q:enqueuePage("/books/a.epub", { mapped_page = 30, book_id = 1, edition_id = 3 })
    at(2)
    q:enqueuePage("/books/a.epub", { mapped_page = 90, book_id = 1, edition_id = 3 })
  end)
  local api = fakeApi()
  local update = api.updatePage
  api.updatePage = function(self, read_id, edition_id, page, started_at, action_at)
    if page == 90 then table.insert(self.calls, { op = "updatePage", page = page }) return nil end
    return update(self, read_id, edition_id, page, started_at, action_at)
  end
  eq(q:flush(api, { user_id = 1 }), false, "the flush is kept")
  eq(#q:get("/books/a.epub").page_days, 1, "the sent day is gone, the latest stays")
  local again = fakeApi()
  q:flush(again, { user_id = 1 })
  local sent = {}
  for _, c in ipairs(again.calls) do if c.op == "updatePage" then sent[#sent + 1] = c.page end end
  eq(table.concat(sent, ","), "90", "only the day that was left")
end)

check("a re-read does not carry the finished read's days", function()
  local q = newQueue()
  atTimes({ T0, T0 + DAY }, function(at)
    q:enqueuePage("/books/a.epub", { mapped_page = 300, book_id = 1, edition_id = 3 })
    at(2)
    q:startReread("/books/a.epub", { mapped_page = 2, book_id = 1, edition_id = 3 })
  end)
  local days = q:get("/books/a.epub").page_days
  eq(#days, 1, "one day")
  eq(days[1].page, 2, "the new read's page")
end)

check("an entry queued before times were kept is sent undated", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 40, book_id = 1, edition_id = 3 })
  local entry = q:get("/books/a.epub")
  entry.page_updated_at, entry.page_days = nil, nil
  local api = fakeApi()
  q:flush(api, { user_id = 1 })
  for _, c in ipairs(api.calls) do
    if c.op == "updatePage" then eq(c.action_at, nil, "no time sent") end
  end
end)

check("a queued status is sent and then cleared", function()
  local q = newQueue()
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 1 })
  local api = fakeApi()
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  local status_update
  for _, c in ipairs(api.calls) do
    if c.op == "updateUserBookStatus" and c.status_id == HARDCOVER.STATUS.FINISHED then status_update = c end
  end
  eq(status_update and status_update.user_book_id, 500, "the existing record reached the api")
end)

check("a queued status on an existing user book updates it by record id", function()
  local q = newQueue()
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.READING, book_id = 1 })
  local api = fakeApi()
  api.findUserBook = function()
    return { id = 501, status_id = HARDCOVER.STATUS.TO_READ, user_book_reads = {} }
  end
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  local status_update
  for _, c in ipairs(api.calls) do
    if c.op == "updateUserBookStatus" then status_update = c end
  end
  eq(status_update and status_update.user_book_id, 501, "existing record id")
  eq(status_update and status_update.status_id, HARDCOVER.STATUS.READING, "new status")
end)

check("a book finished offline is sent with the day it was finished, not the day of the sync", function()
  local q = newQueue()
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 1 })
  local entry = q:get("/books/a.epub")
  eq(entry.finished_date, os.date("%Y-%m-%d"), "the day is kept when the change is made")
  entry.finished_date = "2026-10-19" -- made on the 19th, synced on the 20th
  local api = fakeApi()
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  local date
  for _, c in ipairs(api.calls) do
    if c.op == "setFinishedDate" then date = c.date end
  end
  eq(date, "2026-10-19", "the finish date sent")
end)

check("a status that is not Finished sends no finish date", function()
  local q = newQueue()
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.READING, book_id = 1 })
  eq(q:get("/books/a.epub").finished_date, nil, "no day kept")
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 1 })
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.DNF, book_id = 1 })
  eq(q:get("/books/a.epub").finished_date, nil, "a later status drops the day")
end)

check("a book the server has never seen is created first", function()
  -- Progress on a book with no user_book yet has nowhere to land, so the queue
  -- has to establish the shelf entry before sending a page.
  local q = newQueue()
  q:enqueuePage("/books/new.epub", { mapped_page = 5, book_id = 42, edition_id = 3 })
  local api = fakeApi { no_user_book = true }
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  local created = false
  for _, c in ipairs(api.calls) do
    if c.op == "updateUserBook" and c.book_id == 42 then created = true end
  end
  eq(created, true, "the user book was created")
end)

check("a failed send keeps the entry for the next attempt", function()
  -- Losing queued progress on a transient network error is the worst outcome
  -- here: the reading history is silently wrong with no way to recover.
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 77, book_id = 1, edition_id = 3 })
  local api = fakeApi { page_fails = true }
  eq(q:flush(api, { user_id = 1 }), false, "flush reports failure")
  eq(q:hasPending(), true, "the entry survives")
  eq(q:get("/books/a.epub").mapped_page, 77, "the page survives")
end)

check("a failed status update keeps the entry too", function()
  local q = newQueue()
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 1 })
  local api = fakeApi { update_fails = true }
  eq(q:flush(api, { user_id = 1 }), false, "flush reports failure")
  eq(q:hasPending(), true, "the entry survives")
end)

local function existingBookApi(status_id)
  local api = fakeApi()
  api.findUserBook = function(_, book_id)
    api.calls[#api.calls + 1] = { op = "findUserBook", book_id = book_id }
    return { id = 500, status_id = status_id, user_book_reads = {} }
  end
  api.created_read, api.new_status = false, nil
  api.updateUserBookStatus = function(self, user_book_id, new_status)
    self.new_status = new_status
    return { id = user_book_id, status_id = new_status, user_book_reads = {} }
  end
  api.createRead = function(self, _, _, page)
    self.created_read = true
    return { id = 500, status_id = self.new_status or status_id,
      user_book_reads = { { id = 1, progress_pages = page } } }
  end
  api.updateUserBook = function(self, _, new_status)
    self.new_status = new_status
    return { id = 500, status_id = new_status, user_book_reads = {} }
  end
  return api
end

check("offline progress on a Want to Read book moves it to Currently Reading", function()
  -- The book was linked and read offline without the plugin ever having seen
  -- its status. Reading it means it is being read.
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 120, book_id = 1, edition_id = 3 })
  local api = existingBookApi(HARDCOVER.STATUS.TO_READ)
  api.updateUserBook = function() error("existing user book was inserted again") end
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  eq(api.new_status, HARDCOVER.STATUS.READING, "status set to Currently Reading")
  eq(api.created_read, true, "the page was recorded")
  eq(q:hasPending("/books/a.epub"), false, "the entry is cleared")
end)

check("a failed move to Currently Reading keeps the entry", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 120, book_id = 1, edition_id = 3 })
  local api = existingBookApi(HARDCOVER.STATUS.TO_READ)
  api.updateUserBookStatus = function() return nil end
  eq(q:flush(api, { user_id = 1 }), false, "flush result")
  eq(q:get("/books/a.epub").mapped_page, 120, "the page survives")
  eq(api.created_read, false, "no page was sent on a book still Want to Read")
end)

check("offline progress on a Finished book asks whether it is a re-read, and sends nothing yet", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 120, book_id = 1, edition_id = 3 })
  local api = existingBookApi(HARDCOVER.STATUS.FINISHED)
  eq(q:flush(api, { user_id = 1 }), false, "flush result")
  eq(api.created_read, false, "no reading record created")
  eq(api.new_status, nil, "status untouched")
  local conflicts = q:conflicts()
  eq(#conflicts, 1, "one conflict")
  eq(conflicts[1].entry.conflict.kind, "reread", "kind")
  eq(conflicts[1].entry.conflict.local_page, 120, "local page")
  local calls = #api.calls
  q:flush(api, { user_id = 1 })
  eq(#api.calls, calls, "a held conflict is not tried again")
end)

check("re-reading: yes sets Currently Reading, then writes its new read", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 120, book_id = 1, edition_id = 3 })
  local api = existingBookApi(HARDCOVER.STATUS.FINISHED)
  local order = {}
  api.updateUserBookStatus = function(self, id, status)
    order[#order + 1] = "updateUserBookStatus"
    self.new_status = status
    return { id = id, status_id = status, user_book_reads = { { id = 99 } } }
  end
  api.updatePage = function(_, id, _, page)
    order[#order + 1] = "updatePage"
    eq(id, 99, "new read")
    return { id = 500, status_id = HARDCOVER.STATUS.READING, user_book_reads = { { id = id, progress_pages = page } } }
  end
  q:flush(api, { user_id = 1 })
  eq(q:resolve("/books/a.epub", "yes"), true, "resolved")
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  eq(order[1], "updateUserBookStatus", "the status comes first")
  eq(order[2], "updatePage", "then the new read")
  eq(api.new_status, HARDCOVER.STATUS.READING, "now Currently Reading")
  eq(q:hasPending("/books/a.epub"), false, "cleared")
end)

check("re-reading: no drops the progress and touches nothing", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 120, book_id = 1, edition_id = 3 })
  local api = existingBookApi(HARDCOVER.STATUS.FINISHED)
  q:flush(api, { user_id = 1 })
  eq(q:resolve("/books/a.epub", "no"), true, "resolved")
  eq(q:hasPending("/books/a.epub"), false, "the entry is gone")
  eq(api.created_read, false, "no read created")
end)

local function cloudAhead(page)
  local api = fakeApi()
  api.findUserBook = function()
    return { id = 500, status_id = HARDCOVER.STATUS.READING,
      user_book_reads = { { id = 900, edition_id = 3, progress_pages = page } } }
  end
  return api
end

check("cloud ahead by a few pages wins quietly", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 100, book_id = 1, edition_id = 3 })
  local api = cloudAhead(103)
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  eq(q:conflictCount(), 0, "no question asked")
  eq(q:hasPending("/books/a.epub"), false, "dropped")
  for _, c in ipairs(api.calls) do eq(c.op ~= "updatePage", true, "no page sent") end
end)

check("cloud far ahead holds the page for the user; choosing this device sends it", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 100, book_id = 1, edition_id = 3 })
  local api = cloudAhead(200)
  q:flush(api, { user_id = 1 })
  local c = q:conflicts()[1]
  eq(c.entry.conflict.kind, "page", "kind")
  eq(c.entry.conflict.cloud_page, 200, "cloud page")
  eq(c.entry.mapped_page, 100, "our page is kept")
  eq(q:resolve("/books/a.epub", "local"), true, "resolved")
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  local sent
  for _, call in ipairs(api.calls) do if call.op == "updatePage" then sent = call.page end end
  eq(sent, 100, "our page was sent")
end)

check("cloud far ahead: choosing Hardcover drops ours and remembers where to resume", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 100, book_id = 1, edition_id = 3 })
  local api = cloudAhead(200)
  q:flush(api, { user_id = 1 })
  eq(q:resolve("/books/a.epub", "cloud"), true, "resolved")
  eq(q:hasPending("/books/a.epub"), false, "no page left to send")
  eq(q:takeResumePage("/books/a.epub"), 200, "resume page")
  eq(q:takeResumePage("/books/a.epub"), nil, "only once")
  eq(q:get("/books/a.epub"), nil, "entry cleaned up")
end)

check("Decide later and reading on both leave things sensible", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 100, book_id = 1, edition_id = 3 })
  q:flush(cloudAhead(200), { user_id = 1 })
  eq(q:resolve("/books/a.epub", "later"), false, "later changes nothing")
  eq(q:conflictCount(), 1, "still waiting")
  q:enqueuePage("/books/a.epub", { mapped_page = 130, book_id = 1, edition_id = 3 })
  eq(q:conflictCount(), 0, "reading on asks the question afresh")
end)

check("one book that always fails does not block the others", function()
  -- Returning on the first failure meant a single bad entry (a deleted book, a
  -- rejected edition) stopped every later book from syncing, forever.
  local q = newQueue()
  q:enqueuePage("/books/a_bad.epub", { mapped_page = 1, book_id = 1, edition_id = 3 })
  q:enqueuePage("/books/b_ok.epub", { mapped_page = 2, book_id = 2, edition_id = 3 })
  local api = fakeApi()
  local real = api.updatePage
  api.updatePage = function(self, read_id, edition_id, page)
    if page == 1 then self.calls[#self.calls + 1] = { op = "updatePage", page = page }; return nil end
    return real(self, read_id, edition_id, page)
  end
  eq(q:flush(api, { user_id = 1 }), false, "flush reports the failure")
  eq(q:hasPending("/books/b_ok.epub"), false, "the good book was sent")
  eq(q:hasPending("/books/a_bad.epub"), true, "the bad book is kept")
end)

check("flushing stops after repeated back-to-back failures", function()
  local q = newQueue()
  for i = 1, 5 do
    q:enqueuePage("/books/" .. i .. ".epub", { mapped_page = i, book_id = i, edition_id = 3 })
  end
  local api = fakeApi()
  -- the lookups fail: the network or token is down, not one book's fault
  api.findUserBook = function(self)
    self.calls[#self.calls + 1] = { op = "findUserBook" }
    return {}, { status = 503 }
  end
  q:flush(api, { user_id = 1 })
  local finds = 0
  for _, c in ipairs(api.calls) do if c.op == "findUserBook" then finds = finds + 1 end end
  eq(finds, 2, "books attempted before giving up")
  eq(q:pendingCount(), 5, "nothing was lost")
end)

check("books the server refuses do not stop the others, and are held after repeated refusals", function()
  local q = newQueue()
  q:enqueuePage("/books/a_dead.epub", { mapped_page = 1, book_id = 1, edition_id = 3 })
  q:enqueuePage("/books/b_dead.epub", { mapped_page = 2, book_id = 2, edition_id = 3 })
  q:enqueuePage("/books/c_ok.epub", { mapped_page = 3, book_id = 3, edition_id = 3 })
  local api = fakeApi()
  local find = api.findUserBook
  -- books 1 and 2 are gone server-side: not found, and the insert is refused
  api.findUserBook = function(self, book_id, user_id)
    if book_id ~= 3 then return nil end
    return find(self, book_id, user_id)
  end
  api.updateUserBook = function() return nil end
  q:flush(api, { user_id = 1 })
  eq(q:hasPending("/books/c_ok.epub"), false, "the healthy book synced on the first flush")
  q:flush(api, { user_id = 1 })
  q:flush(api, { user_id = 1 })
  eq(q:heldCount(), 2, "both refused books are held")
  local before = #api.calls
  q:flush(api, { user_id = 1 })
  eq(#api.calls, before, "held entries are not sent again")
  q:retryHeld()
  eq(q:heldCount(), 0, "retry releases them")
end)

check("an API call that throws releases the flushing flag", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 5, book_id = 1, edition_id = 3 })
  local api = fakeApi()
  api.updatePage = function() error("socket exploded") end
  eq(q:flush(api, { user_id = 1 }), false, "flush reports failure")
  eq(q.flushing, false, "flushing flag")
  eq(q:get("/books/a.epub").mapped_page, 5, "the page survives")
  eq(q:flush(fakeApi(), { user_id = 1 }), true, "a later flush works")
end)

check("an enqueue writes the queue to disk once", function()
  local q, settings = newQueue()
  local writes = 0
  settings.flush = function() writes = writes + 1 return true end
  q:enqueuePage("/books/a.epub", { mapped_page = 5, book_id = 1 })
  eq(writes, 1, "page enqueue writes")
  writes = 0
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 1 })
  eq(writes, 1, "status enqueue writes")
end)

check("a re-entrant flush is refused rather than double-sending", function()
  -- flush() recurses through callbacks in some paths; sending twice would
  -- duplicate reads.
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 5, book_id = 1, edition_id = 3 })
  local api = fakeApi()
  local reentrant
  api.findUserBook = function(_, book_id, user_id)
    if reentrant == nil then
      reentrant = q:flush(api, { user_id = 1 })
    end
    return { id = 500, user_book_reads = { { id = 900, edition_id = 3 } } }
  end
  eq(q:flush(api, { user_id = 1 }), true, "outer flush")
  eq(reentrant, false, "inner flush refused")
end)

check("the flushing flag is released after a failure", function()
  -- If it were not, every later flush would be silently refused and progress
  -- would never sync again for the rest of the session.
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 5, book_id = 1, edition_id = 3 })
  q:flush(fakeApi { page_fails = true }, { user_id = 1 })
  eq(q.flushing, false, "flushing flag")
end)

check("a snapshot is written after a successful send", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 5, book_id = 1, edition_id = 3 })
  local saved = {}
  local settings = {
    saveBookSnapshot = function(_, filepath, book) saved[filepath] = book end,
  }
  q:flush(fakeApi(), { user_id = 1, settings = settings })
  if saved["/books/a.epub"] == nil then
    error("no snapshot was saved")
  end
end)

check("the open book is refreshed into app state", function()
  local q = newQueue()
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 1 })
  local state = {}
  q:flush(fakeApi(), { user_id = 1, state = state, current_file = "/books/a.epub" })
  eq(state.book_status_fetched, true, "fetched flag")
  if state.book_status == nil then error("state.book_status was not set") end
end)

check("another book's send does not clobber the open book's state", function()
  local q = newQueue()
  q:enqueueStatus("/books/other.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 2 })
  local state = { book_status = { id = "keep-me" } }
  q:flush(fakeApi(), { user_id = 1, state = state, current_file = "/books/a.epub" })
  eq(state.book_status.id, "keep-me", "open book state")
end)

-- ---------------------------------------------------------------- manual control

print("\n== manual control ==")

check("clearAll empties the queue and reports the count", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 1, book_id = 1 })
  q:enqueuePage("/books/b.epub", { mapped_page = 2, book_id = 2 })
  q:enqueueStatus("/books/c.epub", { status_id = 1, book_id = 3 })
  eq(q:clearAll(), 3, "cleared count")
  eq(q:hasPending(), false, "queue empty")
  eq(q:pendingCount(), 0, "pendingCount")
end)

check("clearAll persists the empty queue", function()
  local q, settings = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 1, book_id = 1 })
  q:clearAll()
  -- A stale copy in LuaSettings would resurrect the entries on next launch.
  local stored = settings.store["pending"] or {}
  eq(next(stored), nil, "stored queue")
end)

check("clearAll on an empty queue reports zero", function()
  local q = newQueue()
  eq(q:clearAll(), 0, "cleared count")
end)

check("clear removes one book and leaves the rest", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 1, book_id = 1 })
  q:enqueuePage("/books/b.epub", { mapped_page = 2, book_id = 2 })
  q:clear("/books/a.epub")
  eq(q:pendingCount(), 1, "remaining")
  eq(q:hasPending("/books/b.epub"), true, "the other book survives")
end)

-- ---------------------------------------------------------------- Home's reading cards

print("\n== what Home's Currently Reading shows offline ==")

local function cards()
  return {
    { book_id = 7, title = "Seven", progress_pages = 100, pages = 300 },
    { book_id = 8, title = "Eight", progress_pages = 10, pages = 200 },
    { book_id = 9, title = "Nine", progress_pages = 50, pages = 250 },
  }
end

check("nothing queued: the cards come back as they are", function()
  local q = SyncQueue:new { settings = fakeSettings() }
  local saved = cards()
  local out = q:applyToReading(saved)
  eq(#out, 3, "cards")
  eq(out[1].progress_pages, 100, "progress")
  eq(#q:applyToReading(nil), 0, "no cards")
end)

check("a queued page further on than the card's is shown; a lower one is not", function()
  local q = SyncQueue:new { settings = fakeSettings() }
  q:enqueuePage("/b/7.epub", { mapped_page = 180, book_id = 7 })
  q:enqueuePage("/b/8.epub", { mapped_page = 4, book_id = 8 })
  local saved = cards()
  local out = q:applyToReading(saved)
  eq(out[1].progress_pages, 180, "book 7 shows the offline page")
  eq(out[2].progress_pages, 10, "book 8 is never taken backwards")
  eq(saved[1].progress_pages, 100, "the saved card itself is not changed")
end)

check("a book finished, dropped or put back offline leaves Currently Reading", function()
  local q = SyncQueue:new { settings = fakeSettings() }
  q:enqueueStatus("/b/7.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 7 })
  q:enqueueStatus("/b/9.epub", { status_id = HARDCOVER.STATUS.DNF, book_id = 9 })
  local out = q:applyToReading(cards())
  eq(#out, 1, "cards left")
  eq(out[1].book_id, 8, "the one still being read")
end)

check("a book started offline comes first, with the shelf row's cover when there is one", function()
  local q = SyncQueue:new { settings = fakeSettings() }
  q:enqueueStatus("/b/20.epub", { status_id = HARDCOVER.STATUS.READING, book_id = 20, title = "Twenty" })
  q:enqueuePage("/b/20.epub", { mapped_page = 33, book_id = 20 })
  local looked
  local out = q:applyToReading(cards(), function(id)
    looked = id
    return { book_id = 20, title = "Twenty (shelf)", pages = 400, cached_image = { url = "c.jpg" } }
  end)
  eq(#out, 4, "cards")
  eq(out[1].book_id, 20, "the new book is first")
  eq(looked, 20, "looked up in the saved shelves")
  eq(out[1].pages, 400, "page count from the shelf row")
  eq(out[1].progress_pages, 33, "the offline page")
  -- with no shelf row the card still exists, from what the queue knows
  local bare = q:applyToReading({})
  eq(#bare, 1, "a card for the new book")
  eq(bare[1].title, "Twenty", "title from the queue")
end)

check("a book already reading with only a queued page is not added twice", function()
  local q = SyncQueue:new { settings = fakeSettings() }
  q:enqueueStatus("/b/8.epub", { status_id = HARDCOVER.STATUS.READING, book_id = 8 })
  eq(#q:applyToReading(cards()), 3, "cards")
end)

-- ---------------------------------------------------------------- persistence

print("\n== surviving a restart ==")

check("a queue survives being rebuilt from settings", function()
  -- This is the actual offline promise: progress recorded with no network must
  -- still be there after KOReader is closed and reopened.
  local settings = fakeSettings()
  local first = SyncQueue:new { settings = settings }
  first:enqueuePage("/books/a.epub", { mapped_page = 314, book_id = 7, edition_id = 3 })

  local second = SyncQueue:new { settings = settings }
  eq(second:get("/books/a.epub").mapped_page, 314, "mapped_page after reload")
  eq(second:pendingCount(), 1, "pendingCount after reload")
end)

check("a status survives being rebuilt from settings", function()
  local settings = fakeSettings()
  SyncQueue:new { settings = settings }:enqueueStatus("/books/a.epub", {
    status_id = HARDCOVER.STATUS.FINISHED, book_id = 7, privacy_setting_id = 2,
  })
  local second = SyncQueue:new { settings = settings }
  local e = second:get("/books/a.epub")
  eq(e.status_id, HARDCOVER.STATUS.FINISHED, "status_id")
  eq(e.privacy_setting_id, 2, "privacy_setting_id")
end)

-- Want to Read -> Currently Reading -> read a bit -> Paused, all offline.
local function pausedAfterReading(page_after_pause)
  local q = newQueue()
  local f = "/books/a.epub"
  q:enqueueStatus(f, { status_id = HARDCOVER.STATUS.READING, book_id = 1, edition_id = 3, from_status_id = HARDCOVER.STATUS.TO_READ })
  q:enqueuePage(f, { mapped_page = 40, book_id = 1, edition_id = 3 })
  q:enqueueStatus(f, { status_id = HARDCOVER.STATUS.PAUSED, book_id = 1, edition_id = 3, from_status_id = HARDCOVER.STATUS.READING })
  local e = q:get(f)
  e.status_updated_at = 1000
  e.page_updated_at = page_after_pause and 1001 or 999
  return q, f
end

check("Paused after offline reading on a Want to Read book is sent", function()
  local q, f = pausedAfterReading(false)
  local api = existingBookApi(HARDCOVER.STATUS.TO_READ)
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  eq(api.new_status, HARDCOVER.STATUS.PAUSED, "ends on Paused")
  eq(q:hasPending(f), false, "the entry is cleared")
end)

check("a page turn after Paused does not hold the Paused status back", function()
  local q, f = pausedAfterReading(true)
  local api = existingBookApi(HARDCOVER.STATUS.TO_READ)
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  eq(api.new_status, HARDCOVER.STATUS.PAUSED, "ends on Paused")
  eq(q:hasPending(f), false, "the entry is cleared")
end)

print("")
print(string.format("  %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
