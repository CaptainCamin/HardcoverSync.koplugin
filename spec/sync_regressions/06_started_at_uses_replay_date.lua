-- BUG: a read created by a replay is dated with the day of the replay.
--
-- Reading starts offline on 2026-01-01 (no read exists yet, so the queue entry
-- has no started_at). The queue is flushed on 2026-01-05.
-- SyncQueue:_flushEntry (hardcover/lib/sync_queue.lua, createRead call) falls
-- back to os.date("%Y-%m-%d") at FLUSH time. The entry already records
-- page_updated_at (epoch), so the day the reading really started is known.
-- The same applies to Cache:syncPage's offline path: queueMeta stores
-- started_at = nil when there is no read.
--
-- Expected: started_at is the date of the first queued page, in local time.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

print("\n== started_at on a replayed read ==")

KB.check("createRead gets the day reading started, not the day of the flush", function()
  local real_time, real_date = os.time, os.date
  local now = real_time { year = 2026, month = 1, day = 1, hour = 12 }
  os.time = function(t) if t then return real_time(t) end return now end
  os.date = function(fmt, t) return real_date(fmt, t or now) end

  local ok, err = pcall(function()
    local q = KB.newQueue()
    q:enqueuePage("/books/a.epub", { mapped_page = 30, book_id = 7, edition_id = 3 })
    now = real_time { year = 2026, month = 1, day = 5, hour = 12 } -- reconnects 4 days later
    local api = KB.fakeApi({ [7] = { id = 500, book_id = 7, status_id = HARDCOVER.STATUS.READING,
      user_book_reads = {} } })
    q:flush(api, { user_id = 1 })
    local started
    for _, c in ipairs(api.calls) do
      if c.op == "createRead" then started = c.started_at end
    end
    KB.eq(started, "2026-01-01", "started_at sent to createRead")
  end)
  os.time, os.date = real_time, real_date
  if not ok then error(err, 0) end
end)

-- Hardcover creates a read as part of changing status, but action_at only dates the journal:
-- the read itself starts on the day of the request. Model that live API behavior here.
local S = HARDCOVER.STATUS
local function datedServer(status, read)
  local ub = status and { id = 500, book_id = 7, status_id = status, user_book_reads = read and { read } or {} }
  local api = {}
  function api:findUserBook() return ub end
  function api:updateUserBook(_, next_status)
    ub = { id = 500, book_id = 7, user_book_reads = {} }
    return self:updateUserBookStatus(ub.id, next_status)
  end
  function api:updateUserBookStatus(_, next_status)
    local reads = ub.user_book_reads
    if next_status == S.READING and (#reads == 0 or ub.status_id == S.FINISHED or ub.status_id == S.DNF) then
      reads[#reads + 1] = { id = 900 + #reads, edition_id = 3, started_at = "2026-01-05" }
    elseif next_status == S.FINISHED then
      reads[#reads].finished_at = "2026-01-05"
    end
    ub.status_id = next_status
    if self.lose_start and next_status == S.READING then
      self.lose_start = false
      return nil, { status = 503 }
    end
    if self.lose_finish and next_status == S.FINISHED then
      self.lose_finish = false
      return nil, { status = 503 }
    end
    return ub
  end
  function api:updatePage(_, _, page, started_at)
    if self.reject_date then self.reject_date = false; return nil, { status = 503 } end
    local r = ub.user_book_reads[#ub.user_book_reads]
    r.progress_pages, r.started_at = page, started_at
    if self.lose_date then self.lose_date = false; return nil, { status = 503 } end
    return ub
  end
  function api:setFinishedDate(_, date)
    ub.user_book_reads[#ub.user_book_reads].finished_at = date
    return ub
  end
  function api:updateReadDates(id, dates)
    if self.reject_date then self.reject_date = false; return nil, { status = 503 } end
    if self.reject_finish_date and dates.finished_at then
      self.reject_finish_date = false
      return nil, { status = 503 }
    end
    for _, r in ipairs(ub.user_book_reads) do
      if r.id == id then
        for k, v in pairs(dates) do r[k] = v end
        if self.lose_date then self.lose_date = false; return nil, { status = 503 } end
        return ub
      end
    end
  end
  return api
end

local function enqueueAt(q, day, kind, value)
  local real = os.time
  local at = real { year = 2026, month = 1, day = day, hour = 12 }
  os.time = function(t) return t and real(t) or at end
  local ok, err = pcall(function()
    local payload = { book_id = 7, edition_id = 3 }
    if kind == "status" then payload.status_id = value; q:enqueueStatus("/b/a.epub", payload)
    elseif kind == "reread" then payload.mapped_page = value; q:startReread("/b/a.epub", payload)
    else payload.mapped_page = value; q:enqueuePage("/b/a.epub", payload) end
  end)
  os.time = real
  if not ok then error(err, 0) end
end

for _, case in ipairs({
  { name = "a status-only offline start", status = S.TO_READ },
  { name = "a start for a book new to the library" },
  { name = "start, progress on another day, pause, resume, finish", status = S.TO_READ, chain = true },
  { name = "an implicit start from queued progress", status = S.TO_READ, page_only = true, day = "2026-01-02" },
  { name = "a reread", status = S.FINISHED, reread = true,
    read = { id = 800, started_at = "2025-12-20", finished_at = "2025-12-25", progress_pages = 300 } },
  { name = "a resume keeps the existing date", status = S.PAUSED, day = "2025-12-20",
    read = { id = 800, started_at = "2025-12-20", progress_pages = 5 } },
  { name = "an already-reading book keeps its existing date", status = S.READING, day = "2025-12-20",
    read = { id = 800, started_at = "2025-12-20", progress_pages = 5 } },
}) do
  KB.check(case.name .. " survives restart with the right read date", function()
    local q, settings = KB.newQueue()
    if case.reread then enqueueAt(q, 1, "reread", 7)
    elseif not case.page_only then enqueueAt(q, 1, "status", S.READING) end
    if case.page_only or case.chain then enqueueAt(q, 2, "page", 7) end
    if case.chain then
      enqueueAt(q, 2, "status", S.PAUSED)
      enqueueAt(q, 3, "status", S.READING)
      enqueueAt(q, 3, "page", 43)
      enqueueAt(q, 4, "status", S.FINISHED)
    end
    q = require("hardcover/lib/sync_queue"):new { settings = settings }
    local api = datedServer(case.status, case.read)
    KB.eq(q:flush(api, { user_id = 1 }), true, "flush")
    local ub = api:findUserBook()
    local reads = ub.user_book_reads
    KB.eq(reads[#reads].started_at, case.day or "2026-01-01", "remote start date")
    KB.eq(#reads, case.reread and 2 or 1, "remote read count")
    if case.reread then KB.eq(reads[1].started_at, "2025-12-20", "previous read untouched") end
    if case.chain then
      KB.eq(reads[1].progress_pages, 43, "remote progress")
      KB.eq(reads[1].finished_at, "2026-01-04", "remote finish date")
    end
    KB.eq(q:hasPending(), false, "queue drained")
  end)
end

for _, failure in ipairs({ "lose_start", "reject_date", "lose_date", "lose_finish", "reject_finish_date" }) do
  KB.check("the start date survives restart after " .. failure, function()
    local q, settings = KB.newQueue()
    enqueueAt(q, 1, "status", S.READING)
    local finishes = failure == "lose_finish" or failure == "reject_finish_date"
    if finishes then enqueueAt(q, 4, "status", S.FINISHED) end
    local api = datedServer(S.TO_READ)
    for _ = 1, failure == "reject_date" and 3 or 1 do
      api[failure] = true
      KB.eq(q:flush(api, { user_id = 1 }), false, "interrupted flush")
      KB.eq(q:hasPending(), true, "action remains queued")
      KB.eq(q:heldCount(), 0, "a transient outage must not hold the action")
      q = require("hardcover/lib/sync_queue"):new { settings = settings }
    end
    KB.eq(q:flush(api, { user_id = 1 }), true, "retry")
    local reads = api:findUserBook().user_book_reads
    KB.eq(#reads, 1, "retry must not create another read")
    KB.eq(reads[1].started_at, "2026-01-01", "retried start date")
    if finishes then KB.eq(reads[1].finished_at, "2026-01-04", "retried finish date") end
    KB.eq(q:hasPending(), false, "queue drained")
  end)
end

for _, remote_change in ipairs({ "finished", "rereading", "removed" }) do
  KB.check("a failed correction cannot replay a start after another device " .. remote_change, function()
    local q, settings = KB.newQueue()
    enqueueAt(q, 1, "status", S.READING)
    local api = datedServer(S.TO_READ)
    api.reject_date = true
    KB.eq(q:flush(api, { user_id = 1 }), false, "correction failed after the start succeeded")
    local row = require("hardcover/lib/pending_status").history(q, 1)[1]
    KB.eq(q:cancelAction(7, row.seq, 1, row.queue_entry), false, "a sent start is not cancellable")
    local ub = api:findUserBook()
    local read = ub.user_book_reads[1]
    if remote_change == "removed" then
      api.findUserBook = function() return nil end
    else
      api:updateUserBookStatus(ub.id, S.FINISHED)
      if remote_change == "rereading" then api:updateUserBookStatus(ub.id, S.READING) end
    end
    q = require("hardcover/lib/sync_queue"):new { settings = settings }
    KB.eq(q:flush(api, { user_id = 1 }), false, "changed reading holds the correction")
    KB.eq(q:heldCount(), 1, "requires attention instead of blind retry")
    KB.eq(#ub.user_book_reads, remote_change == "rereading" and 2 or 1, "no unwanted read created")
    KB.eq(read.started_at, "2026-01-05", "unsafe historical correction withheld")
    if remote_change == "rereading" then
      KB.eq(ub.user_book_reads[2].started_at, "2026-01-05", "unrelated newer read untouched")
    elseif remote_change == "finished" then
      KB.eq(ub.status_id, S.FINISHED, "completed shelf untouched")
    end
  end)
end

for _, kind in ipairs({ "status", "page" }) do
for _, rereading in ipairs({ false, true }) do
  KB.check("an ambiguous " .. kind .. " start cannot replay after another device " .. (rereading and "rereads" or "finishes"), function()
    local q, settings = KB.newQueue()
    enqueueAt(q, 1, kind, kind == "status" and S.READING or 30)
    local api = datedServer(S.TO_READ)
    api.lose_start = true
    KB.eq(q:flush(api, { user_id = 1 }), false, "start response lost")
    local ub = api:findUserBook()
    api:updateUserBookStatus(ub.id, S.FINISHED)
    if rereading then api:updateUserBookStatus(ub.id, S.READING) end
    q = require("hardcover/lib/sync_queue"):new { settings = settings }
    KB.eq(q:flush(api, { user_id = 1 }), false, "ambiguous changed context held")
    KB.eq(#ub.user_book_reads, rereading and 2 or 1, "no duplicate read")
    KB.eq(ub.status_id, rereading and S.READING or S.FINISHED, "remote shelf preserved")
    KB.eq(ub.user_book_reads[#ub.user_book_reads].started_at, "2026-01-05", "new read's date untouched")
  end)
end
end

KB.check("retrying a start correction preserves another device's newer progress", function()
  local q, settings = KB.newQueue()
  enqueueAt(q, 1, "status", S.READING)
  local api = datedServer(S.TO_READ)
  api.reject_date = true
  KB.eq(q:flush(api, { user_id = 1 }), false, "first correction fails")
  local ub = api:findUserBook()
  ub.user_book_reads[1].progress_pages = 89
  q = require("hardcover/lib/sync_queue"):new { settings = settings }
  KB.eq(q:flush(api, { user_id = 1 }), true, "same read's correction retried")
  KB.eq(#ub.user_book_reads, 1, "one read")
  KB.eq(ub.user_book_reads[1].started_at, "2026-01-01", "original start restored")
  KB.eq(ub.user_book_reads[1].progress_pages, 89, "newer progress preserved")
end)

KB.finish("replayed reads must keep the original start date")
