-- Reviews written on the book details screen while offline: kept per book, shown at once, sent when
-- online.
--
-- Plain data, no KOReader requires, so it runs under stock Lua in the spec suite. It lives in the
-- same settings file as the progress queue (SyncQueue). One review per book: writing a book's
-- review twice offline leaves the newest. Empty text clears the review.

local OfflineQueue = require("hardcover/lib/offline_queue")

local ReviewQueue = OfflineQueue.extend({})
ReviewQueue.store_key = "review_ops"
-- Publishing a review needs this OAuth scope (ReviewQueue.WRITE_SCOPE is the one place
-- its name is written down for the queues; auth.lua and default_config.lua spell it
-- out in the scope they ask for, and a spec keeps the three in step).
ReviewQueue.WRITE_SCOPE = "write:reviews"

local function valid(op)
  return type(op) == "table" and (op.user_book_id ~= nil or op.book_id ~= nil) and type(op.text) == "string"
end

-- One review value, so the text and the spoiler flag are always compared together.
local function reviewValue(text, spoilers)
  return { text = tostring(text or ""), spoilers = spoilers == true }
end

local function sameReview(a, b)
  return a.text == b.text and a.spoilers == b.spoilers
end

-- What the device last saw on Hardcover: { text, spoilers, known = true }, or "unknown".
local function baseValue(op)
  local base = op and op.base
  if type(base) == "table" and base.known then return true, reviewValue(base.text, base.spoilers) end
  return false
end

function ReviewQueue:valid(op)
  return valid(op)
end

-- waiting reviews by book (older entries use the library record), as stored
function ReviewQueue:ops()
  return self:store()
end

function ReviewQueue:isEmpty()
  return not self:hasPending()
end

-- the waiting review for this library record as { text ("" = a clear), spoilers }, or nil
function ReviewQueue:get(user_book_id, book_id, user_id)
  local _, op = self:bookOpKey(user_book_id, book_id, user_id)
  if valid(op) then return { text = op.text, spoilers = op.spoilers == true } end
end

-- `base` is what the device last saw on Hardcover: { text, spoilers, known = true }, or
-- "unknown". The first write keeps that baseline; another write while it waits keeps the
-- original one. A combined review is the exception: it is based on the online text the reader
-- just compared, so that becomes its baseline.
function ReviewQueue:queue(user_book_id, text, spoilers, title, book_id, user_id, base)
  local key, before = self:bookOpKey(user_book_id, book_id, user_id)
  local next_base
  if before and type(before.combine_online) == "table" then
    next_base = { text = before.combine_online.text, spoilers = before.combine_online.spoilers == true, known = true }
  else
    next_base = (before and before.base) or base or "unknown"
  end
  self:ops()[key] = {
    user_book_id = user_book_id or (before and before.user_book_id), book_id = book_id or (before and before.book_id),
    user_id = user_id or (before and before.user_id), text = text or "", spoilers = spoilers == true, title = title,
    at = os.time(), base = next_base,
  }
  self:persist()
end

-- every waiting review as { user_book_id, text, spoilers, title, held, reason }, in a stable order
function ReviewQueue:list(user_id)
  local out = {}
  for _, op in pairs(self:ops()) do
    if valid(op) and (user_id == nil or OfflineQueue.bookOpForUser(op, user_id)) then
      out[#out + 1] = { user_book_id = op.user_book_id, book_id = op.book_id, user_id = op.user_id,
        text = op.text, spoilers = op.spoilers == true,
        title = op.title, held = op.held, reason = op.reason,
        blocked = op.blocked, blocked_reason = op.blocked_reason,
        parked = op.parked == true, decision = op.decision }
    end
  end
  table.sort(out, function(a, b) return tostring(a.book_id or a.user_book_id) < tostring(b.book_id or b.user_book_id) end)
  return out
end

-- The questions waiting for this account, in the shared shape the review list uses.
function ReviewQueue:decisions(user_id)
  local out = {}
  for key, op in pairs(self:ops()) do
    if valid(op) and op.parked and type(op.decision) == "table"
      and (user_id == nil or OfflineQueue.bookOpForUser(op, user_id)) then
      local decision_key = key
      out[#out + 1] = {
        id = "review:" .. tostring(key), kind = "review", key = key,
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

function ReviewQueue:decisionForBook(book_id, user_id, user_book_id)
  for _, decision in ipairs(self:decisions(user_id)) do
    if (book_id ~= nil and decision.book_id ~= nil and tostring(decision.book_id) == tostring(book_id))
      or (user_book_id ~= nil and decision.user_book_id ~= nil
        and tostring(decision.user_book_id) == tostring(user_book_id)) then
      return decision
    end
  end
end

-- Keep Hardcover's review (drop ours), use this device's, or combine the two in the editor.
-- The device answer is checked against Hardcover again before it is sent.
function ReviewQueue:resolve(key, choice)
  local ops = self:ops()
  local op = ops[key]
  if not (valid(op) and op.parked and type(op.decision) == "table") then return false end
  if choice == "keep_hardcover" then
    ops[key] = nil
  elseif choice == "use_device" then
    op.answer = { online = reviewValue(op.decision.online.text, op.decision.online.spoilers) }
    op.parked, op.decision = nil, nil
  elseif choice == "combine" and not op.decision.delete then
    op.combine_online = reviewValue(op.decision.online.text, op.decision.online.spoilers)
    return true, {
      kind = "combine", title = op.title, book_id = tonumber(op.book_id),
      user_book_id = op.user_book_id, online = op.combine_online,
      device = reviewValue(op.decision.proposed.text, op.decision.proposed.spoilers),
    }
  else
    return false
  end
  self:persist()
  return true, { kind = "review" }
end

-- Reviews waiting for an earlier change (a library removal not settled).
function ReviewQueue:blockedCount(user_id)
  local n = 0
  for _, op in pairs(self:ops()) do
    if valid(op) and op.blocked and (user_id == nil or OfflineQueue.bookOpForUser(op, user_id)) then
      n = n + 1
    end
  end
  return n
end

-- Reviews parked for any reason (held, blocked or waiting for an answer), counting one that is
-- both only once.
function ReviewQueue:parkedCount(user_id)
  local n = 0
  for _, op in pairs(self:ops()) do
    if valid(op) and (op.held or op.blocked or op.parked)
      and (user_id == nil or OfflineQueue.bookOpForUser(op, user_id)) then
      n = n + 1
    end
  end
  return n
end

-- Cancel the review waiting for one book.
function ReviewQueue:cancel(user_book_id, book_id, user_id)
  local ops = self:ops()
  local key = self:bookOpKey(user_book_id, book_id, user_id)
  local had = ops[key] ~= nil
  ops[key] = nil
  self:persist()
  return had
end

-- Compare the fresh online review with the one this device started from, or with the answer
-- already given. "ack" means there is nothing to write; "send" may write; "park" asks.
local function compare(op, online)
  local proposed = reviewValue(op.text, op.spoilers)
  if sameReview(proposed, online) then return "ack" end
  if op.answer and sameReview(op.answer.online, online) then return "send" end
  local known, base = baseValue(op)
  if known and sameReview(base, online) then return "send" end
  return "park"
end

-- Send what is waiting, one request each. A review Hardcover did not answer for stays queued for
-- the next try and stops the flush. One it refused is counted and the rest go on; the third
-- refusal in a row holds it until the user presses Sync (retryHeld). `opts.barrier(op)` (optional)
-- makes a review wait for an earlier change, such as a library removal, without counting it as a
-- failure.
-- `opts`: { json (KOReader's), barrier(op), on_sent(user_book_id, user_book, book_id) for each one
-- that went through }. Returns the number still waiting (held, blocked and parked included).
function ReviewQueue:flush(api, opts)
  opts = opts or {}
  return self:withFlushLock(function() return #self:list(opts.user_id) end, function()
    local ops = self:ops()
    local keys = {}
    for key, op in pairs(ops) do
      if valid(op) then keys[#keys + 1] = key else ops[key] = nil end
    end
    table.sort(keys)

    for _, key in ipairs(keys) do
      local op = ops[key]
      local mine = op and OfflineQueue.bookOpForUser(op, opts.user_id)
      local barrier = mine and opts.barrier and opts.barrier(op) or nil
      if op and barrier then
        op.blocked, op.blocked_reason = true, barrier
        self:persist()
      elseif op and not op.held and not op.parked and OfflineQueue.bookOpForUser(op, opts.user_id) then
        op.blocked, op.blocked_reason = nil, nil
        local id, err = self:resolveUserBook(api, op, opts.user_id)
        local ready = true

        -- Re-read the review before replacing it: an online edit made after this device went
        -- offline must be shown to the reader, not silently overwritten.
        if id and ops[key] == op and op.book_id and type(api.findUserBookForRemoval) == "function" then
          local record, lookup_err = api:findUserBookForRemoval(op.book_id, opts.user_id)
          if lookup_err ~= nil then
            if OfflineQueue.transient(lookup_err) then break end
            OfflineQueue.reject(op, lookup_err)
            self:persist()
            ready = false
          elseif ops[key] ~= op then
            -- A newer review replaced this one while the lookup was out. Its answer belongs
            -- to the old operation and must not acknowledge or park the new one.
            ready = false
          elseif type(record) ~= "table" or record.id == nil then
            -- The record could not be read. Keep the review for a later pass; sending now
            -- would be a guess about a library entry this device cannot see.
            ready = false
          else
            local online = reviewValue(record.review_raw, record.review_has_spoilers)
            local outcome = compare(op, online)
            if outcome == "ack" then
              ops[key] = nil
              self:persist()
              ready = false
            elseif outcome == "park" then
              op.parked = true
              op.answer = nil
              op.decision = { kind = "review", online = online,
                proposed = reviewValue(op.text, op.spoilers), delete = op.text == "",
                base = baseValue(op) and reviewValue(op.base.text, op.base.spoilers) or nil }
              self:persist()
              ready = false
            end
          end
        end

        local user_book
        if ready and id and ops[key] == op and not op.parked then
          user_book, err = api:updateReview(id, op.text, op.spoilers == true, opts.json, op.at)
        end
        if user_book then
          -- a newer review written while this one was in flight stays
          if ops[key] == op then ops[key] = nil end
          self:persist()
          -- the op rides along: an older queue entry can lack a book id the answer carries,
          -- and its title and queued date are what a kept review shows
          if opts.on_sent then opts.on_sent(op.user_book_id, user_book, op.book_id, op) end
        elseif ready and ops[key] == op and (id or err ~= nil) then
          if OfflineQueue.transient(err) then break end
          OfflineQueue.reject(op, err)
          self:persist()
        end
      end
    end
    return #self:list(opts.user_id)
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
