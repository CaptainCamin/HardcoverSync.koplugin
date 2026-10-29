-- Ratings set from the book details screen while offline, shown at once and sent
-- when the connection is back.
--
-- Plain data, no KOReader requires, so it runs under stock Lua in the spec suite.
-- It lives in the same settings file as the progress queue (SyncQueue). One
-- rating per book: rating a book twice offline leaves the newest. A rating of 0
-- clears it.

local OfflineQueue = require("hardcover/lib/offline_queue")

local RatingQueue = OfflineQueue.extend({})
RatingQueue.store_key = "rating_ops"

local function valid(op)
  return type(op) == "table" and (op.user_book_id ~= nil or op.book_id ~= nil) and tonumber(op.rating) ~= nil
end

function RatingQueue:valid(op)
  return valid(op)
end

-- waiting ratings by book (older entries use the library record), as stored
function RatingQueue:ops()
  return self:store()
end

function RatingQueue:isEmpty()
  return not self:hasPending()
end

-- the rating waiting for this library record (0 = a clear), or nil
function RatingQueue:get(user_book_id, book_id, user_id)
  local _, op = self:bookOpKey(user_book_id, book_id, user_id)
  if valid(op) then return tonumber(op.rating) end
end

function RatingQueue:queue(user_book_id, rating, title, book_id, user_id)
  local key, before = self:bookOpKey(user_book_id, book_id, user_id)
  self:ops()[key] = { user_book_id = user_book_id or (before and before.user_book_id),
    book_id = book_id or (before and before.book_id), user_id = user_id or (before and before.user_id),
    rating = rating, title = title }
  self:persist()
end

-- every waiting rating as { user_book_id, rating (0 = a clear), title }, in a stable order
function RatingQueue:list(user_id)
  local out = {}
  for _, op in pairs(self:ops()) do
    if valid(op) and (user_id == nil or OfflineQueue.bookOpForUser(op, user_id)) then
      out[#out + 1] = { user_book_id = op.user_book_id, book_id = op.book_id, user_id = op.user_id,
        rating = tonumber(op.rating), title = op.title,
        held = op.held, reason = op.reason }
    end
  end
  table.sort(out, function(a, b) return tostring(a.book_id or a.user_book_id) < tostring(b.book_id or b.user_book_id) end)
  return out
end

-- Cancel the rating waiting for one book.
function RatingQueue:cancel(user_book_id, book_id, user_id)
  local ops = self:ops()
  local key = self:bookOpKey(user_book_id, book_id, user_id)
  local had = ops[key] ~= nil
  ops[key] = nil
  self:persist()
  return had
end

-- Send what is waiting, one request each. A rating Hardcover did not answer for
-- stays queued for the next try and stops the flush. One it refused is counted and the
-- rest go on; the third refusal in a row holds it until the user presses Sync (retryHeld).
-- `on_sent(user_book_id, user_book)` is called for each one that went through. Returns
-- the number still waiting (held ones included).
function RatingQueue:flush(api, on_sent, user_id)
  -- a second flush while one is out waits for the first (each rating is sent once)
  return self:withFlushLock(function() return #self:list(user_id) end, function()
    local ops = self:ops()
    local keys = {}
    for key, op in pairs(ops) do
      if valid(op) then keys[#keys + 1] = key else ops[key] = nil end
    end
    table.sort(keys)

    for _, key in ipairs(keys) do
      local op = ops[key]
      if op and not op.held and OfflineQueue.bookOpForUser(op, user_id) then
        local id, err = self:resolveUserBook(api, op, user_id)
        local user_book
        if id and ops[key] == op then user_book, err = api:updateRating(id, tonumber(op.rating)) end
        if user_book then
          -- a newer rating made while this one was in flight stays
          if ops[key] == op then ops[key] = nil end
          self:persist()
          if on_sent then on_sent(op.user_book_id, user_book) end
        elseif ops[key] == op and (id or err ~= nil) then
          if OfflineQueue.transient(err) then break end
          OfflineQueue.reject(op, err)
          self:persist()
        end
      end
    end
    return #self:list(user_id)
  end)
end

-- Let held ratings try again (pressing Sync).
function RatingQueue:retryHeld()
  for _, op in pairs(self:ops()) do
    if type(op) == "table" then op.held, op.failures, op.reason = nil, nil, nil end
  end
  self:persist()
end

return RatingQueue
