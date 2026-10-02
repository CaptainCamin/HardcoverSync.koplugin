-- BUG (low): one malformed entry in hardcoversync_queue.lua makes every queue
-- check throw, for good.
--
-- A file that fails to load is replaced with an empty queue by LuaSettings, so
-- truncation is survivable. A file that loads but holds the wrong shape (a
-- hand edit, a sync tool merging files, a future format change that an older
-- plugin then reads) is not: SyncQueue:isEmpty indexes the entry without a type
-- check, so hasPending / pendingCount / filepaths raise "attempt to index a
-- number value". Those are called from onDocumentClose, onSuspend, onResume,
-- onNetworkConnected and the Sync menu item's enabled_func, so every one of
-- them raises on every call, and nothing ever clears the bad entry (Discard is
-- reached through pendingCount, which raises too).
--
-- Expected: a malformed entry (or a non-table `pending`) is ignored or dropped.
local KB = dofile((arg[1] or ".") .. "/spec/known_bugs/lib.lua")
local SyncQueue = require("hardcover/lib/sync_queue")

print("\n== malformed queue contents ==")

KB.check("a non-table entry does not break hasPending / pendingCount / clearAll", function()
  local settings = KB.fakeSettings()
  settings.store.pending = { ["/books/a.epub"] = 5, ["/books/b.epub"] = { mapped_page = 3, book_id = 1 } }
  local q = SyncQueue:new { settings = settings }
  local ok, err = pcall(function()
    KB.eq(q:pendingCount(), 1, "pendingCount")
    KB.eq(q:hasPending(), true, "hasPending")
    q:clearAll()
  end)
  if not ok then error(err, 0) end
end)

KB.check("a non-table `pending` value does not break the queue", function()
  local settings = KB.fakeSettings()
  settings.store.pending = "garbage"
  local q = SyncQueue:new { settings = settings }
  local ok, err = pcall(function() return q:hasPending() end)
  if not ok then error(err, 0) end
end)

KB.finish("malformed queue contents must not raise from every queue check")
