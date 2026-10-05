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

local OfflineQueue = {}
OfflineQueue.__index = OfflineQueue

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

function OfflineQueue:heldCount()
  local n = 0
  for _, entry in self.iterate(self:store()) do
    if self:valid(entry) and self:isHeld(entry) then n = n + 1 end
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
