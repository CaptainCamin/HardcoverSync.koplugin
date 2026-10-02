-- Keeps your shelves on disk so they can be browsed offline.
--
-- One record per shelf: the whole list as it was last loaded, whether that load
-- reached the end, and when. Pure logic: the store is injected (`open(path)`
-- returns a LuaSettings-like object) and opened on first use, so requiring this
-- costs nothing at startup and nothing is read until a shelf is opened.
--
-- A shelf is the pair (user, status). Keying on the user means a different
-- account never sees someone else's cached library.
--
-- Every operation is best-effort: a cache that cannot be read or written must
-- never break the screen that asked for it.

local ShelfCache = {}
ShelfCache.__index = ShelfCache

-- The cache is for browsing, not a mirror of a very large library, and the
-- whole file is read when a shelf is opened. Past this a shelf is kept as an
-- incomplete list.
local MAX_ENTRIES = 3000

-- Descriptions dominate the size of a row. Enough is kept to read offline; the
-- full text comes with the network.
local MAX_DESCRIPTION = 600

function ShelfCache:new(o)
  return setmetatable(o or {}, self)
end

-- false (not nil) once opening has failed, so a broken file is not retried on
-- every call
function ShelfCache:_store()
  if self.store == nil then
    local ok, store = pcall(self.open, self.path)
    self.store = ok and store or false
  end
  return self.store or nil
end

local function shelfKey(user_id, status_id)
  return tostring(user_id or 0) .. ":" .. tostring(status_id or "all")
end

-- Cut a string to at most `limit` bytes without leaving half of a UTF-8
-- character at the end.
local function truncate(text, limit)
  if type(text) ~= "string" or #text <= limit then
    return text
  end
  local cut = text:sub(1, limit)
  -- drop continuation bytes (10xxxxxx), then a dangling lead byte (11xxxxxx)
  while #cut > 0 and cut:byte(#cut) >= 0x80 and cut:byte(#cut) < 0xC0 do
    cut = cut:sub(1, #cut - 1)
  end
  if #cut > 0 and cut:byte(#cut) >= 0xC0 then
    cut = cut:sub(1, #cut - 1)
  end
  -- the ellipsis as bytes (U+2026), so this reads the same on any Lua
  return cut .. "\226\128\166"
end

-- { entries = {...}, complete = bool, saved_at = os.time() } or nil
function ShelfCache:get(user_id, status_id)
  local store = self:_store()
  local shelves = store and store:readSetting("shelves")
  local shelf = shelves and shelves[shelfKey(user_id, status_id)]
  if shelf and type(shelf.entries) == "table" then
    return shelf
  end
end

-- `complete` says the list reaches the end of the shelf; a partial list is
-- kept so something can still be shown offline, but is marked.
function ShelfCache:put(user_id, status_id, entries, complete)
  if type(entries) ~= "table" then
    return false
  end

  local store = self:_store()
  if not store then return false end

  local kept = {}
  for i, entry in ipairs(entries) do
    if i > MAX_ENTRIES then
      complete = false
      break
    end
    local copy = {}
    for k, v in pairs(entry) do copy[k] = v end
    copy.description = truncate(copy.description, MAX_DESCRIPTION)
    kept[i] = copy
  end

  local shelves = store:readSetting("shelves")
  if not shelves then
    shelves = {}
    store:saveSetting("shelves", shelves)
  end
  shelves[shelfKey(user_id, status_id)] = {
    entries = kept,
    complete = complete and true or false,
    saved_at = os.time(),
  }

  return (pcall(store.flush, store))
end

-- How many books each shelf held when last counted, { [status_id] = n }.
--
-- A count saved from the server wins; otherwise a shelf that was loaded in full
-- is as good a count as any. A shelf with neither has no entry, so the caller can
-- show nothing instead of a made up zero.
function ShelfCache:counts(user_id, status_ids)
  local store = self:_store()
  local out = {}
  if not store then return out end

  local saved = store:readSetting("counts")
  local mine = saved and saved[tostring(user_id or 0)]

  for _, status_id in ipairs(status_ids or {}) do
    local n = mine and mine["s" .. status_id]
    if n == nil then
      local shelf = self:get(user_id, status_id)
      if shelf and shelf.complete then n = #shelf.entries end
    end
    if n ~= nil then out[status_id] = n end
  end
  return out
end

function ShelfCache:putCounts(user_id, counts)
  local store = self:_store()
  if not store or type(counts) ~= "table" then return false end

  local saved = store:readSetting("counts")
  if not saved then
    saved = {}
    store:saveSetting("counts", saved)
  end

  local mine = {}
  for status_id, n in pairs(counts) do
    mine["s" .. status_id] = n
  end
  saved[tostring(user_id or 0)] = mine

  return (pcall(store.flush, store))
end

-- The "currently reading" list for the home screen, as last loaded. Kept apart
-- from the shelves: it is a short, differently shaped list (with progress) and
-- must not stand in for a shelf. `entries` may be empty, which is a real answer
-- (nothing being read); nil means never saved.
function ShelfCache:reading(user_id)
  local store = self:_store()
  local saved = store and store:readSetting("reading")
  local mine = saved and saved[tostring(user_id or 0)]
  if mine and type(mine.entries) == "table" then
    return mine.entries
  end
end

function ShelfCache:putReading(user_id, entries)
  local store = self:_store()
  if not store or type(entries) ~= "table" then return false end

  local saved = store:readSetting("reading")
  if not saved then
    saved = {}
    store:saveSetting("reading", saved)
  end

  local kept = {}
  for i, entry in ipairs(entries) do
    local copy = {}
    for k, v in pairs(entry) do copy[k] = v end
    copy.description = nil
    kept[i] = copy
  end
  saved[tostring(user_id or 0)] = { entries = kept, saved_at = os.time() }

  return (pcall(store.flush, store))
end

-- The cached row for a book, from any of this user's shelves. Lets a book's
-- details be shown offline from what the shelf already had.
function ShelfCache:findEntry(user_id, book_id)
  local store = self:_store()
  local shelves = store and store:readSetting("shelves")
  if not shelves or not book_id then return nil end

  local prefix = tostring(user_id or 0) .. ":"
  for key, shelf in pairs(shelves) do
    if key:sub(1, #prefix) == prefix then
      for _, entry in ipairs(shelf.entries or {}) do
        if entry.book_id == book_id then
          return entry
        end
      end
    end
  end
end

-- Everything, for sign out: the cache holds a user's library.
function ShelfCache:clear()
  local store = self:_store()
  if not store then return false end
  store:saveSetting("shelves", nil)
  store:saveSetting("counts", nil)
  store:saveSetting("reading", nil)
  return (pcall(store.flush, store))
end

return ShelfCache
