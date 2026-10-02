-- BUG: the page read before a queued "Finished" status is thrown away.
--
-- Offline, the reader reaches the end of the book: the last page is queued, then
-- onEndOfBook queues status FINISHED. The entry holds both
-- ({mapped_page = 300, status_id = FINISHED}). SyncQueue:shouldFlushPage
-- (hardcover/lib/sync_queue.lua) returns false whenever status_id ~= READING, so
-- the replay sets the status and then drops the page without sending it
-- (`flush_page` is false, then `self:clear(filepath)`). The server is left with
-- the last progress it happened to see (here 40) on a book marked Read.
-- The online path sends the page first and the status after, so the two paths
-- disagree.
--
-- Expected: the page that preceded the status change reaches the server
-- (the entry records page_updated_at / status_updated_at, so order is known).
local KB = dofile((arg[1] or ".") .. "/spec/known_bugs/lib.lua")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

print("\n== page then Finished, replayed ==")

KB.check("the final page is sent before the book is marked Finished", function()
  local q = KB.newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 300, book_id = 7, edition_id = 3 })
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 7 })
  local api = KB.fakeApi({ [7] = { id = 500, book_id = 7, status_id = HARDCOVER.STATUS.READING,
    user_book_reads = { { id = 900, progress_pages = 40, edition_id = 3 } } } })
  q:flush(api, { user_id = 1 })
  KB.eq(api.shelf[7].status_id, HARDCOVER.STATUS.FINISHED, "status")
  KB.eq(api.shelf[7].user_book_reads[1].progress_pages, 300, "progress left on the finished read")
end)

KB.finish("queued final page must not be dropped when a Finished status is queued after it")
