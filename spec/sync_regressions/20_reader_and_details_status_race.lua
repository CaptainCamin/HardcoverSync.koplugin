-- BUG: a book's status changed offline from the reader (sync queue) and from the book
-- details screen (shelf queue) sat in two queues. On reconnect the sync queue went first
-- and the shelf queue second, so the older of the two changes could overwrite the newer.
--
-- Expected: before sending, the older of the two waiting status changes for a book is
-- dropped, so the newest one wins whichever screen it was made on. A page waiting in the
-- sync queue stays.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()
local ShelfQueue = require("hardcover/lib/shelf_queue")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

local FILE = "/books/a.epub"

local function setup(sync_at, shelf_at, shelf_kind)
  local q = KB.newQueue()
  local entry = q:enqueueStatus(FILE, { book_id = 7, edition_id = 3, status_id = HARDCOVER.STATUS.READING })
  entry.status_updated_at = sync_at
  q:enqueuePage(FILE, { book_id = 7, mapped_page = 40 })
  local sq = ShelfQueue:new { settings = KB.fakeSettings() }
  local op
  if shelf_kind == "remove" then
    sq:queueRemove(1, 7, 500, "T", 2)
    op = sq:get(7)
  else
    op = sq:queueStatus(1, 7, HARDCOVER.STATUS.TO_READ, { user_book_id = 500 })
  end
  op.at = shelf_at
  return q, sq
end

print("\n== two screens, two queues, one book ==")

KB.check("the reader's change is newer: the details screen's is dropped", function()
  local q, sq = setup(200, 100)
  sq:settleWith(q)
  KB.eq(sq:get(7), nil, "shelf change")
  KB.eq(q:get(FILE).status_id, HARDCOVER.STATUS.READING, "reader status")
end)

KB.check("the details screen's change is newer: the reader's status is dropped, its page stays", function()
  local q, sq = setup(100, 200)
  sq:settleWith(q)
  KB.eq(sq:get(7) ~= nil, true, "shelf change")
  KB.eq(q:get(FILE).status_id, nil, "reader status")
  KB.eq(q:get(FILE).mapped_page, 40, "reader page")
end)

KB.check("a newer removal also beats an older reader status", function()
  local q, sq = setup(100, 200, "remove")
  sq:settleWith(q)
  KB.eq(q:get(FILE).status_id, nil, "reader status")
  KB.eq(sq:get(7) ~= nil, true, "removal kept")
end)

KB.finish("the newest status change wins across the reader and the details screen")
