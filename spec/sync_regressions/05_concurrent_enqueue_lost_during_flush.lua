-- BUG: progress queued while a flush is in flight is erased when the flush ends.
--
-- Flush requests run through Trapper (dismissableRunInSubprocess), which yields
-- to the UI loop, so page turns, suspend and status changes keep running while a
-- flush waits on the network. SyncQueue:_flushEntry holds `entry` (the live
-- table) across those calls and finishes with `self:clear(filepath)`
-- (hardcover/lib/sync_queue.lua), which deletes the whole entry -- including a
-- newer mapped_page / status_id that was enqueued after the flush read it.
-- The same applies to the `entry.status_id = nil` it does after a status send.
--
-- Expected: only what was actually sent is cleared; the newer value stays queued.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

print("\n== enqueue during a flush ==")

local function shelf()
  return { [7] = { id = 500, book_id = 7, status_id = HARDCOVER.STATUS.READING,
    user_book_reads = { { id = 900, progress_pages = 10, edition_id = 3 } } } }
end

KB.check("a page queued while the page request is in flight survives", function()
  local q = KB.newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 120, book_id = 7, edition_id = 3 })
  local api = KB.fakeApi(shelf())
  local real = api.updatePage
  api.page_hook = nil
  api.updatePage = function(self, read_id, ed, page, started)
    -- the user turns to page 150 and the plugin enqueues it (e.g. a failed
    -- online update or the network dropping) while this request is outstanding
    q:enqueuePage("/books/a.epub", { mapped_page = 150, book_id = 7, edition_id = 3 })
    return real(self, read_id, ed, page, started)
  end
  q:flush(api, { user_id = 1 })
  local entry = q:get("/books/a.epub")
  KB.eq(entry ~= nil and entry.mapped_page or nil, 150, "newer queued page after the flush")
end)

KB.check("a status queued while the status request is in flight survives", function()
  local q = KB.newQueue()
  q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.READING, book_id = 7, edition_id = 3 })
  local api = KB.fakeApi(shelf())
  local real = api.updateUserBook
  api.updateUserBook = function(self, book_id, status_id, ...)
    -- the user marks it Finished while the first status is being sent
    q:enqueueStatus("/books/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 7 })
    return real(self, book_id, status_id, ...)
  end
  q:flush(api, { user_id = 1 })
  local entry = q:get("/books/a.epub")
  KB.eq(entry ~= nil and entry.status_id or nil, HARDCOVER.STATUS.FINISHED, "newer queued status after the flush")
end)

KB.finish("a flush must not erase changes queued while it was running")
