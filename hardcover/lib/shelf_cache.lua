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
-- Two files, because they are used very differently. The shelves are large (about
-- 2 KB a book, so a 600 book shelf is over a megabyte, and a file of several
-- shelves several megabytes) and only a shelf screen or a book's details need
-- them. The counts and the reading list are tiny and are what the home screen
-- reads and rewrites every time it opens, and the reading list changes whenever
-- progress does. Kept in one file, opening Home parsed all the shelves and every
-- change to a count rewrote them; kept apart, Home touches only the small file.
-- (Counts and a reading list saved by an earlier version are still read from the
-- shelf file until they are saved again.)
--
-- Saving what is already saved writes nothing: the home screen saves what it has
-- just fetched, which for an unchanged library is the very same.
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

-- The small file's store: counts and the reading list. false once opening failed.
function ShelfCache:_home()
  if self.home == nil then
    local path = self.home_path or (self.path and (self.path:gsub("%.lua$", "") .. "_home.lua"))
    local ok, store = pcall(self.open, path)
    self.home = ok and store or false
  end
  return self.home or nil
end

-- A saved table of this name: the small file's, else (saved by an earlier
-- version) the shelf file's. `name` is "counts" or "reading".
function ShelfCache:_read(name)
  local home = self:_home()
  local saved = home and home:readSetting(name)
  if saved ~= nil then return saved end
  local store = self:_store()
  return store and store:readSetting(name) or nil
end

-- Structural equality of plain data (rows are tables of strings, numbers and
-- nested tables).
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not same(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
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

  -- the list that was just loaded is the one already saved (the usual case when
  -- a shelf is opened again): nothing to write, unless the saved day would be
  -- out of date, which is the one thing a reader sees of it
  local saved = shelves[shelfKey(user_id, status_id)]
  if saved and saved.complete == (complete and true or false) and same(saved.entries, kept)
    and os.date("%Y-%m-%d", saved.saved_at or 0) == os.date("%Y-%m-%d") then
    return true
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
  local out = {}
  if not (self:_home() or self:_store()) then return out end

  local saved = self:_read("counts")
  local mine = saved and saved[tostring(user_id or 0)]

  for _, status_id in ipairs(status_ids or {}) do
    local n = mine and mine["s" .. status_id]
    if n == nil then
      -- only now is the (large) shelf file read
      local shelf = self:get(user_id, status_id)
      if shelf and shelf.complete then n = #shelf.entries end
    end
    if n ~= nil then out[status_id] = n end
  end
  return out
end

function ShelfCache:putCounts(user_id, counts)
  local store = self:_home()
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
  local who = tostring(user_id or 0)
  if same(saved[who], mine) then return true end
  saved[who] = mine

  return (pcall(store.flush, store))
end

-- The "currently reading" list for the home screen, as last loaded. Kept apart
-- from the shelves: it is a short, differently shaped list (with progress) and
-- must not stand in for a shelf. `entries` may be empty, which is a real answer
-- (nothing being read); nil means never saved.
function ShelfCache:reading(user_id)
  local saved = self:_read("reading")
  local mine = saved and saved[tostring(user_id or 0)]
  if mine and type(mine.entries) == "table" then
    return mine.entries
  end
end

function ShelfCache:putReading(user_id, entries)
  local store = self:_home()
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
  local who = tostring(user_id or 0)
  if saved[who] and same(saved[who].entries, kept) then return true end
  saved[who] = { entries = kept, saved_at = os.time() }

  return (pcall(store.flush, store))
end

-- The "For you" picks as last loaded, and when (nil when never saved). Kept in the small
-- home file, apart from the shelves.
function ShelfCache:forYou(user_id)
  local home = self:_home()
  local saved = home and home:readSetting("for_you")
  local mine = saved and saved[tostring(user_id or 0)]
  if mine and type(mine.entries) == "table" then
    return mine.entries, mine.saved_at
  end
end

function ShelfCache:putForYou(user_id, entries)
  local home = self:_home()
  if not home or type(entries) ~= "table" then return false end

  local saved = home:readSetting("for_you")
  if not saved then
    saved = {}
    home:saveSetting("for_you", saved)
  end
  local kept = {}
  for i, entry in ipairs(entries) do
    local copy = {}
    for k, v in pairs(entry) do copy[k] = v end
    copy.description = nil
    kept[i] = copy
  end
  saved[tostring(user_id or 0)] = { entries = kept, saved_at = os.time() }
  return (pcall(home.flush, home))
end

-- Your goals, as last loaded (a list of Goals.normalize rows) and when. nil when
-- never saved; an empty list is a real answer (no goals).
function ShelfCache:goals(user_id)
  local store = self:_store()
  local saved = store and store:readSetting("goals")
  local mine = saved and saved[tostring(user_id or 0)]
  if mine and type(mine.goals) == "table" then
    return mine.goals, mine.saved_at
  end
end

function ShelfCache:putGoals(user_id, goals)
  local store = self:_store()
  if not store or type(goals) ~= "table" then return false end

  local saved = store:readSetting("goals")
  if not saved then
    saved = {}
    store:saveSetting("goals", saved)
  end
  local kept = {}
  for i, goal in ipairs(goals) do
    local copy = {}
    for k, v in pairs(goal) do copy[k] = v end
    kept[i] = copy
  end
  saved[tostring(user_id or 0)] = { goals = kept, saved_at = os.time() }
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

-- Forget what is saved about a user's library that a change of shelf makes
-- wrong: the lists for `status_ids` (a book left one and joined another), the
-- list with no status filter, the shelf counts and the reading list. Other
-- shelves are untouched, and so is every other user's data. The next time the
-- home screen or a shelf is opened it loads fresh numbers.
function ShelfCache:invalidate(user_id, status_ids)
  local store = self:_store()
  if not store then return false end

  local shelves = store:readSetting("shelves")
  if shelves then
    shelves[shelfKey(user_id, nil)] = nil
    for _, status_id in ipairs(status_ids or {}) do
      shelves[shelfKey(user_id, status_id)] = nil
    end
  end

  -- counts and the reading list: the small file, and what an earlier version
  -- saved in the shelf file
  local who = tostring(user_id or 0)
  local home = self:_home()
  for _, name in ipairs({ "counts", "reading" }) do
    local legacy = store:readSetting(name)
    if legacy then legacy[who] = nil end
    if home then
      local mine = home:readSetting(name)
      if not mine then
        -- present but empty, so the older copy is not consulted again
        mine = {}
        home:saveSetting(name, mine)
      end
      mine[who] = nil
    end
  end

  local ok = (pcall(store.flush, store))
  if home and home ~= store then ok = (pcall(home.flush, home)) and ok end
  return ok
end

-- Everything, for sign out: the cache holds a user's library.
function ShelfCache:clear()
  local store = self:_store()
  if not store then return false end
  store:saveSetting("shelves", nil)
  store:saveSetting("counts", nil)
  store:saveSetting("reading", nil)
  store:saveSetting("goals", nil)
  local ok = (pcall(store.flush, store))

  local home = self:_home()
  if home and home ~= store then
    home:saveSetting("counts", nil)
    home:saveSetting("reading", nil)
    home:saveSetting("for_you", nil)
    ok = (pcall(home.flush, home)) and ok
  end
  return ok
end

return ShelfCache
