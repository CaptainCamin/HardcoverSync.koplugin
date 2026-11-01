-- BUG: a book's status changed offline from the reader and from the book details screen sat in
-- two queues (progress and shelf). On reconnect the progress queue went first and the shelf queue
-- second, so the older of the two changes could overwrite the newer.
--
-- Expected: a book's changes are one record, so the newest status wins whichever screen it was
-- made on, and a page waiting for the book stays.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()
local HARDCOVER = require("hardcover/lib/constants/hardcover")

local FILE = "/books/a.epub"

local function readerThen(details)
  local q = KB.newQueue()
  q:enqueueStatus(FILE, { book_id = 7, edition_id = 3, status_id = HARDCOVER.STATUS.READING })
  q:enqueuePage(FILE, { book_id = 7, mapped_page = 40 })
  details(q)
  return q
end

print("\n== two screens, one book ==")

KB.check("a status from the details screen after the reader's one replaces it, the page stays", function()
  local q = readerThen(function(queue)
    queue:enqueueStatus(7, { user_id = 1, book_id = 7, user_book_id = 500, status_id = HARDCOVER.STATUS.TO_READ })
  end)
  KB.eq(q:pendingCount(), 1, "one entry")
  KB.eq(q:get(7).status_id, HARDCOVER.STATUS.TO_READ, "status")
  KB.eq(q:get(FILE).mapped_page, 40, "page")
end)

KB.check("a status from the reader after the details screen's one replaces it", function()
  local q = KB.newQueue()
  q:enqueueStatus(7, { book_id = 7, status_id = HARDCOVER.STATUS.TO_READ })
  q:enqueueStatus(FILE, { book_id = 7, status_id = HARDCOVER.STATUS.READING })
  KB.eq(q:get(7).status_id, HARDCOVER.STATUS.READING, "status")
  KB.eq(q:pendingCount(), 1, "one entry")
end)

KB.check("a removal after the reader's status beats it, and the page goes with the record", function()
  local q = readerThen(function(queue)
    KB.eq(queue:queueRemove(1, 7, 500, "T", 2), "queued")
  end)
  KB.eq(q:get(7).remove, true, "removal kept")
  KB.eq(q:get(7).status_id, nil, "status")
  KB.eq(q:get(7).mapped_page, nil, "page")
end)

KB.finish("the newest status change wins across the reader and the details screen")
