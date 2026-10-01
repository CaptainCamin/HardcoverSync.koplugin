-- Proves the offline state layer reconstructs a book correctly with no network.
--
-- This is the half of feature 1 that the queue tests cannot reach. The queue
-- holds what must be *sent*; this holds what the UI must *show* while offline.
-- If hydration is wrong the user opens a book they have been reading and the
-- plugin either loses their place or reports a page they never turned to.
--
-- Run with:  lua spec/cache_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

-- Only the boundaries. cache.lua itself is never stubbed.
local support = dofile(PLUGIN .. "/spec/support.lua")

support.preload_ui_stubs()
support.preload_http_stubs()
support.preload_json(PLUGIN)

package.preload["ui/network/manager"] = function()
  return {
    -- deliberately offline: this harness exists to prove the offline path
    isOnline = function() return false end,
    isConnected = function() return false end,
    runWhenOnline = function(_, fn) fn() end,
  }
end

-- hardcover_api pulls in KOReader's FFI helpers at load time. Stock Lua has no
-- FFI, so provide the handful the module touches.
package.preload["ffi/util"] = function()
  local util = {}
  util.template = function(t) return t end
  setmetatable(util, {
    __call = function(_, s) return tostring(s) end,
  })
  return util
end
package.preload["ffi"] = function() return {} end
package.preload["ffi/pointer"] = function() return {} end
package.preload["ffi/utf8"] = function() return { char = string.char, len = string.len } end
package.preload["blitbuffer"] = function() return {} end
package.preload["ui/trapper"] = function()
  return {
    -- the API runs long calls in a subprocess; a harness must never fork
    dismissableRunInSubprocess = function(_, fn) return true, fn end,
    runInSubprocess = function(_, fn) return true, fn end,
  }
end
-- hardcover_api does table.concat(VERSION, "."), so this must be a table of
-- version parts. Returning a string makes the require fail with a confusing
-- "invalid value (nil) at index 1 in table for 'concat'".
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end

local HARDCOVER = require("hardcover/lib/constants/hardcover")
for _, name in ipairs({ "TO_READ", "READING", "FINISHED", "DNF" }) do
  if HARDCOVER.STATUS[name] == nil then
    error("HARDCOVER.STATUS." .. name .. " does not exist -- fix the harness, not the plugin")
  end
end

local Cache = require("hardcover/lib/cache")
local SyncQueue = require("hardcover/lib/sync_queue")

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

-- A settings double covering the per-book surface cache.lua uses.
local function fakeSettings(snapshot)
  local books = {}
  local saved = {}
  return {
    getFilePath = function() return "/books/current.epub" end,
    readBookSetting = function(_, filename, key)
      local b = books[filename]
      return b and b[key] or nil
    end,
    writeBookSetting = function(_, filename, key, value)
      books[filename] = books[filename] or {}
      books[filename][key] = value
    end,
    saveBookSnapshot = function(_, filename, user_book) saved[filename] = user_book end,
    bookStatusFromSnapshot = function(_, filename) return snapshot end,
    books = books,
    snapshots = saved,
  }
end

local function newCache(opts)
  opts = opts or {}
  local settings = opts.settings or fakeSettings(opts.snapshot)
  local queue = opts.queue
  return Cache:new {
    settings = settings,
    state = opts.state or {},
    sync_queue = queue,
    api = opts.api,
  }, settings
end

-- ---------------------------------------------------------------- hydration

print("\n== rebuilding a book with no network ==")

check("a full snapshot hydrates the status", function()
  local snapshot = {
    id = 501, book_id = 9001, status_id = HARDCOVER.STATUS.READING,
    user_book_reads = { { id = 77, progress_pages = 120, edition_id = 3 } },
  }
  local cache = newCache { snapshot = snapshot }
  eq(cache:hydrateBookStatus("/books/a.epub"), true, "hydrate result")
  eq(cache.state.book_status.status_id, HARDCOVER.STATUS.READING, "status")
  eq(cache.state.book_status.user_book_reads[1].progress_pages, 120, "progress")
end)

check("a book with only per-book settings still hydrates", function()
  -- Older installs have settings but no snapshot. Losing the book entirely here
  -- would mean a previously-synced book becomes untrackable offline.
  local settings = fakeSettings(nil)
  settings:writeBookSetting("/books/a.epub", "book_id", 9001)
  settings:writeBookSetting("/books/a.epub", "edition_id", 3)
  settings:writeBookSetting("/books/a.epub", "status_id", HARDCOVER.STATUS.READING)
  local cache = newCache { settings = settings }
  eq(cache:hydrateBookStatus("/books/a.epub"), true, "hydrate result")
  eq(cache.state.book_status.book_id, 9001, "book id")
  eq(cache.state.book_status.edition_id, 3, "edition id")
end)

check("a snapshot takes precedence over loose settings", function()
  -- The snapshot is the newer truth; a stale status_id in settings would
  -- otherwise resurrect a status the user already changed.
  local settings = fakeSettings({ id = 501, book_id = 9001, status_id = HARDCOVER.STATUS.READING })
  settings:writeBookSetting("/books/a.epub", "status_id", HARDCOVER.STATUS.TO_READ)
  local cache = newCache { settings = settings }
  cache:hydrateBookStatus("/books/a.epub")
  eq(cache.state.book_status.status_id, HARDCOVER.STATUS.READING, "status from the snapshot")
end)

check("an unknown book reports failure rather than an empty status", function()
  -- Returning true here would let the caller start tracking a book it has no
  -- id for, producing updates the API cannot accept.
  local cache = newCache { settings = fakeSettings(nil) }
  eq(cache:hydrateBookStatus("/books/never-seen.epub"), false, "hydrate result")
end)

check("no filename at all is handled", function()
  local settings = fakeSettings(nil)
  settings.getFilePath = function() return nil end
  local cache = newCache { settings = settings }
  eq(cache:hydrateBookStatus(nil), false, "hydrate result")
end)

check("a queued page is layered over the snapshot", function()
  -- This is the offline promise in one assertion: the user reads to page 340
  -- with no network, and the UI reflects 340 immediately rather than the stale
  -- 120 from the last sync.
  local settings = fakeSettings {
    id = 501, book_id = 9001, status_id = HARDCOVER.STATUS.READING,
    user_book_reads = { { id = 77, progress_pages = 120, edition_id = 3 } },
  }
  -- The queue's settings must hand back the SAME table on every read, the way
  -- real LuaSettings does. Returning a fresh {} each call (an earlier version
  -- here) means every write lands in a throwaway table, so the queued page
  -- silently vanishes and hydration falls back to the stale snapshot value.
  local store = {}
  local queue = SyncQueue:new {
    settings = {
      readSetting = function(_, key) return store[key] end,
      saveSetting = function(_, key, value) store[key] = value end,
      flush = function() end,
    },
  }
  queue:enqueuePage("/books/a.epub", { mapped_page = 340, book_id = 9001, edition_id = 3 })
  local cache = newCache { settings = settings, queue = queue }
  cache:hydrateBookStatus("/books/a.epub")
  eq(cache.state.book_status.user_book_reads[1].progress_pages, 340, "progress after hydration")
end)

check("hydration works with no queue attached", function()
  -- The queue is optional; a nil queue must not take hydration down with it.
  local cache = newCache { snapshot = { id = 1, book_id = 2, status_id = HARDCOVER.STATUS.READING } }
  eq(cache:hydrateBookStatus("/books/a.epub"), true, "hydrate result")
end)

-- ---------------------------------------------------------------- local page tracking

print("\n== recording progress with no network ==")

check("a page turn updates the existing read", function()
  local cache = newCache()
  cache.state.book_status = {
    id = 501, book_id = 9001, status_id = HARDCOVER.STATUS.READING,
    user_book_reads = { { id = 77, progress_pages = 10, edition_id = 3 } },
  }
  cache:applyLocalPage(250, 3)
  eq(cache.state.book_status.user_book_reads[1].progress_pages, 250, "progress")
  eq(cache.state.book_status.user_book_reads[1].id, 77, "the read id is kept")
end)

check("a first page turn creates a read", function()
  local cache = newCache()
  cache.state.book_status = { id = 501, book_id = 9001 }
  cache:applyLocalPage(15, 3, "2026-01-01", 88)
  eq(#cache.state.book_status.user_book_reads, 1, "read count")
  eq(cache.state.book_status.user_book_reads[1].progress_pages, 15, "progress")
  eq(cache.state.book_status.user_book_reads[1].id, 88, "read id")
end)

check("tracking a page implies the book is being read", function()
  -- Without this the plugin would queue a page for a book sitting on the shelf
  -- as Want to Read, which then never flushes.
  local cache = newCache()
  cache.state.book_status = { id = 501, book_id = 9001 }
  cache:applyLocalPage(15, 3)
  eq(cache.state.book_status.status_id, HARDCOVER.STATUS.READING, "status")
end)

check("an existing status is not overwritten by a page turn", function()
  -- Reading a book the user explicitly marked Read should not drag it back to
  -- Currently Reading behind their back.
  local cache = newCache()
  cache.state.book_status = { id = 501, book_id = 9001, status_id = HARDCOVER.STATUS.FINISHED }
  cache:applyLocalPage(300, 3)
  eq(cache.state.book_status.status_id, HARDCOVER.STATUS.FINISHED, "status")
end)

check("page zero is recorded rather than treated as absent", function()
  -- A falsy check loses the very first page of every book.
  local cache = newCache()
  cache.state.book_status = { id = 501, book_id = 9001 }
  cache:applyLocalPage(0, 3, "2026-01-01", 88)
  eq(cache.state.book_status.user_book_reads[1].progress_pages, 0, "progress")
end)

check("tracking with no status at all does not crash", function()
  local cache = newCache()
  cache.state.book_status = nil
  cache:applyLocalPage(20, 3)
  if cache.state.book_status == nil then error("no status was created") end
end)

check("the edition falls back to the book's when not supplied", function()
  local cache = newCache()
  cache.state.book_status = { id = 501, book_id = 9001, edition_id = 3 }
  cache:applyLocalPage(10, nil, "2026-01-01", 88)
  eq(cache.state.book_status.user_book_reads[1].edition_id, 3, "edition")
end)

-- ---------------------------------------------------------------- local status

print("\n== changing status with no network ==")

check("a status change is applied locally", function()
  local cache = newCache()
  cache:applyLocalStatus("/books/a.epub", HARDCOVER.STATUS.FINISHED, 2)
  eq(cache.state.book_status.status_id, HARDCOVER.STATUS.FINISHED, "status")
  eq(cache.state.book_status.privacy_setting_id, 2, "privacy")
end)

check("book and edition are filled in from settings", function()
  -- Without these the eventual API call has no book to attach the status to.
  local settings = fakeSettings(nil)
  settings:writeBookSetting("/books/a.epub", "book_id", 9001)
  settings:writeBookSetting("/books/a.epub", "edition_id", 3)
  local cache = newCache { settings = settings }
  cache:applyLocalStatus("/books/a.epub", HARDCOVER.STATUS.READING)
  eq(cache.state.book_status.book_id, 9001, "book id")
  eq(cache.state.book_status.edition_id, 3, "edition id")
end)

check("an existing privacy setting is not cleared by a status change", function()
  local cache = newCache()
  cache.state.book_status = { id = 501, book_id = 9001, privacy_setting_id = 3 }
  cache:applyLocalStatus("/books/a.epub", HARDCOVER.STATUS.READING, nil)
  eq(cache.state.book_status.privacy_setting_id, 3, "privacy")
end)

check("an explicit privacy setting does replace the old one", function()
  local cache = newCache()
  cache.state.book_status = { id = 501, book_id = 9001, privacy_setting_id = 3 }
  cache:applyLocalStatus("/books/a.epub", HARDCOVER.STATUS.READING, 1)
  eq(cache.state.book_status.privacy_setting_id, 1, "privacy")
end)

-- ---------------------------------------------------------------- snapshots

print("\n== writing state back for next time ==")

check("a snapshot is written when one is saved", function()
  local settings = fakeSettings(nil)
  local cache = newCache { settings = settings }
  cache:saveSnapshot("/books/a.epub", { id = 1, book_id = 2 })
  if settings.snapshots["/books/a.epub"] == nil then error("no snapshot written") end
end)

check("saving with no filename is a no-op", function()
  -- A nil filename here would otherwise build a settings key of "nil" and
  -- corrupt an unrelated book's entry.
  local settings = fakeSettings(nil)
  local cache = newCache { settings = settings }
  cache:saveSnapshot(nil, { id = 1 })
  eq(next(settings.snapshots), nil, "snapshots written")
end)

print("")
print(string.format("  %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)