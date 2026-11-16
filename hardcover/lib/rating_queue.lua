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

-- A rating of 0 and no rating are the same value to compare with Hardcover's nil.
local function value(rating)
  return tonumber(rating) or 0
end

-- What the device last saw on Hardcover: a table with `known`, or "unknown".
local function baseValue(op)
  local base = op and op.base
  if type(base) == "table" and base.known then return true, value(base.rating) end
  return false
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

-- `base` is what the device last saw on Hardcover: { rating = n or nil, known = true }, or
-- "unknown" when the screen could not tell. The first edit keeps that baseline; a later edit
-- while it waits keeps the original one, so the comparison stays against Hardcover, not against
-- our own draft.
function RatingQueue:queue(user_book_id, rating, title, book_id, user_id, base)
  local key, before = self:bookOpKey(user_book_id, book_id, user_id)
  local next_base = (before and before.base) or base or "unknown"
  self:ops()[key] = { user_book_id = user_book_id or (before and before.user_book_id),
    book_id = book_id or (before and before.book_id), user_id = user_id or (before and before.user_id),
    rating = rating, title = title, at = os.time(), base = next_base }
  self:persist()
end

-- every waiting rating as { user_book_id, rating (0 = a clear), title }, in a stable order
function RatingQueue:list(user_id)
  local out = {}
  for _, op in pairs(self:ops()) do
    if valid(op) and (user_id == nil or OfflineQueue.bookOpForUser(op, user_id)) then
      out[#out + 1] = { user_book_id = op.user_book_id, book_id = op.book_id, user_id = op.user_id,
        rating = tonumber(op.rating), title = op.title,
        held = op.held, reason = op.reason, blocked = op.blocked, blocked_reason = op.blocked_reason,
        parked = op.parked == true, decision = op.decision }
    end
  end
  table.sort(out, function(a, b) return tostring(a.book_id or a.user_book_id) < tostring(b.book_id or b.user_book_id) end)
  return out
end

-- The questions waiting for this account, in the shared shape the review list uses.
function RatingQueue:decisions(user_id)
  local out = {}
  for key, op in pairs(self:ops()) do
    if valid(op) and op.parked and type(op.decision) == "table"
      and (user_id == nil or OfflineQueue.bookOpForUser(op, user_id)) then
      local decision_key = key
      out[#out + 1] = {
        id = "rating:" .. tostring(key), kind = "rating", key = key,
        book_id = tonumber(op.book_id), user_book_id = op.user_book_id, title = op.title,
        entry = { title = op.title, conflict = op.decision },
        resolve = function(choice) return self:resolve(decision_key, choice) end,
      }
    end
  end
  table.sort(out, function(a, b)
    local a_book, b_book = tonumber(a.book_id) or 0, tonumber(b.book_id) or 0
    if a_book ~= b_book then return a_book < b_book end
    return tostring(a.id) < tostring(b.id)
  end)
  return out
end

function RatingQueue:decisionForBook(book_id, user_id, user_book_id)
  for _, decision in ipairs(self:decisions(user_id)) do
    if (book_id ~= nil and decision.book_id ~= nil and tostring(decision.book_id) == tostring(book_id))
      or (user_book_id ~= nil and decision.user_book_id ~= nil
        and tostring(decision.user_book_id) == tostring(user_book_id)) then
      return decision
    end
  end
end

-- Keep Hardcover's rating (drop ours), or use this device's. The device answer is checked
-- against Hardcover again before it is sent, so it never becomes a blanket overwrite.
function RatingQueue:resolve(key, choice)
  local ops = self:ops()
  local op = ops[key]
  if not (valid(op) and op.parked and type(op.decision) == "table") then return false end
  if choice == "keep_hardcover" then
    ops[key] = nil
  elseif choice == "use_device" then
    op.answer = { online = value(op.decision.online), rating = value(op.decision.proposed) }
    op.parked, op.decision = nil, nil
  else
    return false
  end
  self:persist()
  return true, { kind = "rating" }
end

-- Ratings waiting for an earlier change (a shelf or removal not settled): not a refusal, and
-- not a reason to keep retrying on their own.
function RatingQueue:blockedCount(user_id)
  local n = 0
  for _, op in pairs(self:ops()) do
    if valid(op) and op.blocked and (user_id == nil or OfflineQueue.bookOpForUser(op, user_id)) then
      n = n + 1
    end
  end
  return n
end

-- Ratings parked for any reason (held, blocked or waiting for an answer), counting one that is
-- both only once: the number the flush result must not exceed to call the pass complete.
function RatingQueue:parkedCount(user_id)
  local n = 0
  for _, op in pairs(self:ops()) do
    if valid(op) and (op.held or op.blocked or op.parked)
      and (user_id == nil or OfflineQueue.bookOpForUser(op, user_id)) then
      n = n + 1
    end
  end
  return n
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

-- Compare the fresh online rating with the one this device started from, or with the answer
-- already given. "ack" means there is nothing to write; "send" may write; "park" asks.
local function compare(op, online)
  local proposed = value(op.rating)
  if proposed == online then return "ack" end
  if op.answer and value(op.answer.online) == online then return "send" end
  local known, base = baseValue(op)
  if known and base == online then return "send" end
  return "park"
end

-- Send what is waiting, one request each. A rating Hardcover did not answer for
-- stays queued for the next try and stops the flush. One it refused is counted and the
-- rest go on; the third refusal in a row holds it until the user presses Sync (retryHeld).
-- `opts.barrier(op)` (optional) says an earlier change must settle first: such a rating is
-- skipped, marked blocked, and does not count as a failure. `on_sent(user_book_id, user_book)`
-- is called for each one that went through. Returns the number still waiting (held, blocked,
-- parked and unowned included).
function RatingQueue:flush(api, on_sent, user_id, opts)
  opts = opts or {}
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
      local mine = op and OfflineQueue.bookOpForUser(op, user_id)
      local barrier = mine and opts.barrier and opts.barrier(op) or nil
      if op and barrier then
        op.blocked, op.blocked_reason = true, barrier
        self:persist()
      elseif op and not op.held and not op.parked and OfflineQueue.bookOpForUser(op, user_id) then
        op.blocked, op.blocked_reason = nil, nil
        local id, err = self:resolveUserBook(api, op, user_id)
        local ready = true

        -- A preflight read is the only way to tell an offline rating from one made online in
        -- the meantime. No catalog id or no lookup method means there is nothing to compare.
        if id and ops[key] == op and op.book_id and type(api.findUserBook) == "function" then
          local record, lookup_err = api:findUserBook(op.book_id, user_id)
          if lookup_err ~= nil then
            if OfflineQueue.transient(lookup_err) then break end
            OfflineQueue.reject(op, lookup_err)
            self:persist()
            ready = false
          elseif ops[key] ~= op then
            -- A newer rating replaced this one while the lookup was out. Its answer belongs
            -- to the old operation and must not acknowledge or park the new one.
            ready = false
          elseif type(record) ~= "table" or record.id == nil then
            -- The record could not be read. Keep the rating for a later pass; sending now
            -- would be a guess about a library entry this device cannot see.
            ready = false
          else
            local online = value(record.rating)
            local outcome = compare(op, online)
            if outcome == "ack" then
              ops[key] = nil
              self:persist()
              ready = false
            elseif outcome == "park" then
              local known, base = baseValue(op)
              op.parked = true
              op.answer = nil
              op.decision = { kind = "rating", online = online, proposed = value(op.rating),
                base = known and base or nil }
              self:persist()
              ready = false
            end
          end
        end

        local user_book
        if ready and id and ops[key] == op and not op.parked then
          user_book, err = api:updateRating(id, tonumber(op.rating), op.at)
        end
        if user_book then
          -- a newer rating made while this one was in flight stays
          if ops[key] == op then ops[key] = nil end
          self:persist()
          if on_sent then on_sent(op.user_book_id, user_book) end
        elseif ready and ops[key] == op and (id or err ~= nil) then
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
