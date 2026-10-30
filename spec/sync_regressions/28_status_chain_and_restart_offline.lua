-- BUG: several status changes made offline were sent as only the last one.
--
-- 1. Paused (or Want to Read) -> Currently Reading -> Read offline sent just "Read": the book never
--    started again, so Hardcover's journal had no "started" entry for it.
-- 2. A book finished and then started over before anything was sent asked "which page?" (the new
--    read's page 0 was sent first, against the old read's page) and the finish was never written.
--
-- Expected: Currently Reading is sent first when the book passed through it; a finish goes before
-- the new read opens.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local S = HARDCOVER.STATUS
local FILE = "/b/a.epub"

local function server(user_book)
  local cur, calls = user_book, {}
  local api = {}
  function api:findUserBook() return cur end
  function api:updateUserBook(_, status) calls[#calls + 1] = "create " .. status; cur = { id = 9, status_id = status, user_book_reads = {} }; return cur end
  function api:updateUserBookStatus(_, status) calls[#calls + 1] = "status " .. status; cur.status_id = status; return cur end
  function api:updatePage(_, _, page) calls[#calls + 1] = "page " .. page; return cur end
  function api:createRead(_, _, page) calls[#calls + 1] = "read " .. page; return cur end
  function api:setFinishedDate() return cur end
  return api, calls
end

local function paused() return { id = 9, status_id = S.PAUSED, user_book_reads = { { id = 5, progress_pages = 10 } } } end

print("\n== Currently Reading on the way to another status ==")

KB.check("Paused -> Reading -> page -> Read sends Reading first", function()
  local q = KB.newQueue()
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.READING, from_status_id = S.PAUSED })
  q:enqueuePage(FILE, { book_id = 1, mapped_page = 100 })
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.FINISHED })
  local api, calls = server(paused())
  q:flush(api, { user_id = 1 })
  KB.eq(table.concat(calls, ","), "status 2,page 100,status 3", "calls")
  KB.eq(q:pendingCount(), 0, "left in queue")
end)

KB.check("a book new to the library is created as Reading, then Read", function()
  local q = KB.newQueue()
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.READING })
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.FINISHED })
  local api, calls = server(nil)
  q:flush(api, { user_id = 1 })
  KB.eq(table.concat(calls, ","), "create 2,status 3", "calls")
end)

KB.check("a status that never passed through Reading sends no extra step", function()
  local q = KB.newQueue()
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.TO_READ })
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.FINISHED })
  local api, calls = server(paused())
  q:flush(api, { user_id = 1 })
  KB.eq(table.concat(calls, ","), "status 3", "calls")
end)

KB.check("a book already on Currently Reading is not set to it again", function()
  local q = KB.newQueue()
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.READING })
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.FINISHED })
  local ub = paused(); ub.status_id = S.READING
  local api, calls = server(ub)
  q:flush(api, { user_id = 1 })
  KB.eq(table.concat(calls, ","), "status 3", "calls")
end)

print("\n== finished, then started over, before anything was sent ==")

KB.check("the finish is sent, then the new read opens, without a page question", function()
  local q = KB.newQueue()
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.FINISHED, from_status_id = S.READING })
  q:startReread(FILE, { book_id = 1, mapped_page = 0 })
  local ub = { id = 9, status_id = S.READING, user_book_reads = { { id = 5, progress_pages = 300 } } }
  local api, calls = server(ub)
  q:flush(api, { user_id = 1 })
  KB.eq(table.concat(calls, ","), "status 3,read 0,status 2", "calls")
  KB.eq(q:conflictCount(), 0, "questions")
  KB.eq(q:pendingCount(), 0, "left in queue")
end)

KB.check("while it waits, the book started over is on Currently Reading, not Finished", function()
  local q = KB.newQueue()
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.FINISHED, from_status_id = S.READING })
  q:startReread(FILE, { book_id = 1, mapped_page = 0 })
  KB.eq(q:statusOf(FILE), S.READING, "status")
  KB.eq(q:applyPending(FILE, { status_id = S.READING }).status_id, S.READING, "shown")
  local lone = KB.newQueue()
  lone:enqueueStatus(FILE, { book_id = 1, status_id = S.FINISHED })
  KB.eq(lone:statusOf(FILE), S.FINISHED, "a finish alone stays finished")
end)

KB.finish("a status chain must keep Reading, and a finish must precede a restart")
