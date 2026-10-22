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

local function storeKey(user_id) return "activity:" .. tostring(user_id or 0) end

-- { entries, more, saved_at } as last saved, or nil.
function ActivityStore:get(user_id)
  if not self.db then return nil end
  local saved = Codec.decode(self.db:getBlob(storeKey(user_id)))
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
  return text and self.db:putBlob(storeKey(user_id), text) or false
end

-- An edit or delete Hardcover took: the saved copy shows it too, so it is right offline before the
-- next refresh. `fields` are set on the entry kept under `key` (text, excerpt, ...); nil deletes it.
-- When the copy is from stays as it was. Returns whether the copy changed.
function ActivityStore:change(user_id, key, fields)
  local saved = self:get(user_id)
  if not saved then return false end
  for i, e in ipairs(saved.entries) do
    if type(e) == "table" and e.key == key then
      if fields then
        for k, v in pairs(fields) do e[k] = v end
      else
        table.remove(saved.entries, i)
      end
      local text = Codec.encode(saved)
      return text and self.db:putBlob(storeKey(user_id), text) or false
    end
  end
  return false
end

return ActivityStore
