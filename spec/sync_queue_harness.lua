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
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.READING, book_id = 1 })
  eq(q:pendingCount(), 1, "pending file count")
  eq(q:changeCount(), 2, "pending change count")
  local e = q:get("/books/a.epub")
  eq(e.mapped_page, 10, "page survives")
  eq(e.status_id, HARDCOVER.STATUS.READING, "status recorded")
end)

-- ------------------------------------------------- one entry per book

print("\n== one entry per book ==")

check("a change with no book to send it to is not queued", function()
  local q = newQueue()
  eq(q:enqueuePage("/books/a.epub", { mapped_page = 10 }), nil, "page")
  eq(q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.READING }), nil, "status")
  eq(q:hasPending(), false)
end)

check("two files of one book share the entry, and either finds it", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 10, book_id = 7 })
  q:enqueuePage("/books/a.pdf", { mapped_page = 30, book_id = 7 })
  eq(q:pendingCount(), 1)
  eq(q:get("/books/a.epub"), q:get("/books/a.pdf"), "the same entry")
  eq(q:get(7), q:get("/books/a.pdf"), "by book id")
  eq(q:get("/books/a.pdf").file, "/books/a.pdf", "the last file read from")
  eq(q:get("/books/other.epub"), nil)
end)

check("entries kept by file are moved to the book on first read: newest page and newest status each win", function()
  local q, settings = newQueue()
  settings:saveSetting("pending", {
    ["/books/a.epub"] = { book_id = 7, title = "A", updated_at = 200, mapped_page = 10, page_updated_at = 100,
      status_id = 3, status_updated_at = 200, finished_date = "2026-10-30" },
    ["/books/a.pdf"] = { book_id = 7, updated_at = 150, mapped_page = 30, page_updated_at = 150,
      status_id = 2, status_updated_at = 150 },
    ["/books/b.epub"] = { book_id = 8, mapped_page = 5, page_updated_at = 50, updated_at = 50 },
    ["/books/nobook.epub"] = { mapped_page = 9, page_updated_at = 60, updated_at = 60 },
    ["/books/junk.epub"] = 5,
  })
  q = SyncQueue:new { settings = settings }
  eq(q:pendingCount(), 2, "the entry with no book and the junk are gone")
  local e = q:get(7)
  eq(e.mapped_page, 30, "the newer page, from the other file")
  eq(e.status_id, 3, "the newer status, from this one")
  eq(e.finished_date, "2026-10-30", "its finish day goes with it")
  assert(e.files["/books/a.epub"] and e.files["/books/a.pdf"], "both files found")
  eq(q:get("/books/b.epub").mapped_page, 5)
  eq(q:get("/books/nobook.epub"), nil)
  assert(settings:readSetting("pending")["/books/a.epub"] == nil, "the old key was left behind")
  -- moved once: a second queue over the same settings reads the same
  eq(SyncQueue:new { settings = settings }:get(7).mapped_page, 30)
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
    -- a removal asks with more fields; older cases answer through findUserBook
    findUserBookForRemoval = function(self, book_id, user_id)
      return self.findUserBook(self, book_id, user_id)
    end,
    updateUserBook = function(_, book_id, status_id, privacy, edition_id, at)
      calls[#calls + 1] = { op = "updateUserBook", book_id = book_id, status_id = status_id, at = at }
      if opts.update_fails then return nil end
      return { id = 500, status_id = status_id, user_book_reads = {} }
    end,
    updateUserBookStatus = function(_, user_book_id, status_id, privacy, at)
      calls[#calls + 1] = { op = "updateUserBookStatus", user_book_id = user_book_id, status_id = status_id, at = at }
      if opts.update_fails then return nil end
      return { id = user_book_id, status_id = status_id,
        user_book_reads = status_id == HARDCOVER.STATUS.FINISHED and { { id = 900, finished_at = "2026-01-05" } } or {} }
    end,
    updateReadDates = function(_, id, dates)
      calls[#calls + 1] = { op = "updateReadDates", dates = dates }
      return { id = 500, status_id = dates.finished_at and HARDCOVER.STATUS.FINISHED or HARDCOVER.STATUS.READING,
        user_book_reads = { { id = id, started_at = dates.started_at, finished_at = dates.finished_at } } }
    end,
    updatePage = function(_, read_id, edition_id, page, started_at, action_at)
      calls[#calls + 1] = { op = "updatePage", read_id = read_id, edition_id = edition_id, page = page, action_at = action_at }
      if opts.page_fails then return nil end
      return { id = 500, status_id = HARDCOVER.STATUS.READING,
        user_book_reads = { { id = read_id, edition_id = edition_id, progress_pages = page, started_at = started_at } } }
    end,
    createRead = function(_, user_book_id, edition_id, page, started_at, action_at)
      calls[#calls + 1] = { op = "createRead", user_book_id = user_book_id, page = page, action_at = action_at }
      return { id = 500, status_id = HARDCOVER.STATUS.READING, user_book_reads = {} }
    end,
  }
end

check("shelf changes kept apart before are moved in: the newer of two for a book wins, the reader's on a tie", function()
  local q, settings = newQueue()
  settings:saveSetting("pending", {
    ["7"] = { book_id = 7, file = "/books/a.epub", files = { ["/books/a.epub"] = true }, updated_at = 300,
      mapped_page = 10, page_updated_at = 300, status_id = 2, status_updated_at = 200 },
    ["8"] = { book_id = 8, file = "/books/b.epub", files = { ["/books/b.epub"] = true }, updated_at = 100,
      status_id = 2, status_updated_at = 100 },
    ["9"] = { book_id = 9, file = "/books/c.epub", files = { ["/books/c.epub"] = true }, updated_at = 100,
      status_id = 2, status_updated_at = 150 },
  })
  settings:saveSetting("shelf_ops", {
    ["7"] = { kind = "status", book_id = 7, status_id = 3, at = 250, user_id = 1, user_book_id = 70, from_status_id = 1 },
    ["8"] = { kind = "status", book_id = 8, status_id = 3, at = 90, user_id = 1 },
    ["9"] = { kind = "remove", book_id = 9, user_book_id = 90, at = 150, user_id = 1, from_status_id = 2 },
    ["10"] = { kind = "status", book_id = 10, status_id = 1, at = 5, user_id = 1, title = "New", edition_id = 4,
      held = true, reason = "scope", failures = 1 },
    ["11"] = "junk",
  })
  q = SyncQueue:new { settings = settings }
  local e7 = q:get(7)
  eq(e7.status_id, 3, "the newer shelf change replaced the reader's status")
  eq(e7.mapped_page, 10, "the page stayed")
  eq(e7.user_book_id, 70); eq(e7.from_status_id, 1)
  eq(q:get(8).status_id, 2, "the reader's newer status stands")
  eq(q:get(9).status_id, 2, "a tie: the reader's stands")
  local e10 = q:get(10)
  eq(e10.status_id, 1); eq(e10.edition_id, 4); eq(e10.title, "New")
  eq(e10.held, true); eq(e10.reason, "scope", "a held change stays held")
  eq(settings:readSetting("shelf_ops"), nil, "the old key is cleared")
  eq(q:count(), 4)
end)

check("a removal kept apart before is moved in as a removal", function()
  local q, settings = newQueue()
  settings:saveSetting("shelf_ops", { ["5"] = { kind = "remove", book_id = 5, user_book_id = 50, at = 10, user_id = 1, from_status_id = 3 } })
  q = SyncQueue:new { settings = settings }
  local op = q:shelfOp(5, 1)
  eq(op.kind, "remove"); eq(op.user_book_id, 50); eq(op.from_status_id, 3)
  eq(q:hasPending(), true)
end)

check("an entry migrated from a file is sent, and its file takes the snapshot", function()
  local q, settings = newQueue()
  settings:saveSetting("pending", { ["/books/a.epub"] = { book_id = 1, mapped_page = 10, page_updated_at = 5, updated_at = 5 } })
  q = SyncQueue:new { settings = settings }
  local snapshots = {}
  eq(q:flush(fakeApi(), { user_id = 1, settings = { saveBookSnapshot = function(_, file) snapshots[#snapshots + 1] = file end } }), true)
  eq(q:hasPending(), false)
  eq(snapshots[1], "/books/a.epub")
end)

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

check("a re-read preserves earlier progress before the new read's page", function()
  local q = newQueue()
  atTimes({ T0, T0 + DAY }, function(at)
    q:enqueuePage("/books/a.epub", { mapped_page = 300, book_id = 1, edition_id = 3 })
    at(2)
    q:startReread("/books/a.epub", { mapped_page = 2, book_id = 1, edition_id = 3 })
  end)
  local days = q:get("/books/a.epub").page_days
  eq(#days, 2, "both reading sessions are kept")
  eq(days[1].page, 300, "the earlier read's page")
  eq(days[2].page, 2, "the new read's page")
end)

check("an entry queued before times were kept is sent undated", function()
  local q = newQueue()
  q:save(1, { mapped_page = 40, book_id = 1, edition_id = 3 })
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

check("a queued status is sent with the time it was made, on an existing record and a new one", function()
  local q = newQueue()
  atTimes({ 1234 }, function()
    q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 1 })
  end)
  local api = fakeApi()
  q:flush(api, { user_id = 1 })
  local sent
  for _, c in ipairs(api.calls) do if c.op == "updateUserBookStatus" then sent = c end end
  eq(sent and sent.at, 1234, "existing record")

  q = newQueue()
  atTimes({ 5678 }, function()
    q:enqueueStatus("/books/b.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 2 })
  end)
  api = fakeApi { no_user_book = true }
  q:flush(api, { user_id = 1 })
  eq(api.calls[2].op, "updateUserBook")
  eq(api.calls[2].at, 5678, "new record")
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
  local finished_at = os.time { year = 2026, month = 10, day = 19, hour = 12 }
  atTimes({ finished_at }, function()
    q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 1 })
  end)
  local entry = q:get("/books/a.epub")
  eq(entry.finished_date, "2026-10-19", "the day is kept when the change is made")
  local api = fakeApi()
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  local date
  for _, c in ipairs(api.calls) do
    if c.op == "updateReadDates" then date = c.dates.finished_at end
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
  api.createRead = function(self, _, _, page, started_at)
    self.created_read = true
    return { id = 500, status_id = self.new_status or status_id,
      user_book_reads = { { id = 1, progress_pages = page, started_at = started_at } } }
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
  api.updatePage = function(_, id, _, page, started_at)
    order[#order + 1] = "updatePage"
    eq(id, 99, "new read")
    return { id = 500, status_id = HARDCOVER.STATUS.READING,
      user_book_reads = { { id = id, progress_pages = page, started_at = started_at } } }
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

check("Decide later and reading on both leave the question waiting", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 100, book_id = 1, edition_id = 3 })
  q:flush(cloudAhead(200), { user_id = 1 })
  eq(q:resolve("/books/a.epub", "later"), false, "later changes nothing")
  eq(q:conflictCount(), 1, "still waiting")
  q:enqueuePage("/books/a.epub", { mapped_page = 130, book_id = 1, edition_id = 3 })
  -- A later page turn is saved behind the question; it is not an answer, and it must not
  -- erase the barrier that keeps the conflicting page from being sent.
  eq(q:conflictCount(), 1, "reading on keeps the barrier")
  eq(q:get("/books/a.epub").conflict.seq, 1, "the question is still about the first page")
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

-- What a flush sends, without the lookups, so a batched run can be compared with a per-book one.
local function sentOps(calls)
  local out = {}
  for _, c in ipairs(calls) do
    if c.op ~= "findUserBook" then
      out[#out + 1] = c.op .. ":" .. tostring(c.book_id or c.read_id or c.user_book_id) .. ":" .. tostring(c.page or c.status_id)
    end
  end
  return table.concat(out, ",")
end

local function threeBooks(batched)
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 5, book_id = 1, edition_id = 3 })
  q:enqueuePage("/books/b.epub", { mapped_page = 6, book_id = 2, edition_id = 3 })
  q:enqueuePage("/books/c.epub", { mapped_page = 7, book_id = 3, edition_id = 3 })
  local api = fakeApi()
  local find = api.findUserBook
  api.findUserBook = function(self, book_id, user_id)
    if book_id == 3 then
      self.calls[#self.calls + 1] = { op = "findUserBook", book_id = book_id }
      return nil
    end
    return find(self, book_id, user_id)
  end
  local batches = {}
  if batched then
    api.findUserBooks = function(_, ids, user_id)
      batches[#batches + 1] = { ids = ids, user_id = user_id }
      local found = {}
      for _, id in ipairs(ids) do
        found[tostring(id)] = id ~= 3 and { id = 500, status_id = HARDCOVER.STATUS.READING,
          user_book_reads = { { id = 900, edition_id = 3, started_at = "2026-01-01" } } } or false
      end
      return found
    end
  end
  local result = q:flush(api, { user_id = 1 })
  return result, api, batches, q
end

check("a flush asks for every queued book's library record in one request", function()
  local result, api, batches, q = threeBooks(true)
  eq(result, true, "flush result")
  eq(#batches, 1, "one batched lookup")
  eq(#batches[1].ids, 3, "every queued book is in it")
  eq(batches[1].user_id, 1, "for the signed-in account")
  local finds = 0
  for _, c in ipairs(api.calls) do if c.op == "findUserBook" then finds = finds + 1 end end
  eq(finds, 0, "no per-book lookups")
  eq(#q:keys(), 0, "every entry is sent")
end)

check("a batched lookup sends exactly what per-book lookups send", function()
  local _, per_book = threeBooks(false)
  local _, batched = threeBooks(true)
  local expected = sentOps(per_book.calls)
  assert(expected ~= "", "the per-book run sent something")
  eq(sentOps(batched.calls), expected, "the same requests, in the same order")
end)

check("a failed batched lookup falls back to one lookup per book", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 5, book_id = 1, edition_id = 3 })
  q:enqueuePage("/books/b.epub", { mapped_page = 6, book_id = 2, edition_id = 3 })
  local api = fakeApi()
  api.findUserBooks = function() return nil, { status = 503 } end
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  local finds = 0
  for _, c in ipairs(api.calls) do if c.op == "findUserBook" then finds = finds + 1 end end
  eq(finds, 2, "each book asked for its own record")
end)

-- A removal and the record it expects: the base is what this device knew when the
-- reader asked to remove the book.
local function removalBase(overrides)
  local base = {
    status_known = true, status_id = HARDCOVER.STATUS.READING,
    rating_known = true, rating = nil,
    reads_known = true, reads = nil,
    review_known = false,
    updated_at = "2026-01-01T00:00:00Z",
  }
  for key, value in pairs(overrides or {}) do base[key] = value end
  return base
end

local function removalRecord(overrides)
  local record = {
    id = 70, book_id = 7, status_id = HARDCOVER.STATUS.READING, rating = nil,
    updated_at = "2026-01-01T00:00:00Z", has_review = false, user_book_reads = {},
  }
  for key, value in pairs(overrides or {}) do record[key] = value end
  return record
end

local function removalQueue(book_id, record_id, base)
  local q = newQueue()
  q:queueRemove(1, book_id, record_id, "Dune", HARDCOVER.STATUS.READING, base or removalBase(),
    "/books/a.epub")
  return q
end

check("an unchanged removal deletes the record", function()
  local q = removalQueue(7, 70, removalBase({ review_known = true, review_raw = nil }))
  local api = fakeApi()
  api.findUserBookForRemoval = function() return removalRecord() end
  local removed = {}
  api.removeUserBook = function(_, id) removed[#removed + 1] = id return { id = id } end
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  eq(#removed, 1, "removed once"); eq(removed[1], 70, "the saved record")
  eq(#q:keys(), 0, "nothing left")
end)

check("a removal no longer in the library finishes quietly", function()
  local q = removalQueue(7, 70)
  local api = fakeApi()
  api.findUserBookForRemoval = function() return nil end
  local removed = 0
  api.removeUserBook = function() removed = removed + 1 return true end
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  eq(removed, 0, "nothing to delete")
  eq(#q:keys(), 0, "nothing left")
end)

check("a finished removal clears the saved snapshot and the shelf marker", function()
  local q = removalQueue(7, 70)
  local api = fakeApi()
  api.findUserBookForRemoval = function() return removalRecord() end
  api.removeUserBook = function(_, id) return { id = id } end
  local cleared, removed = {}, {}
  local settings = { clearBookSnapshotsFor = function(_, book_id) cleared[#cleared + 1] = book_id end }
  eq(q:flush(api, { user_id = 1, settings = settings,
    on_removed = function(op) removed[#removed + 1] = op end }), true)
  eq(cleared[1], 7, "the file still has the removed book's snapshot")
  eq(#removed, 1, "the shelf was not told the removal is done")
  eq(removed[1].kind, "remove", "the wrong callback was used")
  eq(removed[1].book_id, 7, "the wrong book's marker was cleared")

  local q2 = removalQueue(7, 70)
  local api2 = fakeApi()
  api2.findUserBookForRemoval = function() return nil end
  local cleared2 = {}
  eq(q2:flush(api2, { user_id = 1,
    settings = { clearBookSnapshotsFor = function(_, book_id) cleared2[#cleared2 + 1] = book_id end } }), true)
  eq(cleared2[1], 7, "an already-gone removal left the stale snapshot")
end)

check("a removal that asks a question leaves the snapshot alone", function()
  local q = removalQueue(7, 70, removalBase({ rating = 4 }))
  local api = fakeApi()
  api.findUserBookForRemoval = function() return removalRecord({ rating = 5 }) end
  local cleared = 0
  local settings = { clearBookSnapshotsFor = function() cleared = cleared + 1 end }
  eq(q:flush(api, { user_id = 1, settings = settings }), false)
  eq(cleared, 0, "a kept book lost its saved snapshot")
end)

check("an answerless delete is marked, so putting the book back keeps its edition", function()
  local q = removalQueue(7, 70)
  local api = fakeApi()
  api.findUserBookForRemoval = function() return removalRecord() end
  api.removeUserBook = function() return nil, { completed = false } end
  eq(q:flush(api, { user_id = 1 }), false)
  eq(q:get(7).maybe_remote, true, "the possibly-landed delete was not remembered")
  q:enqueueStatus("/books/a.epub", { user_id = 1, book_id = 7, status_id = HARDCOVER.STATUS.FINISHED,
    edition_id = 9, from_status_id = HARDCOVER.STATUS.READING })
  eq(q:shelfOp(7).edition_id, 9, "the restored book lost its linked edition")
end)

check("a book that gained work online keeps both the book and the removal", function()
  local q = removalQueue(7, 70, removalBase({ rating = 4, reads = "1:10:3::" }))
  local api = fakeApi()
  api.findUserBookForRemoval = function()
    return removalRecord({ rating = 5, user_book_reads = { { id = 1, progress_pages = 240, edition_id = 3 } },
      has_review = true, review_raw = "new words" })
  end
  local removed = 0
  api.removeUserBook = function() removed = removed + 1 return true end
  eq(q:flush(api, { user_id = 1 }), false, "a question is not a successful send")
  eq(removed, 0, "the book is kept")
  local entry = q:get(7)
  eq(entry.remove, true, "the removal is kept")
  eq(entry.conflict.kind, "remove", "a decision")
  local changes = entry.conflict.changes
  local text = table.concat(changes, ",")
  for _, want in ipairs({ "a rating", "reading progress", "a review" }) do
    if not text:find(want, 1, true) then error("missing " .. want .. " in " .. text) end
  end
  eq(q:conflictCount(), 1, "one question")
end)

check("one removal's question does not stop another book's removal", function()
  local q = removalQueue(7, 70, removalBase({ rating = 4 }))
  -- a second book with an unchanged record
  q:queueRemove(1, 8, 80, "Emma", HARDCOVER.STATUS.READING, removalBase())
  local api = fakeApi()
  api.findUserBookForRemoval = function(book_id)
    if tonumber(book_id) == 7 then return removalRecord({ rating = 5 }) end
    return removalRecord({ id = 80, book_id = 8 })
  end
  local removed = {}
  api.removeUserBook = function(_, id) removed[#removed + 1] = id return { id = id } end
  eq(q:flush(api, { user_id = 1 }), false, "the pass reports the unanswered question")
  eq(table.concat(removed, ","), "80", "the other removal went through")
  eq(q:get(7).conflict.kind, "remove")
  eq(q:get(8), nil)
end)

check("a replacement record is a question even when its fields match", function()
  local q = removalQueue(7, 70)
  local api = fakeApi()
  api.findUserBookForRemoval = function() return removalRecord({ id = 71 }) end
  local removed = 0
  api.removeUserBook = function() removed = removed + 1 return true end
  q:flush(api, { user_id = 1 })
  eq(removed, 0, "the replacement is kept")
  eq(q:get(7).conflict.replaced, true, "reported as a replacement")
end)

check("keeping the book releases what waited behind the removal", function()
  local q = removalQueue(7, 70, removalBase({ rating = 4 }))
  local api = fakeApi()
  api.findUserBookForRemoval = function() return removalRecord({ rating = 5 }) end
  q:flush(api, { user_id = 1 })
  q:enqueuePage("/books/dune.epub", { mapped_page = 42, book_id = 7, edition_id = 3, title = "Dune" })
  eq(q:conflictCount(), 1, "reading on does not answer the removal")
  eq(q:resolve("/books/dune.epub", "keep"), true, "kept the book")
  local entry = q:get("/books/dune.epub")
  eq(entry.remove, nil, "no removal left")
  eq(entry.mapped_page, 42, "the page behind it is still saved")
  eq(q:flush(api, { user_id = 1 }), true, "the page goes")
  eq(q:hasPending("/books/dune.epub"), false)
end)

check("removing anyway rechecks once more before deleting", function()
  local q = removalQueue(7, 70, removalBase({ rating = 4 }))
  local api = fakeApi()
  api.findUserBookForRemoval = function() return removalRecord({ rating = 5 }) end
  local removed = 0
  api.removeUserBook = function() removed = removed + 1 return true end
  q:flush(api, { user_id = 1 })
  eq(q:resolve(7, "remove"), true, "accepted the online record")
  eq(q:get(7).conflict, nil, "the question is gone")
  -- Hardcover changes again before the next pass: ask again rather than delete unseen work
  api.findUserBookForRemoval = function() return removalRecord({ rating = 3 }) end
  q:flush(api, { user_id = 1 })
  eq(removed, 0, "not deleted")
  eq(q:get(7).conflict.kind, "remove", "asked again")
  eq(q:resolve(7, "remove"), true, "accepted the newer record")
  -- the same record as the accepted one can go
  api.findUserBookForRemoval = function() return removalRecord({ rating = 3 }) end
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  eq(removed, 1, "deleted")
  eq(#q:keys(), 0)
end)

check("a shelf change made while a removal lookup runs is kept", function()
  local q = removalQueue(7, 70)
  local api = fakeApi()
  local removed = 0
  api.removeUserBook = function() removed = removed + 1 return true end
  local first = true
  api.findUserBookForRemoval = function()
    if first then
      first = false
      q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.READING, book_id = 7, title = "Dune" })
      return nil
    end
    return nil
  end
  eq(q:flush(api, { user_id = 1 }), false, "the canceled removal did not count as sent")
  eq(removed, 0, "nothing deleted")
  local entry = q:get("/books/a.epub")
  eq(entry and entry.remove, nil, "the removal was canceled")
  eq(entry and entry.status_id, HARDCOVER.STATUS.READING, "the new shelf change survived")
  -- the next pass sends the shelf change, not nothing
  local api2 = fakeApi()
  api2.findUserBook = function() return { id = 70, status_id = HARDCOVER.STATUS.TO_READ, user_book_reads = {} } end
  local sent_status = false
  api2.updateUserBookStatus = function(_, id, status)
    sent_status = true
    return { id = id, status_id = status, user_book_reads = {} }
  end
  eq(q:flush(api2, { user_id = 1 }), true, "the new shelf change goes")
  eq(sent_status, true, "the status was sent")
  eq(q:get("/books/a.epub"), nil, "nothing left")
end)

check("a shelf change made while a removal lookup finds a record is kept too", function()
  local q = removalQueue(7, 70)
  local api = fakeApi()
  local removed = 0
  api.removeUserBook = function() removed = removed + 1 return true end
  api.findUserBookForRemoval = function()
    q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 7, title = "Dune" })
    return removalRecord({ rating = 5 })
  end
  eq(q:flush(api, { user_id = 1 }), false, "the canceled removal did not count as sent")
  eq(removed, 0, "nothing deleted")
  local entry = q:get("/books/a.epub")
  eq(entry and entry.remove, nil, "the removal was canceled")
  eq(entry and entry.status_id, HARDCOVER.STATUS.FINISHED, "the new shelf change survived")
  eq(q:conflictCount(), 0, "the old record's change did not become a question")
end)

check("keeping a removal reports the shelf and rating to put back", function()
  local q = removalQueue(7, 70, removalBase({ rating = 4 }))
  local api = fakeApi()
  api.findUserBookForRemoval = function()
    return removalRecord({ status_id = HARDCOVER.STATUS.FINISHED, rating = 4 })
  end
  q:flush(api, { user_id = 1 })
  local saved, outcome = q:resolve(7, "keep")
  eq(saved, true, "kept")
  eq(outcome and outcome.kind, "shelf", "outcome kind")
  eq(outcome and outcome.book_id, 7, "book")
  eq(outcome and outcome.user_book_id, 70, "record")
  eq(outcome and outcome.status_id, HARDCOVER.STATUS.FINISHED, "the shelf Hardcover has")
  eq(outcome and outcome.rating, 4, "the rating Hardcover has")
end)

check("a waiting conflict is a decision that can be answered through one interface", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 100, book_id = 1, edition_id = 3 })
  q:flush(cloudAhead(200), { user_id = 1 })
  local decisions = q:decisions(1)
  eq(#decisions, 1, "one decision")
  eq(decisions[1].kind, "page", "kind")
  eq(decisions[1].book_id, 1, "book")
  local by_book = q:decisionForBook(1, 1)
  eq(by_book and by_book.id, decisions[1].id, "found by book")
  eq(q:decisionForBook(2, 1), nil, "not another book's")
  eq(decisions[1].resolve("cloud"), true, "answered")
  eq(q:conflictCount(), 0, "no question left")
  eq(q:takeResumePage("/books/a.epub"), 200, "the answer took effect")
end)

check("waiting counts separate questions from failures", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 100, book_id = 1, edition_id = 3 })
  q:flush(cloudAhead(200), { user_id = 1 })
  q:enqueuePage("/books/b.epub", { mapped_page = 5, book_id = 2, edition_id = 3 })
  local counts = q:waitingCounts(1)
  eq(counts.decisions, 1, "the question")
  eq(counts.failed, 1, "work that has not had a turn")
  eq(counts.waiting, 0, "nothing held")
  -- a changed reading is a dependant; a refusal is a failed send
  q:get("/books/b.epub").held, q:get("/books/b.epub").reason = true, "reading_changed"
  local again = q:waitingCounts(1)
  eq(again.waiting, 1, "the changed reading")
  eq(again.failed, 0, "not a failure")
  q:get("/books/b.epub").reason = "refused"
  eq(q:waitingCounts(1).failed, 1, "a refusal")
end)

check("a shelf or removal barrier holds a rating but a page question does not", function()
  local q = newQueue()
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 1 })
  eq(q:bookBarrier(1, nil, 1, "rating"), "status", "a shelf change")
  eq(q:bookBarrier(1, nil, 1, "review"), nil, "a review can still go")
  q:queueRemove(1, 1, 50, "Dune", HARDCOVER.STATUS.READING, removalBase())
  eq(q:bookBarrier(1, nil, 1, "rating"), "remove", "a removal holds the rating")
  eq(q:bookBarrier(1, nil, 1, "review"), "remove", "and the review")
  -- a page question on a stable record does not stop either
  local q2 = newQueue()
  q2:enqueuePage("/books/a.epub", { mapped_page = 100, book_id = 1, edition_id = 3 })
  q2:flush(cloudAhead(200), { user_id = 1 })
  eq(q2:bookBarrier(1, nil, 1, "rating"), nil, "rating on a stable record")
  eq(q2:bookBarrier(1, nil, 1, "review"), nil, "review on a stable record")
  -- a reread question changes a shelf, so a rating waits for it
  q2:get("/books/a.epub").conflict = { kind = "reread", local_page = 100, cloud_status = HARDCOVER.STATUS.FINISHED }
  eq(q2:bookBarrier(1, nil, 1, "rating"), "reading", "a reread question")
end)

check("a removal keeps the work already waiting and does not send it before the delete", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 42, book_id = 7, edition_id = 3 })
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 7 })
  eq(q:queueRemove(1, 7, 70, "Dune", HARDCOVER.STATUS.READING, removalBase()), "queued")
  local entry = q:get(7)
  eq(entry.mapped_page, 42, "the page is kept with the removal")
  eq(entry.status_id, HARDCOVER.STATUS.FINISHED, "the status is kept")
  eq(entry.remove_seq, 2, "the boundary is where the removal was asked for")
  -- a page read after asking to remove waits behind it
  q:enqueuePage("/books/a.epub", { mapped_page = 50, book_id = 7, edition_id = 3 })
  eq(q:get(7).remove_seq, 2, "the boundary does not move")
  local api = fakeApi()
  api.findUserBookForRemoval = function() return removalRecord() end
  local sent, removed = 0, 0
  api.updatePage = function() sent = sent + 1 return nil end
  api.removeUserBook = function() removed = removed + 1 return { id = 70 } end
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  eq(sent, 0, "no page went out before the delete")
  eq(removed, 1, "the record was deleted")
end)

check("a single queued book keeps its one lookup and sends no batch", function()
  local q = newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 5, book_id = 1, edition_id = 3 })
  local api = fakeApi()
  local batched = false
  api.findUserBooks = function() batched = true return {} end
  eq(q:flush(api, { user_id = 1 }), true, "flush result")
  eq(batched, false, "no batch for one book")
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
