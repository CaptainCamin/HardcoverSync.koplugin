-- BUG: two permanently failing entries stop every other book from ever syncing.
--
-- SyncQueue:flush (hardcover/lib/sync_queue.lua) gives up after
-- MAX_CONSECUTIVE_FAILURES = 2 back-to-back failures, and it walks the files in
-- sorted order. A book that can never succeed (deleted on Hardcover, edition
-- rejected, entry with no book_id) therefore sits at the front of the queue
-- forever; with two of them, the entries sorted after them are never even tried.
-- Nothing ever removes a dead entry, so the queue never drains.
--
-- Expected: healthy entries behind the bad ones still sync (e.g. skip entries
-- that failed the same way on earlier flushes, or stop only on errors that mean
-- "network/token down", not on per-book rejections).
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

print("\n== dead entries at the front of the queue ==")

KB.check("a healthy book behind two permanently bad ones still syncs", function()
  local q = KB.newQueue()
  q:enqueuePage("/books/a_dead.epub", { mapped_page = 1, book_id = 1, edition_id = 3 })
  q:enqueuePage("/books/b_dead.epub", { mapped_page = 2, book_id = 2, edition_id = 3 })
  q:enqueuePage("/books/c_ok.epub", { mapped_page = 3, book_id = 3, edition_id = 3 })
  local api = KB.fakeApi({ [3] = { id = 503, book_id = 3, status_id = HARDCOVER.STATUS.READING,
    user_book_reads = { { id = 903, progress_pages = 0, edition_id = 3 } } } })
  -- books 1 and 2 are gone server-side: lookups find nothing and the insert is rejected
  api.update_hook = function(book_id, status_id)
    if book_id == 1 or book_id == 2 then return nil, { status = 200, errors = { { message = "book not found" } } } end
    return api.shelf[book_id]
  end
  for _ = 1, 5 do q:flush(api, { user_id = 1 }) end -- five flushes, e.g. five reconnects
  KB.eq(q:hasPending("/books/c_ok.epub"), false, "healthy entry still pending after 5 flushes")
end)

KB.finish("dead queue entries must not starve the healthy ones")
