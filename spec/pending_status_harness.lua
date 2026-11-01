-- The status changes waiting in the progress queue, read as rows.
--
-- Run with:  lua spec/pending_status_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local PendingStatus = require("hardcover/lib/pending_status")
local SyncQueue = require("hardcover/lib/sync_queue")

local results = { passed = 0, failed = 0 }
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then results.passed = results.passed + 1 print("  [ok  ] " .. name)
  else results.failed = results.failed + 1 print("  [FAIL] " .. name .. "\n         " .. tostring(err)) end
end
local function eq(a, b, label)
  if a ~= b then error((label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local function settings()
  local store = {}
  return { readSetting = function(_, k) return store[k] end,
    saveSetting = function(_, k, v) store[k] = v end, flush = function() end }
end

check("changes from the reader and from details are listed by book, the newest winning for a book", function()
  local sync = SyncQueue:new { settings = settings() }
  sync:enqueueStatus("/a.epub", { user_id = 1, book_id = 1, title = "A", status_id = 3 })
  sync:get(1).status_updated_at = 100
  sync:enqueueStatus("/b.epub", { user_id = 1, book_id = 2, title = "B", status_id = 2 })
  sync:get(2).status_updated_at = 100
  sync:enqueueStatus(1, { user_id = 1, book_id = 1, title = "A", status_id = 5 })
  sync:get(1).status_updated_at = 200
  sync:enqueueStatus(3, { user_id = 1, book_id = 3, title = "C", status_id = 1 })
  sync:queueRemove(1, 4, 44, "D")
  local list = PendingStatus.list(sync, 1)
  eq(#list, 4)
  eq(list[1].book_id, 1); eq(list[1].status_id, 5, "the newer change wins")
  eq(list[2].book_id, 2); eq(list[2].status_id, 2); eq(list[2].at, 100)
  eq(list[4].kind, "remove")
  eq(list[4].entry, sync:get(4), "the entry is there for cancelling")
  eq(PendingStatus.get(sync, 2, 1).title, "B")
  eq(PendingStatus.get(sync, 99, 1), nil)
end)

check("another account's change is not listed", function()
  local sync = SyncQueue:new { settings = settings() }
  sync:enqueueStatus("/a.epub", { user_id = 2, book_id = 1, status_id = 3 })
  eq(#PendingStatus.list(sync, 1), 0)
  eq(#PendingStatus.list(sync, 2), 1)
  eq(PendingStatus.get(sync, 1, 1), nil)
end)

check("pages waiting are listed one for each day read, newest last, for the signed-in user", function()
  local sync = SyncQueue:new { settings = settings() }
  sync:enqueuePage("/a.epub", { user_id = 1, book_id = 1, title = "A", mapped_page = 10 })
  local entry = sync:get(1)
  entry.page_days = {
    { day = "2026-10-29", page = 10, at = 100 }, { day = "2026-10-30", page = 40, at = 200 },
  }
  entry.mapped_page = 40
  sync:enqueuePage("/b.epub", { user_id = 2, book_id = 2, title = "B", mapped_page = 5 })
  sync:enqueueStatus("/c.epub", { user_id = 1, book_id = 3, title = "C", status_id = 2 })
  local pages = PendingStatus.pages(sync, 1)
  eq(#pages, 2, "another account's and a status with no page are left out")
  eq(pages[1].page, 10); eq(pages[1].day, "2026-10-29")
  eq(pages[2].page, 40); eq(pages[2].at, 200); eq(pages[2].kind, "progress"); eq(pages[2].title, "A")
  eq(#PendingStatus.pages(sync, 2), 1)
end)

check("a page saved before the days were kept is listed once, by its own time", function()
  local sync = SyncQueue:new { settings = settings() }
  sync:enqueuePage("/a.epub", { user_id = 1, book_id = 1, mapped_page = 10 })
  local entry = sync:get(1)
  entry.page_days, entry.page_updated_at = nil, 777
  local pages = PendingStatus.pages(sync, 1)
  eq(#pages, 1); eq(pages[1].page, 10); eq(pages[1].at, 777)
end)

print(string.format("\n  %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
