-- BUG: entries kept before timestamps were stored ({book_id, mapped_page} with no
-- page_updated_at, {book_id, status_id} with no status_updated_at) were sent but never
-- cleared (nil ~= 0), so every flush sent them again and the queue never drained.
--
-- Expected: such an entry is cleared once sent.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()
local HARDCOVER = require("hardcover/lib/constants/hardcover")

print("\n== entries without timestamps ==")

KB.check("an untimed page is cleared once sent", function()
  local q = KB.newQueue()
  q:pending()["/b/a.epub"] = { book_id = 7, mapped_page = 50 }
  local api = KB.fakeApi({ [7] = { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.READING,
    user_book_reads = { { id = 900, progress_pages = 10 } } } })
  q:flush(api, { user_id = 1 })
  KB.eq(q:hasPending("/b/a.epub"), false, "still queued")
end)

KB.check("an untimed status is cleared once sent", function()
  local q = KB.newQueue()
  q:pending()["/b/b.epub"] = { book_id = 8, status_id = HARDCOVER.STATUS.PAUSED }
  local api = KB.fakeApi({ [8] = { id = 508, book_id = 8, status_id = HARDCOVER.STATUS.READING, user_book_reads = {} } })
  q:flush(api, { user_id = 1 })
  KB.eq(q:hasPending("/b/b.epub"), false, "still queued")
  KB.eq(api:count("updateUserBookStatus"), 1, "status sends")
end)

KB.finish("untimed queue entries must drain")
