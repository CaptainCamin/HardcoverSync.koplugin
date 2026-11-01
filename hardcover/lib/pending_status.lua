-- The status changes (and removals) waiting to be sent, read from the progress queue (SyncQueue), which
-- keeps one entry per book: its page, its status or its removal. Screens ask here for the change as a
-- plain row instead of reading entries.
--
-- A change is { kind ("status" or "remove"), book_id, status_id (nil for a remove), user_book_id, title,
-- at (when it was made, os.time), key, entry }. `entry` is the queue's own entry and `key` its key (for
-- cancelling it); `entry.file` is set for a book read on this device.
--
-- Plain data, no KOReader requires.

local SyncQueue = require("hardcover/lib/sync_queue")

local PendingStatus = {}

-- Every waiting change for `user_id` (nil: anyone's), in a stable order (by book id).
function PendingStatus.list(sync_queue, user_id)
  local out = {}
  if not sync_queue then return out end
  for _, key in ipairs(sync_queue:keys()) do
    local entry = sync_queue:get(key)
    local op = SyncQueue.opOf(entry)
    if op and tonumber(entry.book_id) and (user_id == nil or SyncQueue.ownedBy(entry, user_id)) then
      op.key, op.entry = key, entry
      out[#out + 1] = op
    end
  end
  table.sort(out, function(a, b) return a.book_id < b.book_id end)
  return out
end

-- The change waiting for one book, or nil.
function PendingStatus.get(sync_queue, book_id, user_id)
  local op = sync_queue and sync_queue:shelfOp(book_id, user_id)
  return op
end

return PendingStatus
