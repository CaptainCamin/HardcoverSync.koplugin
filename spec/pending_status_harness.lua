-- The status changes waiting in the progress queue and the shelf queue, read as one.
--
-- Run with:  lua spec/pending_status_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local PendingStatus = require("hardcover/lib/pending_status")
local SyncQueue = require("hardcover/lib/sync_queue")
local ShelfQueue = require("hardcover/lib/shelf_queue")

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

check("changes from both queues are listed, the newer winning for a book in both", function()
  local sync, shelf = SyncQueue:new { settings = settings() }, ShelfQueue:new { settings = settings() }
  sync:enqueueStatus("/a.epub", { user_id = 1, book_id = 1, title = "A", status_id = 3 })
  sync:get("/a.epub").status_updated_at = 100
  sync:enqueueStatus("/b.epub", { user_id = 1, book_id = 2, title = "B", status_id = 2 })
  sync:get("/b.epub").status_updated_at = 100
  shelf:queueStatus(1, 1, 5, { title = "A" })
  shelf:get(1).at = 200
  shelf:queueStatus(1, 3, 1, { title = "C" })
  shelf:queueRemove(1, 4, 44, "D")
  local list = PendingStatus.list(sync, shelf, 1)
  eq(#list, 4)
  eq(list[1].book_id, 1); eq(list[1].status_id, 5, "the newer change wins")
  eq(list[2].book_id, 2); eq(list[2].status_id, 2); eq(list[2].at, 100)
  eq(list[4].kind, "remove")
  eq(PendingStatus.get(sync, shelf, 2, 1).title, "B")
  eq(PendingStatus.get(sync, shelf, 99, 1), nil)
end)

check("another account's change is not listed", function()
  local sync = SyncQueue:new { settings = settings() }
  sync:enqueueStatus("/a.epub", { user_id = 2, book_id = 1, status_id = 3 })
  eq(#PendingStatus.list(sync, nil, 1), 0)
  eq(#PendingStatus.list(sync, nil, 2), 1)
end)

print(string.format("\n  %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
