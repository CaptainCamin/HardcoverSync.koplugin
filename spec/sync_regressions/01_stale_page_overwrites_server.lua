-- BUG: a stale queued page replaces newer progress on the server.
--
-- Read to page 120 offline on this device (queued). Meanwhile the book is read
-- on to 200 on another device. When this device comes online, SyncQueue:_flushEntry
-- (hardcover/lib/sync_queue.lua, the `if flush_page then` block) calls
-- updatePage(read_id, ..., 120) without ever looking at the progress the server
-- already holds, so the server goes BACK to 120.
--
-- Expected: the server keeps 200 (the queued 120 is older news).
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
local SyncQueue = require("hardcover/lib/sync_queue")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

print("\n== stale queued page vs newer server progress ==")

local function serverAt(page)
  return {
    [7] = {
      id = 500, book_id = 7, status_id = HARDCOVER.STATUS.READING,
      user_book_reads = { { id = 900, progress_pages = page, edition_id = 3, started_at = "2026-01-01" } },
    },
  }
end

KB.check("replay does not move the server back from 200 to 120", function()
  local q = KB.newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 120, book_id = 7, edition_id = 3 })
  local api = KB.fakeApi(serverAt(200))
  q:flush(api, { user_id = 1 })
  KB.eq(api.shelf[7].user_book_reads[1].progress_pages, 200, "server progress after replay")
end)

KB.check("the open book's local state is not dragged back to the stale page either", function()
  -- Cache:cacheUserBook fetches the server book (200) then calls applyPending,
  -- which overwrites progress_pages with the queued 120 (sync_queue.lua applyPending).
  local q = KB.newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 120, book_id = 7, edition_id = 3 })
  local status = serverAt(200)[7]
  q:applyPending("/books/a.epub", status)
  KB.eq(status.user_book_reads[1].progress_pages, 200, "progress shown for the book")
end)

KB.finish("stale queued page must not overwrite newer server progress")
