-- Your lists, kept on the device: the index (yours and the ones you follow, as
-- Lists.normalize shapes them) and, for each list, which books it holds and in what
-- order. The books themselves are in the book store, once each.
--
-- A saved list remembers the list's fingerprint (Lists.fingerprint: when Hardcover last
-- changed it, and how many books it holds) as it was when its download began. A list
-- whose fingerprint has not moved since is not downloaded again (see lists_sync.lua).
--
-- Keyed by user, so another account never sees someone else's lists. Pure logic over
-- the same injected store as book_store.lua; every operation is best-effort.

local json = require("json")
local Lists = require("hardcover/lib/lists")

local ListStore = {}
ListStore.__index = ListStore

function ListStore:new(o)
  o = o or {}
  o.now = o.now or os.time
  return setmetatable(o, self)
end

local function encode(value)
  local ok, text = pcall(json.encode, value)
  return ok and type(text) == "string" and text or nil
end

local function decode(text)
  if type(text) ~= "string" then return nil end
  local ok, value = pcall(json.decode, text, json.decode.simple)
  return ok and type(value) == "table" and value or nil
end

local function who(user_id) return tostring(user_id or 0) end
local function indexKey(user_id) return "lists:" .. who(user_id) end
local function listKey(user_id, list_id) return "list:" .. who(user_id) .. ":" .. tostring(list_id) end

-- ------------------------------------------------------------------ the index

-- { mine = rows, following = rows, saved_at, checked_at } as last saved, or nil.
-- `checked_at` is when Hardcover last said the lists were as saved (on Home, or when
-- the lists screen fetched them); `saved_at` when they last changed here.
function ListStore:index(user_id)
  local saved = decode(self.db:getBlob(indexKey(user_id)))
  if saved and type(saved.mine) == "table" and type(saved.following) == "table" then
    return saved
  end
end

-- Save a fresh index (Api:getLists's answer). A list that is no longer in it (deleted,
-- unfollowed) is forgotten along with its books' hold on the store.
function ListStore:putIndex(user_id, lists)
  if type(lists) ~= "table" then return false end
  local now = self.now()
  local fresh = {
    mine = type(lists.mine) == "table" and lists.mine or {},
    following = type(lists.following) == "table" and lists.following or {},
    saved_at = now,
    checked_at = now,
  }

  local before = self:index(user_id)
  if before then
    local still = {}
    for _, row in ipairs(fresh.mine) do still[tostring(row.id)] = true end
    for _, row in ipairs(fresh.following) do still[tostring(row.id)] = true end
    for _, group in ipairs({ before.mine, before.following }) do
      for _, row in ipairs(group) do
        if not still[tostring(row.id)] then self.db:dropOwned(listKey(user_id, row.id)) end
      end
    end
  end

  local text = encode(fresh)
  return text and self.db:putBlob(indexKey(user_id), text) or false
end

-- Hardcover says the lists are as saved: note when, so a screen opened shortly after
-- need not ask again (see ListsSync.indexFresh).
function ListStore:markChecked(user_id)
  local saved = self:index(user_id)
  if not saved then return false end
  saved.checked_at = self.now()
  local text = encode(saved)
  return text and self.db:putBlob(indexKey(user_id), text) or false
end

-- Every list in the index, yours first.
function ListStore.allRows(index)
  local out = {}
  for _, group in ipairs({ index and index.mine or {}, index and index.following or {} }) do
    for _, row in ipairs(group) do out[#out + 1] = row end
  end
  return out
end

-- ------------------------------------------------------------------ one list

-- { fingerprint, complete, saved_at, members = { { list_book_id, position, book_id,
-- date_added }, ... } } as last saved, or nil when this list was never saved.
function ListStore:contents(user_id, list_id)
  local saved = decode(self.db:getBlob(listKey(user_id, list_id)))
  if saved and type(saved.members) == "table" then return saved end
end

-- The list's books as shelf entries (Lists.entry's shape: the book's row, the
-- list_books id, and `rank` on a ranked list), in the list's order. nil when the list
-- was never saved; a book whose row is missing is left out.
function ListStore:entries(user_id, row)
  local saved = type(row) == "table" and self:contents(user_id, row.id)
  if not saved then return nil end

  local ids = {}
  for i, m in ipairs(saved.members) do ids[i] = m.book_id end
  local books = self.books:rows(ids)

  local out = {}
  for _, m in ipairs(saved.members) do
    local book = books[tonumber(m.book_id)]
    if book then
      local entry = {}
      for k, v in pairs(book) do entry[k] = v end
      entry.list_book_id = m.list_book_id
      entry.date_added = m.date_added
      entry.position = m.position
      if row.ranked and tonumber(m.position) then entry.rank = tonumber(m.position) + 1 end
      out[#out + 1] = entry
    end
  end
  return out, saved
end

local function membersOf(entries)
  local members, ids = {}, {}
  for i, e in ipairs(entries) do
    local book_id = tonumber(e.book_id)
    if book_id then
      members[#members + 1] = {
        list_book_id = e.list_book_id,
        position = tonumber(e.position) or (e.rank and e.rank - 1) or (i - 1),
        book_id = book_id,
        date_added = e.date_added,
      }
      ids[#ids + 1] = book_id
    end
  end
  return members, ids
end

local function save(self, user_id, row, members, ids, complete)
  local text = encode({
    fingerprint = row.fingerprint or Lists.fingerprint(row),
    complete = complete and true or false,
    saved_at = self.now(),
    members = members,
  })
  if not text then return false end
  return self.db:putOwned(listKey(user_id, row.id), ids, text)
end

--
-- A list downloaded in full (Api:getListBooks's entries): its books go into the book
-- store and the list remembers which they are. `row` is the index row the download was
-- for; its fingerprint is the one saved, so a change made while the download ran is
-- seen next time.
--
function ListStore:putEntries(user_id, row, entries, complete)
  if type(row) ~= "table" or type(entries) ~= "table" then return false end
  local members, ids = membersOf(entries)
  self.books:saveRows(entries)
  return save(self, user_id, row, members, ids, complete)
end

-- A list re-downloaded as membership only (Api:getListMembers's rows); the books not
-- saved yet were fetched and saved by the caller.
function ListStore:putMembers(user_id, row, members, complete)
  if type(row) ~= "table" or type(members) ~= "table" then return false end
  local kept, ids = membersOf(members)
  return save(self, user_id, row, kept, ids, complete)
end

return ListStore
