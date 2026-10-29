-- What the offline queues have in common: progress and statuses (SyncQueue), goal
-- changes (GoalQueue) and ratings (RatingQueue) each keep changes made without a
-- connection in the settings file and send them later. Their data and their rules
-- differ (a page and a status per book; a whole goal record; one rating per book),
-- so each keeps its own enqueue, apply and flush. This holds the rest, so a screen or
-- the sync can treat them alike:
--
--   count()       how many changes are waiting
--   hasPending()  whether any is
--   heldCount()   how many of those are held, waiting for the user
--   retryHeld()   let held ones try again (nothing is held in a queue that never holds)
--
-- plus the storage (store, persist) and a lock for flush that is always released.
--
-- A queue says what it keeps by setting, on its class:
--   store_key   the settings key its data lives under
--   iterate     pairs (the default, a table keyed by file or id) or ipairs (a list)
-- and what a well-formed entry is, by defining valid(entry). A queue that can hold
-- entries defines isHeld(entry) too; the default is an entry's `held` field.
--
-- Beware the name: SyncQueue:isEmpty(entry) asks about ONE entry, where GoalQueue and
-- RatingQueue have isEmpty() for the whole queue. Use hasPending() on anything that
-- might be any of the three.
--
-- Plain data, no KOReader requires, so it runs under stock Lua in the spec suite.

local Lists = require("hardcover/lib/lists")

local OfflineQueue = {}
OfflineQueue.__index = OfflineQueue

-- A change Hardcover refused (or that needs a permission the sign-in lacks) this many
-- flushes in a row is held: it stays, shown as waiting, until the user acts.
OfflineQueue.MAX_REJECTIONS = 3

-- Is this the kind of failure that says nothing about the change itself? (no answer,
-- a timeout, a busy or broken server.) Those are tried again later without counting.
function OfflineQueue.transient(err)
  if err == nil then return true end
  if type(err) == "string" then return false end -- Hardcover's own words: a refusal
  if type(err) ~= "table" then return true end
  if err.completed == false or err.error == "no_response" then return true end
  local status = tonumber(err.status)
  if status == nil then return err.errors == nil end
  return status == 429 or status >= 500
end

-- Count a refusal against `op`: a missing scope holds it at once (reason "scope"), the
-- third refusal in a row holds it too (reason "refused").
function OfflineQueue.reject(op, err)
  op.failures = (op.failures or 0) + 1
  if Lists.isScopeError(err) then
    op.held, op.reason = true, "scope"
  elseif op.failures >= OfflineQueue.MAX_REJECTIONS then
    op.held, op.reason = true, "refused"
  end
end

OfflineQueue.iterate = pairs

-- Make `class` a queue: it looks things up here when it does not have them itself.
function OfflineQueue.extend(class)
  class.__index = class
  return setmetatable(class, { __index = OfflineQueue })
end

function OfflineQueue:new(o)
  o = o or {}
  setmetatable(o, self)
  o.flushing = false
  return o
end

-- The queue's data, made on first use. The table itself, not a copy: LuaSettings
-- hands out the stored table, and callers change entries in place.
function OfflineQueue:store()
  local data = self.settings:readSetting(self.store_key)
  if type(data) ~= "table" then
    data = {}
    self.settings:saveSetting(self.store_key, data)
  end
  return data
end

function OfflineQueue:persist()
  if self.settings.flush then self.settings:flush() end
end

-- Ratings and reviews can precede the library record. Keep their identity stable when that
-- record arrives, including queues saved by older versions with only a user_book_id.
function OfflineQueue.bookOpForUser(op, user_id)
  if op.user_id ~= nil then return tostring(op.user_id) == tostring(user_id) end
  -- Legacy operations are bound to a library record already. Unowned catalog-only text must
  -- never be rebound to whichever account happens to sign in next.
  return op.user_book_id ~= nil
end

function OfflineQueue:bookOpKey(user_book_id, book_id, user_id)
  for key, op in pairs(self:store()) do
    if self:valid(op) and (user_id == nil or OfflineQueue.bookOpForUser(op, user_id))
      and ((book_id ~= nil and tostring(op.book_id) == tostring(book_id))
      or (user_book_id ~= nil and tostring(op.user_book_id) == tostring(user_book_id))) then
      return key, op
    end
  end
  local key = book_id ~= nil and ("book:" .. tostring(book_id)) or tostring(user_book_id)
  return user_id ~= nil and (tostring(user_id) .. ":" .. key) or key
end

-- Status/shelf queues run first. If their record is not available yet, leave this change waiting;
-- do not invent a shelf or send an update with the catalog book ID in place of the library ID.
function OfflineQueue:resolveUserBook(api, op, user_id)
  if not OfflineQueue.bookOpForUser(op, user_id) then return nil end
  if op.user_book_id then return op.user_book_id end
  if not user_id then return nil end
  local book, err = api:findUserBook(op.book_id, user_id)
  if not (book and book.id) then return nil, err end
  op.user_book_id = book.id
  self:persist()
  return book.id
end

function OfflineQueue:isHeld(entry)
  return type(entry) == "table" and entry.held and true or false
end

function OfflineQueue:count()
  local n = 0
  for _, entry in self.iterate(self:store()) do
    if self:valid(entry) then n = n + 1 end
  end
  return n
end

function OfflineQueue:hasPending()
  return self:count() > 0
end

function OfflineQueue:heldCount(user_id)
  local n = 0
  for _, entry in self.iterate(self:store()) do
    if self:valid(entry) and self:isHeld(entry)
      and (user_id == nil or entry.user_id == nil or tostring(entry.user_id) == tostring(user_id)) then n = n + 1 end
  end
  return n
end

function OfflineQueue:retryHeld()
end

--
-- Run a flush with the lock held. A flush yields to the UI while a request is out, so
-- a second one can start meanwhile; it gets `busy` (a value, or a function returning
-- one) instead. The lock is released whether `fn` returns or raises: a flush that
-- threw must not leave every later one refused until KOReader restarts. A raised
-- error is passed on.
--
function OfflineQueue:withFlushLock(busy, fn)
  if self.flushing then
    if type(busy) == "function" then return busy() end
    return busy
  end
  self.flushing = true
  local ok, result = pcall(fn)
  self.flushing = false
  if not ok then error(result, 0) end
  return result
end

return OfflineQueue
