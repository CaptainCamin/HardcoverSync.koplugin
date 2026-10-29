-- Shelf changes made from the book details screen while offline: a book put on a shelf,
-- moved to another, or taken out of the library. Shown at once on the details screen and
-- the saved shelves, and sent when the connection is back.
--
-- Plain data, no KOReader requires, so it runs under stock Lua in the spec suite. It
-- lives in the same settings file as the progress queue (SyncQueue) but is its own thing:
-- a book here is known by its Hardcover id (it need not be a file on this device), and
-- a book new to the library has no user_book_id until the change is sent.
--
-- One op per book, the newest wins, and the ops that cancel each other leave nothing:
--   status   the book goes on shelf `status_id` (Hardcover upserts: a book already in
--            the library keeps its record, its rating and its reads)
--   remove   the book leaves the library (needs the record's `user_book_id`)
-- A book put on a shelf and then removed before anything was sent has nothing to
-- remove, so both vanish. A remove followed by a new shelf becomes a status change on the
-- same record, so the reading history the remove would have deleted is kept.
--
-- Every op carries the user it was made for. Signing out clears the saved shelves but
-- not this file, so a flush sends only the signed-in user's ops and drops the rest.

local OfflineQueue = require("hardcover/lib/offline_queue")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

local ShelfQueue = OfflineQueue.extend({})
ShelfQueue.store_key = "shelf_ops"

local function valid(op)
  return type(op) == "table" and op.book_id ~= nil and (op.kind == "status" or op.kind == "remove")
    and (op.kind ~= "status" or tonumber(op.status_id) ~= nil)
end

function ShelfQueue:valid(op)
  return valid(op)
end

-- waiting ops by book id, as stored
function ShelfQueue:ops()
  return self:store()
end

function ShelfQueue:isEmpty()
  return not self:hasPending()
end

local function keyOf(book_id) return tostring(tonumber(book_id) or book_id) end

-- the op waiting for this book, or nil. With a user_id, an op made by another
-- account is not returned (an op with no user_id, from an older version, is).
function ShelfQueue:get(book_id, user_id)
  local op = self:ops()[keyOf(book_id)]
  if valid(op) and not (user_id ~= nil and op.user_id ~= nil and op.user_id ~= user_id) then return op end
end

--
-- The book goes on shelf `status_id`. `info`: { user_book_id (the record, if the book
-- is in the library), edition_id (for a book new to it), title }. Returns the op.
--
function ShelfQueue:queueStatus(user_id, book_id, status_id, info)
  info = info or {}
  local before = self:get(book_id, user_id)
  local user_book_id, edition_id = tonumber(info.user_book_id), tonumber(info.edition_id)
  if before then
    -- a change on top of a change keeps what the first one knew about the book
    user_book_id = user_book_id or tonumber(before.user_book_id)
    edition_id = edition_id or tonumber(before.edition_id)
    -- back from a waiting remove: the record is still there, so it is not a new book
    if before.kind == "remove" then edition_id = nil end
  end
  local op = {
    kind = "status", user_id = user_id, book_id = tonumber(book_id), status_id = status_id,
    user_book_id = user_book_id, edition_id = edition_id, title = info.title or (before and before.title),
    -- the shelf the book was on before the first waiting change: what it leaves
    from_status_id = before and before.from_status_id or info.from_status_id,
    at = os.time(),
    -- the day it was finished, so a sync on a later day does not become the finish date
    finished_date = status_id == HARDCOVER.STATUS.FINISHED and os.date("%Y-%m-%d") or nil,
  }
  self:ops()[keyOf(book_id)] = op
  self:persist()
  return op
end

--
-- The book leaves the library. `user_book_id` is its record, `from_status_id` the shelf it
-- is on. Returns "queued", or
-- "dropped" when the book only ever went on a shelf offline: nothing was sent, so
-- nothing is, and the waiting op is gone.
--
function ShelfQueue:queueRemove(user_id, book_id, user_book_id, title, from_status_id)
  local ops = self:ops()
  local before = self:get(book_id, user_id)
  user_book_id = tonumber(user_book_id) or (before and tonumber(before.user_book_id)) or nil
  if not user_book_id then
    ops[keyOf(book_id)] = nil
    self:persist()
    return "dropped"
  end
  ops[keyOf(book_id)] = {
    kind = "remove", user_id = user_id, book_id = tonumber(book_id), user_book_id = user_book_id,
    title = title or (before and before.title),
    from_status_id = before and before.from_status_id or from_status_id,
    at = os.time(),
  }
  self:persist()
  return "queued"
end

-- every waiting op, in a stable order (a copy of the list, the ops themselves)
function ShelfQueue:list()
  local out = {}
  for _, op in pairs(self:ops()) do
    if valid(op) then out[#out + 1] = op end
  end
  table.sort(out, function(a, b) return tostring(a.book_id) < tostring(b.book_id) end)
  return out
end

-- Cancel the change waiting for one book. Returns true when there was one.
function ShelfQueue:cancel(book_id)
  local ops = self:ops()
  local had = ops[keyOf(book_id)] ~= nil
  ops[keyOf(book_id)] = nil
  self:persist()
  return had
end

-- Let held changes try again (after signing in again, say).
function ShelfQueue:retryHeld()
  for _, op in pairs(self:ops()) do
    if type(op) == "table" then op.held, op.failures, op.reason = nil, nil, nil end
  end
  self:persist()
end

--
-- A book's status can also be changed from the reader, which keeps it in the progress queue
-- (SyncQueue, one entry per file, with the page). When both queues hold a status change for
-- the same book, only the newer is sent: the other would land after it and undo it. The
-- older one is dropped (a page waiting in the progress queue stays). `at` stamps are whole
-- seconds; on a tie the reader's change stands.
--
function ShelfQueue:settleWith(sync_queue)
  if not sync_queue then return end
  for _, filepath in ipairs(sync_queue:filepaths()) do
    local entry = sync_queue:get(filepath)
    local op = type(entry) == "table" and entry.status_id ~= nil and entry.book_id ~= nil
      and self:get(entry.book_id)
    if op then
      if (tonumber(op.at) or 0) > (tonumber(entry.status_updated_at) or 0) then
        sync_queue:cancelStatus(filepath)
      else
        self:cancel(op.book_id)
      end
    end
  end
end

-- Throw everything waiting away.
function ShelfQueue:clear()
  local ops = self:ops()
  for key in pairs(ops) do ops[key] = nil end
  self:persist()
end

--
-- Send what is waiting, one request each. `api` needs updateUserBook(book_id,
-- status_id, privacy, edition_id) and removeUserBook(user_book_id), each returning a
-- result, or nil and an error. opts: user_id (required: without a signed-in user nothing
-- is sent); on_sent(op, result) for each change that went through. Stops at the first
-- failure that says the server could not be asked; one it refused is counted and the
-- rest go on. Returns { sent = n, held = n, waiting = n, stopped = bool }.
--
function ShelfQueue:flush(api, opts)
  opts = opts or {}
  local busy = function()
    return { sent = 0, held = self:heldCount(), waiting = self:count(), stopped = true }
  end
  return self:withFlushLock(busy, function() return self:_flush(api, opts) end)
end

function ShelfQueue:_flush(api, opts)
  local ops = self:ops()
  local sent, stopped = 0, false
  if opts.user_id == nil then
    return { sent = 0, held = self:heldCount(), waiting = self:count(), stopped = true }
  end

  local keys = {}
  for key, op in pairs(ops) do
    if not valid(op) or (op.user_id ~= nil and op.user_id ~= opts.user_id) then
      ops[key] = nil -- junk, or made for an account that is not signed in any more
    else
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)

  for _, key in ipairs(keys) do
    local op = ops[key]
    if op and not op.held then
      local ok, result, err = pcall(function()
        if op.kind == "remove" then return api:removeUserBook(op.user_book_id) end
        local result, err = api:updateUserBook(op.book_id, op.status_id, nil, op.edition_id)
        if result and op.finished_date then result = api:setFinishedDate(result, op.finished_date) or result end
        return result, err
      end)
      if not ok then result, err = nil, nil end

      if result then
        sent = sent + 1
        -- a newer change made while this one was out is what is left to send
        if ops[key] == op then ops[key] = nil end
        self:persist()
        if opts.on_sent then opts.on_sent(op, result) end
      elseif OfflineQueue.transient(err) then
        stopped = true
        break
      else
        OfflineQueue.reject(op, err)
        self:persist()
      end
    end
  end

  return { sent = sent, held = self:heldCount(), waiting = self:count(), stopped = stopped }
end

return ShelfQueue
