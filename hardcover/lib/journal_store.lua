-- Your journal, kept on the device: the entries the Journal tab last showed (Journal.parse's shape),
-- newest first, so the tab opens at once and opens offline. Up to KEEP entries are kept; a later
-- page that was loaded with Load more is kept too, within that limit.
--
-- Keyed by user, so another account never sees someone else's journal. Pure logic over the same
-- injected store as list_store.lua (getBlob, putBlob); every operation is best-effort.

local Codec = require("hardcover/lib/codec")

local JournalStore = {}
JournalStore.__index = JournalStore

JournalStore.KEEP = 100

function JournalStore:new(o)
  o = o or {}
  o.now = o.now or os.time
  return setmetatable(o, self)
end

-- (the Activity tab kept its entries, of another shape, under "activity:<user>": they are not read)
local function storeKey(user_id) return "journal:" .. tostring(user_id or 0) end

-- { entries, more, saved_at } as last saved, or nil.
function JournalStore:get(user_id)
  if not self.db then return nil end
  local saved = Codec.decode(self.db:getBlob(storeKey(user_id)))
  if saved and type(saved.entries) == "table" then
    return saved
  end
end

-- Save what the tab shows. `more`: Hardcover has entries older than these (a list cut to KEEP
-- has more too). Returns whether it was saved.
function JournalStore:put(user_id, entries, more)
  if not self.db or type(entries) ~= "table" then return false end
  local kept = {}
  for i = 1, math.min(#entries, JournalStore.KEEP) do kept[i] = entries[i] end
  local text = Codec.encode({
    entries = kept,
    more = more == true or #entries > JournalStore.KEEP,
    saved_at = self.now(),
  })
  return text and self.db:putBlob(storeKey(user_id), text) or false
end

--
-- An edit or delete Hardcover took: the saved copy shows it too, so it is right offline before the
-- next refresh. `match` is an entry's key, or function(entry) -> true for every entry it is about
-- (a review is on each "reviewed" entry of its book). `fields` are set on each (text, excerpt, ...;
-- `false` clears one); nil deletes them. When the copy is from stays as it was. Returns whether the
-- copy changed.
--
function JournalStore:change(user_id, match, fields)
  local saved = self:get(user_id)
  if not saved then return false end
  local test = type(match) == "function" and match or function(e) return e.key == match end
  local kept, changed = {}, false
  for _, e in ipairs(saved.entries) do
    if type(e) == "table" and test(e) then
      changed = true
      if fields then
        for k, v in pairs(fields) do
          if v == false then e[k] = nil else e[k] = v end
        end
        kept[#kept + 1] = e
      end
    else
      kept[#kept + 1] = e
    end
  end
  if not changed then return false end
  saved.entries = kept
  local text = Codec.encode(saved)
  return text and self.db:putBlob(storeKey(user_id), text) or false
end

return JournalStore
