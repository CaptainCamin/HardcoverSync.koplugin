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

local Codec = require("hardcover/lib/codec")
local Lists = require("hardcover/lib/lists")

local ListStore = {}
ListStore.__index = ListStore

function ListStore:new(o)
  o = o or {}
  o.now = o.now or os.time
  return setmetatable(o, self)
end

local function who(user_id) return tostring(user_id or 0) end
local function indexKey(user_id) return "lists:" .. who(user_id) end
local function listKey(user_id, list_id) return "list:" .. who(user_id) .. ":" .. tostring(list_id) end

-- ------------------------------------------------------------------ the index

-- { mine = rows, following = rows, saved_at, checked_at } as last saved, or nil.
-- `checked_at` is when Hardcover last said the lists were as saved (on Home, or when
-- the lists screen fetched them); `saved_at` when they last changed here.
function ListStore:index(user_id)
  local saved = Codec.decode(self.db:getBlob(indexKey(user_id)))
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
  local dropped = false
  if before then
    local still = {}
    for _, row in ipairs(fresh.mine) do still[tostring(row.id)] = true end
    for _, row in ipairs(fresh.following) do still[tostring(row.id)] = true end
    for _, group in ipairs({ before.mine, before.following }) do
      for _, row in ipairs(group) do
        if not still[tostring(row.id)] then
          self.db:dropOwned(listKey(user_id, row.id))
          dropped = true
        end
      end
    end
  end
  if dropped then self.books:evict() end

  local text = Codec.encode(fresh)
  return text and self.db:putBlob(indexKey(user_id), text) or false
end

-- Hardcover says the lists are as saved: note when, so a screen opened shortly after
-- need not ask again (see ListsSync.indexFresh).
function ListStore:markChecked(user_id)
  local saved = self:index(user_id)
  if not saved then return false end
  saved.checked_at = self.now()
  local text = Codec.encode(saved)
  return text and self.db:putBlob(indexKey(user_id), text) or false
end

--
-- A change made on this device (a book put on the list or taken off it, from a book's
-- details): the saved copy of the list no longer matches Hardcover, and the index's count
-- and covers may not either. Both are marked so the next look asks Hardcover again,
-- however recently it was asked, and the list downloads its membership (one request).
--
function ListStore:markStale(user_id, list_id)
  local saved = self:contents(user_id, list_id)
  if saved then
    saved.fingerprint = nil
    local text = Codec.encode(saved)
    if text then self.db:putBlob(listKey(user_id, list_id), text) end
  end
  local index = self:index(user_id)
  if index then
    index.checked_at = nil
    local text = Codec.encode(index)
    if text then self.db:putBlob(indexKey(user_id), text) end
  end
  return true
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
  local saved = Codec.decode(self.db:getBlob(listKey(user_id, list_id)))
  if saved and type(saved.members) == "table" then return saved end
end

-- The list's members, in the list's order ({ list_book_id, position, book_id, date_added }
-- each), and what was saved with them; nil when the list was never saved. None of the
-- books themselves is read.
function ListStore:members(user_id, row)
  local saved = type(row) == "table" and self:contents(user_id, row.id)
  if not saved then return nil end
  return saved.members, saved
end

-- The entries (Lists.entry's shape: the book's row, the list_books id, and `rank` on a
-- ranked list) for these members, in the order given. Only their books are read and
-- decoded. A book whose row is missing is left out.
function ListStore:entriesOf(row, members)
  local ids = {}
  for i, m in ipairs(members) do ids[i] = m.book_id end
  local books = self.books:rows(ids)

  local out = {}
  for _, m in ipairs(members) do
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
  return out
end

-- The list's books as entries, in the list's order. nil when the list was never saved.
function ListStore:entries(user_id, row)
  local members, saved = self:members(user_id, row)
  if not members then return nil end
  return self:entriesOf(row, members), saved
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
  local text = Codec.encode({
    fingerprint = row.fingerprint or Lists.fingerprint(row),
    complete = complete and true or false,
    saved_at = self.now(),
    members = members,
  })
  if not text then return false end
  local ok = self.db:putOwned(listKey(user_id, row.id), ids, text)
  -- a book the list no longer holds may now be held by nothing
  self.books:evict()
  return ok
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

-- ------------------------------------------------------------------ changes made offline

-- Is the book on this saved list? Returns the member ({ list_book_id, position, book_id,
-- date_added }), false when the list is saved whole and the book is not on it, and nil
-- when the saved copy cannot say (never saved, or only part of it).
function ListStore:memberOf(user_id, list_id, book_id)
  local saved = self:contents(user_id, list_id)
  if not saved then return nil end
  book_id = tonumber(book_id)
  for _, m in ipairs(saved.members) do
    if tonumber(m.book_id) == book_id then return m end
  end
  if saved.complete then return false end
  return nil
end

-- The index row of one of your lists, from the saved index.
local function indexRow(index, list_id)
  for _, row in ipairs(index and index.mine or {}) do
    if tostring(row.id) == tostring(list_id) then return row end
  end
end

local function putIndexAsIs(self, user_id, index)
  local text = Codec.encode(index)
  return text and self.db:putBlob(indexKey(user_id), text) or false
end

--
-- A book put on a list from this device while offline. The saved list and its size in the
-- index change at once, so every screen shows it; the fingerprints stay as they were, so
-- the saved copy is not mistaken for out of date and downloaded over the change before it
-- is sent (see markStale for after). A ranked list gets the book last. The book's row must
-- be saved already (opening its details does that), or the list cannot show it.
--
function ListStore:addMember(user_id, list_id, book_id)
  book_id = tonumber(book_id)
  local saved = self:contents(user_id, list_id)
  if not (saved and book_id) then return false end
  for _, m in ipairs(saved.members) do
    if tonumber(m.book_id) == book_id then return false end
  end

  local members, ids = {}, {}
  local last = -1
  for i, m in ipairs(saved.members) do
    members[i] = m
    ids[#ids + 1] = m.book_id
    last = math.max(last, tonumber(m.position) or i - 1)
  end
  members[#members + 1] = { position = last + 1, book_id = book_id, date_added = os.date("%Y-%m-%d") }
  ids[#ids + 1] = book_id

  local text = Codec.encode({
    fingerprint = saved.fingerprint, complete = saved.complete, saved_at = self.now(), members = members,
  })
  if not text then return false end
  self.db:putOwned(listKey(user_id, list_id), ids, text)

  local index = self:index(user_id)
  local row = indexRow(index, list_id)
  if row then
    row.count = (tonumber(row.count) or 0) + 1
    putIndexAsIs(self, user_id, index)
  end
  return true
end

-- A book taken off a list from this device while offline (see addMember).
function ListStore:removeMember(user_id, list_id, book_id)
  book_id = tonumber(book_id)
  local saved = self:contents(user_id, list_id)
  if not (saved and book_id) then return false end

  local members, ids, found = {}, {}, false
  for _, m in ipairs(saved.members) do
    if tonumber(m.book_id) == book_id then
      found = true
    else
      members[#members + 1] = m
      ids[#ids + 1] = m.book_id
    end
  end
  if not found then return false end

  local text = Codec.encode({
    fingerprint = saved.fingerprint, complete = saved.complete, saved_at = self.now(), members = members,
  })
  if not text then return false end
  self.db:putOwned(listKey(user_id, list_id), ids, text)
  self.books:evict()

  local index = self:index(user_id)
  local row = indexRow(index, list_id)
  if row then
    row.count = math.max(0, (tonumber(row.count) or 0) - 1)
    putIndexAsIs(self, user_id, index)
  end
  return true
end

return ListStore
