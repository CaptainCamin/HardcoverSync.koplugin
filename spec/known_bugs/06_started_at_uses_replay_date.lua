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
local KB = dofile((arg[1] or ".") .. "/spec/known_bugs/lib.lua")
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

KB.finish("replayed reads must keep the original start date")
