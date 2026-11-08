-- A queued Read on an already finished book must not date its old read as today.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
local S = require("hardcover/lib/constants/hardcover").STATUS

for _, finish in ipairs({ "2023-04-12", false }) do
  KB.check("an already read book keeps its finish date: " .. tostring(finish), function()
    local q = KB.newQueue()
    -- Offline, an old book may have no saved Hardcover status at all.
    q:enqueueStatus("/old.epub", { book_id = 7, status_id = S.FINISHED })
    local read = { id = 800, progress_pages = 300, finished_at = finish or nil,
      finished_at_precision = finish and 1 or 0 }
    local api = KB.fakeApi({ [7] = { id = 500, book_id = 7, status_id = S.FINISHED,
      user_book_reads = { read } } })
    local dates = 0
    api.updateReadDates = function() dates = dates + 1; error("old read was redated") end
    KB.eq(q:flush(api, { user_id = 1 }), true, "flush")
    KB.eq(dates, 0, "date writes")
    KB.eq(api:count("updateUserBookStatus"), 0, "status writes")
    KB.eq(read.finished_at, finish or nil, "original finish date")
    KB.eq(read.finished_at_precision, finish and 1 or 0, "original precision")
    KB.eq(q:hasPending("/old.epub"), false, "queue cleared")
  end)
end

KB.check("a genuine offline finish still corrects its date after a lost response", function()
  local q = KB.newQueue()
  q:enqueueStatus("/new.epub", { book_id = 7, status_id = S.FINISHED, from_status_id = S.READING })
  local expected = q:get("/new.epub").finished_date
  local read = { id = 800, progress_pages = 300 }
  local ub = { id = 500, book_id = 7, status_id = S.READING, user_book_reads = { read } }
  local api = KB.fakeApi({ [7] = ub })
  api.updateUserBookStatus = function()
    ub.status_id, read.finished_at = S.FINISHED, "2099-01-01"
    return nil, { status = 503 }
  end
  KB.eq(q:flush(api, { user_id = 1 }), false, "lost response")
  -- Recreate the queue to cover a restart between the request and its retry.
  local SyncQueue = require("hardcover/lib/sync_queue")
  q = SyncQueue:new { settings = q.settings }
  KB.eq(q:flush(api, { user_id = 1 }), true, "retry")
  KB.eq(read.finished_at, expected, "actual offline finish date")
end)

KB.finish("reading an old finished book offline preserves its original finish date")
