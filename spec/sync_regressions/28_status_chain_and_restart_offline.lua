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

local function atTime(at, fn)
  local real = os.time
  os.time = function(t) if t then return real(t) end return at end
  local ok, err = pcall(fn)
  os.time = real
  if not ok then error(err, 0) end
end

local function server(user_book)
  local cur, calls = user_book, {}
  local api = { status_times = {} }
  function api:findUserBook() return cur end
  function api:updateUserBook(_, status) calls[#calls + 1] = "create " .. status; cur = { id = 9, status_id = status, user_book_reads = {} }; return cur end
  function api:updateUserBookStatus(_, status, _, at)
    calls[#calls + 1] = "status " .. status
    self.status_times[status] = at
    if status == S.READING and (cur.status_id == S.FINISHED or cur.status_id == S.DNF) then
      cur.user_book_reads[#cur.user_book_reads + 1] = { id = 5 + #cur.user_book_reads }
    elseif status == S.FINISHED and #cur.user_book_reads > 0 then
      cur.user_book_reads[#cur.user_book_reads].finished_at = "finished"
    end
    cur.status_id = status
    return cur
  end
  function api:updatePage(id, _, page, started_at)
    -- Correcting the date of an empty auto-created read is not a progress checkpoint.
    if page ~= nil then calls[#calls + 1] = "page " .. page end
    for _, read in ipairs(cur.user_book_reads) do
      if read.id == id then read.progress_pages, read.started_at = page, started_at end
    end
    return cur
  end
  function api:createRead(_, _, page)
    calls[#calls + 1] = "read " .. page
    cur.user_book_reads[#cur.user_book_reads + 1] = { id = 5, progress_pages = page }
    return cur
  end
  function api:setFinishedDate() return cur end
  function api:updateReadDates(id, dates)
    for _, read in ipairs(cur.user_book_reads) do
      if read.id == id then for field, value in pairs(dates) do read[field] = value end end
    end
    return cur
  end
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

KB.check("offline start, a few pages, then pause survives a restart and sync", function()
  local q, settings = KB.newQueue()
  local started = os.time() - 2 * 86400
  atTime(started, function()
    q:enqueueStatus(FILE, { book_id = 1, status_id = S.READING, from_status_id = S.TO_READ })
  end)
  q:enqueuePage(FILE, { book_id = 1, mapped_page = 7 })
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.PAUSED })
  local paused_at = q:get(FILE).status_updated_at
  q = require("hardcover/lib/sync_queue"):new { settings = settings }
  local api, calls = server({ id = 9, status_id = S.TO_READ, user_book_reads = {} })
  KB.eq(q:flush(api, { user_id = 1 }), true, "flush")
  KB.eq(table.concat(calls, ","), "status 2,read 7,status 4", "calls")
  KB.eq(api.status_times[S.READING], started, "the start keeps its original time")
  KB.eq(api.status_times[S.PAUSED], paused_at, "the pause keeps its own time")
  KB.eq(q:pendingCount(), 0, "left in queue")
end)

KB.check("statuses that never passed through Reading are preserved without inventing a start", function()
  local q = KB.newQueue()
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.TO_READ })
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.FINISHED })
  local api, calls = server(paused())
  q:flush(api, { user_id = 1 })
  KB.eq(table.concat(calls, ","), "status 1,status 3", "calls")
end)

KB.check("start, pause, resume and finish in the same second preserve every transition and one read", function()
  local q, settings = KB.newQueue()
  local ub = { id = 9, status_id = S.TO_READ, user_book_reads = {} }
  atTime(1793442600, function()
    q:enqueueStatus(FILE, { book_id = 1, status_id = S.READING, from_status_id = S.TO_READ })
    q:enqueuePage(FILE, { book_id = 1, mapped_page = 7 })
    q:enqueueStatus(FILE, { book_id = 1, status_id = S.PAUSED })
    q:enqueueStatus(FILE, { book_id = 1, status_id = S.READING })
    q:enqueuePage(FILE, { book_id = 1, mapped_page = 43 })
    q:enqueueStatus(FILE, { book_id = 1, status_id = S.FINISHED })
  end)
  q = require("hardcover/lib/sync_queue"):new { settings = settings }
  local api, calls = server(ub)
  KB.eq(q:statusOf(FILE), S.FINISHED, "local shelf")
  KB.eq(q:flush(api, { user_id = 1 }), true, "flush")
  KB.eq(table.concat(calls, ","), "status 2,read 7,status 4,status 2,page 43,status 3", "ordered actions")
  KB.eq(#ub.user_book_reads, 1, "a resume is not a new read")
  KB.eq(ub.user_book_reads[1].progress_pages, 43, "final progress")
  KB.eq(ub.status_id, S.FINISHED, "server shelf")
  KB.eq(q:hasPending(), false, "queue drained")
end)

KB.check("a lost pause response resumes after that pause without replaying the start", function()
  local q, settings = KB.newQueue()
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.READING, from_status_id = S.TO_READ })
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.PAUSED })
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.READING })
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.FINISHED })
  local ub = { id = 9, status_id = S.TO_READ, user_book_reads = {} }
  local api, calls = server(ub)
  local update = api.updateUserBookStatus
  api.updateUserBookStatus = function(self, id, status, privacy, at)
    local result = update(self, id, status, privacy, at)
    if status == S.PAUSED then return nil, { status = 503 } end
    return result
  end
  KB.eq(q:flush(api, { user_id = 1 }), false, "interrupted flush")
  KB.eq(table.concat(calls, ","), "status 2,status 4", "stop at the lost response")
  q = require("hardcover/lib/sync_queue"):new { settings = settings }
  api, calls = server(ub)
  KB.eq(q:flush(api, { user_id = 1 }), true, "retry")
  KB.eq(table.concat(calls, ","), "status 2,status 3", "already applied pause is not repeated")
  KB.eq(q:hasPending(), false, "queue drained")
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
  KB.eq(table.concat(calls, ","), "status 3,status 2,page 0", "calls")
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

KB.check("two offline reads keep their pages separate through pause, resume and finish", function()
  local q, settings = KB.newQueue()
  local first, second = 1793442600, 1793529000
  atTime(first, function()
    q:enqueuePage(FILE, { book_id = 1, mapped_page = 300, started_at = "2026-09-01" })
    q:enqueueStatus(FILE, { book_id = 1, status_id = S.FINISHED, from_status_id = S.READING })
  end)
  atTime(second, function()
    q:startReread(FILE, { book_id = 1, mapped_page = 7 })
    q:enqueueStatus(FILE, { book_id = 1, status_id = S.PAUSED })
    KB.eq(q:statusOf(FILE), S.PAUSED, "paused reread's local shelf")
    KB.eq(#q:applyToReading({}), 0, "a paused reread is not a reading card")
    q:enqueueStatus(FILE, { book_id = 1, status_id = S.READING })
    q:enqueuePage(FILE, { book_id = 1, mapped_page = 31 })
    q:enqueueStatus(FILE, { book_id = 1, status_id = S.FINISHED })
  end)
  q = require("hardcover/lib/sync_queue"):new { settings = settings }
  local shown = q:applyPending(FILE, { status_id = S.READING,
    user_book_reads = { { id = 5, progress_pages = 200 } } })
  KB.eq(shown.status_id, S.FINISHED, "finished reread's local shelf")
  KB.eq(shown.user_book_reads[1].progress_pages, 31, "finished reread's local progress")
  local ub = { id = 9, status_id = S.READING,
    user_book_reads = { { id = 5, progress_pages = 200, started_at = "2026-09-01" } } }
  local api, calls = server(ub)
  KB.eq(q:flush(api, { user_id = 1 }), true, "flush")
  KB.eq(table.concat(calls, ","), "page 300,status 3,status 2,page 7,status 4,status 2,page 31,status 3", "session order")
  KB.eq(#ub.user_book_reads, 2, "resume does not create a third read")
  KB.eq(ub.user_book_reads[1].progress_pages, 300, "original read's page")
  KB.eq(ub.user_book_reads[1].started_at, "2026-09-01", "original read's date")
  KB.eq(ub.user_book_reads[2].progress_pages, 31, "new read's page")
  KB.eq(ub.user_book_reads[2].started_at, os.date("%Y-%m-%d", second), "new read's date")
  KB.eq(ub.status_id, S.FINISHED, "final shelf")
end)

KB.check("an older queue keeps its known start, page and pause when upgraded", function()
  local q, settings = KB.newQueue()
  settings:saveSetting("pending", { ["1"] = { book_id = 1, status_id = S.PAUSED, status_updated_at = 300,
    passed_reading = true, passed_reading_at = 100, mapped_page = 7, page_updated_at = 200,
    from_status_id = S.TO_READ } })
  local api, calls = server({ id = 9, status_id = S.TO_READ, user_book_reads = {} })
  KB.eq(q:flush(api, { user_id = 1 }), true, "migrated flush")
  KB.eq(table.concat(calls, ","), "status 2,read 7,status 4", "legacy history")
  KB.eq(api.status_times[S.READING], 100, "known original start time")
end)

KB.check("confirming one reread does not silently confirm another after a finish", function()
  local q = KB.newQueue()
  q:enqueuePage(FILE, { book_id = 1, mapped_page = 7 })
  q:enqueueStatus(FILE, { book_id = 1, status_id = S.FINISHED })
  q:enqueuePage(FILE, { book_id = 1, mapped_page = 9 })
  local ub = { id = 9, status_id = S.FINISHED,
    user_book_reads = { { id = 5, progress_pages = 300, finished_at = "finished" } } }
  local api, calls = server(ub)
  KB.eq(q:flush(api, { user_id = 1 }), false, "first reread needs a choice")
  KB.eq(q:resolve(FILE, "yes"), true, "confirm first reread")
  KB.eq(q:flush(api, { user_id = 1 }), false, "second reread still needs a choice")
  KB.eq(table.concat(calls, ","), "status 2,page 7,status 3", "stop before the unconfirmed read")
  KB.eq(#ub.user_book_reads, 2, "only the confirmed read was created")
  KB.eq(q:get(FILE).conflict.local_page, 9, "the remaining question is about the second read")
end)

KB.check("journal cancellation removes only the selected action and rejects stale or dependent rows", function()
  local PendingStatus = require("hardcover/lib/pending_status")
  local q = KB.newQueue()
  q:enqueueStatus(FILE, { book_id = 1, user_id = 1, status_id = S.READING, from_status_id = S.TO_READ })
  q:enqueuePage(FILE, { book_id = 1, user_id = 1, mapped_page = 7 })
  q:enqueueStatus(FILE, { book_id = 1, user_id = 1, status_id = S.PAUSED })
  local history = PendingStatus.history(q, 1)
  local start, page, pause = history[1], history[2], history[3]
  KB.eq(q:cancelAction(1, pause.seq, 2, pause.queue_entry), false, "another account cannot cancel it")
  KB.eq(q:cancelAction(1, pause.seq, 1, pause.queue_entry), true, "cancel just the pause")
  KB.eq(q:statusOf(1), S.READING, "Reading survives")
  KB.eq(q:get(1).mapped_page, 7, "progress survives")
  local ok, reason = q:cancelAction(1, start.seq, 1, start.queue_entry)
  KB.eq(ok, false, "a required start cannot be removed alone")
  KB.eq(reason, "dependent", "why the start stays")
  KB.eq(q:cancelAction(1, page.seq, 1, page.queue_entry), true, "cancel its progress first")
  KB.eq(q:cancelAction(1, start.seq, 1, start.queue_entry), true, "then cancel the start")
  KB.eq(q:hasPending(), false, "all chosen changes cancelled")
  q:enqueueStatus(FILE, { book_id = 1, user_id = 1, status_id = S.READING })
  KB.eq(q:cancelAction(1, start.seq, 1, start.queue_entry), false, "old row cannot cancel a new session with reused sequence")
  KB.eq(q:hasPending(), true, "new session remains")
  q:clearAll()
  q:enqueueStatus(FILE, { book_id = 1, user_id = 1, status_id = S.FINISHED, from_status_id = S.READING })
  q:startReread(FILE, { book_id = 1, user_id = 1, mapped_page = 7 })
  local finish = PendingStatus.history(q, 1)[1]
  ok, reason = q:cancelAction(1, finish.seq, 1, finish.queue_entry)
  KB.eq(ok, false, "a finish needed by a new read stays")
  KB.eq(reason, "dependent", "cancel the dependent session first")
end)

KB.check("a journal action cannot be cancelled while its book is being sent", function()
  local q = KB.newQueue()
  q:enqueueStatus(FILE, { book_id = 1, user_id = 1, status_id = S.PAUSED, from_status_id = S.READING })
  local row = require("hardcover/lib/pending_status").history(q, 1)[1]
  local api = server(paused())
  local find = api.findUserBook
  api.findUserBook = function(self)
    local ok, reason = q:cancelAction(1, row.seq, 1, row.queue_entry)
    KB.eq(ok, false, "cancellation refused")
    KB.eq(reason, "sending", "request may already have reached Hardcover")
    return find(self)
  end
  KB.eq(q:flush(api, { user_id = 1 }), true, "send completes")
end)

KB.check("a migrated finish cannot be cancelled while its reread progress remains", function()
  local q, settings = KB.newQueue()
  settings:saveSetting("pending", { ["1"] = { book_id = 1, user_id = 1, status_id = S.FINISHED,
    status_updated_at = 100, mapped_page = 7, page_updated_at = 200, reread = true,
    from_status_id = S.READING } })
  local finish = require("hardcover/lib/pending_status").history(q, 1)[1]
  local ok, reason = q:cancelAction(1, finish.seq, 1, finish.queue_entry)
  KB.eq(ok, false, "the original finish must survive")
  KB.eq(reason, "dependent", "migrated reread needs the finish")
  local ub = { id = 9, status_id = S.READING,
    user_book_reads = { { id = 5, progress_pages = 300, started_at = "2025-12-01" } } }
  KB.eq(q:flush(server(ub), { user_id = 1 }), true, "migrated stream sends")
  KB.eq(#ub.user_book_reads, 2, "a separate reread opens")
  KB.eq(ub.user_book_reads[1].progress_pages, 300, "original progress is untouched")
  KB.eq(ub.user_book_reads[2].progress_pages, 7, "reread progress reaches its own read")
end)

for _, choice in ipairs({ "cloud", "no" }) do
  KB.check("rejecting a conflict with " .. choice .. " preserves a later reread", function()
    local q, settings = KB.newQueue()
    q:enqueuePage(FILE, { book_id = 1, mapped_page = 7 })
    q:enqueueStatus(FILE, { book_id = 1, status_id = S.FINISHED })
    q:startReread(FILE, { book_id = 1, mapped_page = 31 })
    local ub = { id = 9, status_id = choice == "cloud" and S.READING or S.FINISHED,
      user_book_reads = { { id = 5, progress_pages = 300, started_at = "2025-12-01",
        finished_at = choice == "no" and "2025-12-10" or nil } } }
    local api = server(ub)
    KB.eq(q:flush(api, { user_id = 1 }), false, "first checkpoint conflicts")
    KB.eq(q:resolve(FILE, choice), true, "reject only the conflicted reading")
    q = require("hardcover/lib/sync_queue"):new { settings = settings }
    KB.eq(q:flush(api, { user_id = 1 }), true, "later session still sends after restart")
    KB.eq(#ub.user_book_reads, 2, "later reread preserved")
    KB.eq(ub.user_book_reads[1].progress_pages, 300, "original page preserved")
    KB.eq(ub.user_book_reads[2].progress_pages, 31, "later progress preserved")
  end)
end

KB.finish("a status chain must keep Reading, and a finish must precede a restart")
