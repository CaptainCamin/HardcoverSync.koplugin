-- Your Activity, kept on the device: the entries the tab last showed (Feed.parse's shape), newest
-- first, so the tab opens at once and opens offline. Up to KEEP entries are kept; a later page that
-- was loaded with Load more is kept too, within that limit.
--
-- Keyed by user, so another account never sees someone else's journal. Pure logic over the same
-- injected store as list_store.lua (getBlob, putBlob); every operation is best-effort.

local Codec = require("hardcover/lib/codec")

local ActivityStore = {}
ActivityStore.__index = ActivityStore

ActivityStore.KEEP = 100

function ActivityStore:new(o)
  o = o or {}
  o.now = o.now or os.time
  return setmetatable(o, self)
end

local function key(user_id) return "activity:" .. tostring(user_id or 0) end

-- { entries, more, saved_at } as last saved, or nil.
function ActivityStore:get(user_id)
  if not self.db then return nil end
  local saved = Codec.decode(self.db:getBlob(key(user_id)))
  if saved and type(saved.entries) == "table" then
    return saved
  end
end

-- Save what the tab shows. `more`: Hardcover has entries older than these (a list cut to KEEP
-- has more too). Returns whether it was saved.
function ActivityStore:put(user_id, entries, more)
  if not self.db or type(entries) ~= "table" then return false end
  local kept = {}
  for i = 1, math.min(#entries, ActivityStore.KEEP) do kept[i] = entries[i] end
  local text = Codec.encode({
    entries = kept,
    more = more == true or #entries > ActivityStore.KEEP,
    saved_at = self.now(),
  })
  return text and self.db:putBlob(key(user_id), text) or false
end

return ActivityStore
