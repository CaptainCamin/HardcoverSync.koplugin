-- Reviews written on the book details screen while offline: kept per book, shown at once, sent when
-- online.
--
-- Plain data, no KOReader requires, so it runs under stock Lua in the spec suite. It lives in the
-- same settings file as the progress queue (SyncQueue). One review per book: writing a book's
-- review twice offline leaves the newest. Empty text clears the review.

local OfflineQueue = require("hardcover/lib/offline_queue")

local ReviewQueue = OfflineQueue.extend({})
ReviewQueue.store_key = "review_ops"

local function valid(op)
  return type(op) == "table" and op.user_book_id ~= nil and type(op.text) == "string"
end

function ReviewQueue:valid(op)
  return valid(op)
end

-- waiting reviews by library record, as stored
function ReviewQueue:ops()
  return self:store()
end

function ReviewQueue:isEmpty()
  return not self:hasPending()
end

-- the waiting review for this library record as { text ("" = a clear), spoilers }, or nil
function ReviewQueue:get(user_book_id)
  local op = self:ops()[tostring(user_book_id)]
  if valid(op) then return { text = op.text, spoilers = op.spoilers == true } end
end

function ReviewQueue:queue(user_book_id, text, spoilers, title)
  self:ops()[tostring(user_book_id)] = {
    user_book_id = user_book_id, text = text or "", spoilers = spoilers == true, title = title,
  }
  self:persist()
end

-- every waiting review as { user_book_id, text, spoilers, title, held, reason }, in a stable order
function ReviewQueue:list()
  local out = {}
  for _, op in pairs(self:ops()) do
    if valid(op) then
      out[#out + 1] = { user_book_id = op.user_book_id, text = op.text, spoilers = op.spoilers == true,
        title = op.title, held = op.held, reason = op.reason }
    end
  end
  table.sort(out, function(a, b) return tostring(a.user_book_id) < tostring(b.user_book_id) end)
  return out
end

-- Cancel the review waiting for one book.
function ReviewQueue:cancel(user_book_id)
  local ops = self:ops()
  local had = ops[tostring(user_book_id)] ~= nil
  ops[tostring(user_book_id)] = nil
  self:persist()
  return had
end

-- Send what is waiting, one request each. A review Hardcover did not answer for stays queued for
-- the next try and stops the flush. One it refused is counted and the rest go on; the third
-- refusal in a row holds it until the user presses Sync (retryHeld).
-- `opts`: { json (KOReader's), on_sent(user_book_id, user_book) for each one that went through }.
-- Returns the number still waiting (held ones included).
function ReviewQueue:flush(api, opts)
  opts = opts or {}
  return self:withFlushLock(function() return self:count() end, function()
    local ops = self:ops()
    local keys = {}
    for key, op in pairs(ops) do
      if valid(op) then keys[#keys + 1] = key else ops[key] = nil end
    end
    table.sort(keys)

    for _, key in ipairs(keys) do
      local op = ops[key]
      if not op.held then
        local user_book, err = api:updateReview(op.user_book_id, op.text, op.spoilers == true, opts.json)
        if user_book then
          -- a newer review written while this one was in flight stays
          if ops[key] == op then ops[key] = nil end
          self:persist()
          if opts.on_sent then opts.on_sent(op.user_book_id, user_book) end
        elseif OfflineQueue.transient(err) then
          break
        else
          OfflineQueue.reject(op, err)
          self:persist()
        end
      end
    end
    return self:count()
  end)
end

-- Let held reviews try again (pressing Sync).
function ReviewQueue:retryHeld()
  for _, op in pairs(self:ops()) do
    if type(op) == "table" then op.held, op.failures, op.reason = nil, nil, nil end
  end
  self:persist()
end

return ReviewQueue
