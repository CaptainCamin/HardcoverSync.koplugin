-- The status changes waiting to be sent, from wherever they are kept: the progress queue (a book
-- read on this device, SyncQueue, by file) and the shelf queue (a book changed from its details,
-- ShelfQueue, by Hardcover book id). Screens ask here instead of knowing both.
--
-- A change is { kind ("status" or "remove"), book_id, status_id (nil for a remove), user_book_id,
-- title, at (when it was made, os.time), and where it is kept: `filepath` and `entry` in the progress
-- queue, `op` in the shelf queue }. When both queues hold one for a book the newer wins,
-- as ShelfQueue:settleWith does at flush time.
--
-- Plain data, no KOReader requires.

local PendingStatus = {}

local function newer(a, b)
  return not a or (tonumber(b.at) or 0) >= (tonumber(a.at) or 0)
end

-- Every waiting change for `user_id` (nil: anyone's), in a stable order (by book id).
function PendingStatus.list(sync_queue, shelf_queue, user_id)
  local by_book = {}
  local function consider(change)
    local key = tostring(change.book_id)
    if newer(by_book[key], change) then by_book[key] = change end
  end
  local function mine(owner)
    return owner == nil or user_id == nil or tostring(owner) == tostring(user_id)
  end

  if sync_queue then
    for _, filepath in ipairs(sync_queue:filepaths()) do
      local entry = sync_queue:get(filepath)
      local book_id = type(entry) == "table" and tonumber(entry.book_id)
      if book_id and entry.status_id ~= nil and mine(entry.user_id) then
        consider { kind = "status", book_id = book_id, status_id = entry.status_id,
          user_book_id = entry.user_book_id, title = entry.title, at = entry.status_updated_at,
          filepath = filepath, entry = entry }
      end
    end
  end
  if shelf_queue then
    for _, op in ipairs(shelf_queue:list()) do
      if mine(op.user_id) then
        consider { kind = op.kind, book_id = tonumber(op.book_id), status_id = op.status_id,
          user_book_id = op.user_book_id, title = op.title, at = op.at, op = op }
      end
    end
  end

  local out = {}
  for _, change in pairs(by_book) do out[#out + 1] = change end
  table.sort(out, function(a, b) return a.book_id < b.book_id end)
  return out
end

-- The change waiting for one book, or nil.
function PendingStatus.get(sync_queue, shelf_queue, book_id, user_id)
  book_id = tonumber(book_id)
  for _, change in ipairs(PendingStatus.list(sync_queue, shelf_queue, user_id)) do
    if change.book_id == book_id then return change end
  end
end

return PendingStatus
