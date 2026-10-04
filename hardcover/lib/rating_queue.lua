-- Ratings set from the book details screen while offline, shown at once and sent
-- when the connection is back.
--
-- Plain data, no KOReader requires, so it runs under stock Lua in the spec suite.
-- It lives in the same settings file as the progress queue (SyncQueue). One
-- rating per book: rating a book twice offline leaves the newest. A rating of 0
-- clears it.

local RatingQueue = {}
RatingQueue.__index = RatingQueue

function RatingQueue:new(o)
  o = o or {}
  setmetatable(o, self)
  return o
end

function RatingQueue:ops()
  local ops = self.settings:readSetting("rating_ops")
  if type(ops) ~= "table" then
    ops = {}
    self.settings:saveSetting("rating_ops", ops)
  end
  return ops
end

function RatingQueue:persist()
  if self.settings.flush then self.settings:flush() end
end

local function valid(op)
  return type(op) == "table" and op.user_book_id ~= nil and tonumber(op.rating) ~= nil
end

function RatingQueue:count()
  local n = 0
  for _, op in pairs(self:ops()) do
    if valid(op) then n = n + 1 end
  end
  return n
end

function RatingQueue:isEmpty()
  return self:count() == 0
end

-- the rating waiting for this library record (0 = a clear), or nil
function RatingQueue:get(user_book_id)
  local op = self:ops()[tostring(user_book_id)]
  if valid(op) then return tonumber(op.rating) end
end

function RatingQueue:queue(user_book_id, rating, title)
  self:ops()[tostring(user_book_id)] = { user_book_id = user_book_id, rating = rating, title = title }
  self:persist()
end

-- every waiting rating as { user_book_id, rating (0 = a clear), title }, in a stable order
function RatingQueue:list()
  local out = {}
  for _, op in pairs(self:ops()) do
    if valid(op) then
      out[#out + 1] = { user_book_id = op.user_book_id, rating = tonumber(op.rating), title = op.title }
    end
  end
  table.sort(out, function(a, b) return tostring(a.user_book_id) < tostring(b.user_book_id) end)
  return out
end

-- Cancel the rating waiting for one book.
function RatingQueue:cancel(user_book_id)
  local ops = self:ops()
  local had = ops[tostring(user_book_id)] ~= nil
  ops[tostring(user_book_id)] = nil
  self:persist()
  return had
end

-- Send what is waiting, one request each. A rating Hardcover did not answer for
-- stays queued for the next try. `on_sent(user_book_id, user_book)` is called for
-- each one that went through. Returns the number still waiting.
function RatingQueue:flush(api, on_sent)
  local ops = self:ops()
  local keys = {}
  for key, op in pairs(ops) do
    if valid(op) then keys[#keys + 1] = key else ops[key] = nil end
  end
  table.sort(keys)

  for _, key in ipairs(keys) do
    local op = ops[key]
    local user_book = api:updateRating(op.user_book_id, tonumber(op.rating))
    if not user_book then break end
    -- a newer rating made while this one was in flight stays
    if ops[key] == op then ops[key] = nil end
    self:persist()
    if on_sent then on_sent(op.user_book_id, user_book) end
  end
  return self:count()
end

return RatingQueue
