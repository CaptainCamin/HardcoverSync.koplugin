-- Pending changes groups each book's statuses under one cancellation control; the journal asks
-- for history instead, to show each transition and checkpoint that sync will send.
--
-- A change is { kind ("status" or "remove"), book_id, status_id (nil for a remove), user_book_id, title,
-- at (when it was made, os.time), key, entry }. `entry` is the queue's own entry and `key` its key (for
-- cancelling it); `entry.file` is set for a book read on this device.
--
-- Plain data, no KOReader requires.

local SyncQueue = require("hardcover/lib/sync_queue")
local Actions = require("hardcover/lib/reading_actions")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

local PendingStatus = {}

-- Every waiting change for `user_id` (nil: anyone's), in a stable order (by book id).
function PendingStatus.list(sync_queue, user_id)
  local out = {}
  if not sync_queue then return out end
  for _, key in ipairs(sync_queue:keys()) do
    local entry = sync_queue:get(key)
    local op = SyncQueue.opOf(entry)
    if op and (entry.remove or Actions.statusCount(entry) > 0)
      and tonumber(entry.book_id) and (user_id == nil or SyncQueue.ownedBy(entry, user_id)) then
      op.key, op.entry = key, entry
      op.count = Actions.statusCount(entry)
      out[#out + 1] = op
    end
  end
  table.sort(out, function(a, b) return a.book_id < b.book_id end)
  return out
end

-- The progress checkpoints waiting for `user_id` (nil: anyone's): { kind ("progress"), book_id,
-- title, page, day, at }, by book then time. A status boundary can retain multiple on the same day.
function PendingStatus.pages(sync_queue, user_id)
  local out = {}
  if not sync_queue then return out end
  for _, key in ipairs(sync_queue:keys()) do
    local entry = sync_queue:get(key)
    if entry.mapped_page ~= nil and tonumber(entry.book_id) and (user_id == nil or SyncQueue.ownedBy(entry, user_id)) then
      local days = type(entry.page_days) == "table" and #entry.page_days > 0 and entry.page_days
        or { { day = "", page = entry.mapped_page, at = entry.page_updated_at } }
      for _, d in ipairs(days) do
        out[#out + 1] = { kind = "progress", book_id = tonumber(entry.book_id), title = entry.title,
          page = d.page, day = d.day, at = d.at }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.book_id ~= b.book_id then return a.book_id < b.book_id end
    return (tonumber(a.at) or 0) < (tonumber(b.at) or 0)
  end)
  return out
end

-- The change waiting for one book, or nil.
function PendingStatus.get(sync_queue, book_id, user_id)
  local op = sync_queue and sync_queue:shelfOp(book_id, user_id)
  return op
end

-- The journal reads the same ordered actions sync sends, not a reconstruction from the final
-- shelf. Sequence numbers distinguish repeated statuses and page checkpoints on the same day.
function PendingStatus.history(sync_queue, user_id)
  local out = {}
  if not sync_queue then return out end
  for _, key in ipairs(sync_queue:keys()) do
    local entry = sync_queue:get(key)
    if user_id == nil or SyncQueue.ownedBy(entry, user_id) then
      if entry.remove then
        local op = SyncQueue.opOf(entry)
        op.queue_entry = entry
        out[#out + 1] = op
      else
        local previous = entry.from_status_id
        for _, action in ipairs(Actions.list(entry)) do
          local reading = action.kind == "status" and action.value == HARDCOVER.STATUS.READING
          out[#out + 1] = {
            kind = action.kind == "page" and "progress" or "status", seq = action.seq, queue_entry = entry,
            started = Actions.started(action),
            sync_state = entry.reason == "reading_changed" and "Reading changed on Hardcover"
              or (action.applied or action.status_sent) and "Finishing sync"
              or Actions.started(action) and "Checking sync outcome" or nil,
            book_id = tonumber(entry.book_id), title = entry.title, at = action.at,
            page = action.kind == "page" and action.value or nil, day = action.day,
            status_id = action.kind == "status" and action.value or nil,
            reading = reading and previous ~= HARDCOVER.STATUS.READING
              and (previous == HARDCOVER.STATUS.PAUSED and "resume" or "start") or nil,
          }
          if action.kind == "status" then previous = action.value end
        end
      end
    end
  end
  return out
end

return PendingStatus
