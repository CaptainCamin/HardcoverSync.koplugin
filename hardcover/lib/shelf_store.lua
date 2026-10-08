-- Your shelves, kept on the device: which books are on each (with your status, rating
-- and when they were added), in the shelf's order. The books themselves are in the
-- book store, once each, shared with the lists.
--
-- Each shelf remembers the fingerprint it was saved with (Shelf.fingerprint: how many
-- books, the latest change, the total of your ratings), as Hardcover gave it just before
-- the download began. A shelf whose fingerprint has not moved since is not downloaded
-- again (see shelves_sync.lua).
--
-- A change made on this device (a book moved, rated, removed) is made here at once, and
-- the shelf is marked so the next look asks Hardcover again: the saved copy is right in
-- the meantime, and Hardcover's word replaces it as soon as there is a connection.
--
-- Keyed by user. Pure logic over the same injected store as book_store.lua.

local BookStore = require("hardcover/lib/book_store")
local Codec = require("hardcover/lib/codec")

local ShelfStore = {}
ShelfStore.__index = ShelfStore

function ShelfStore:new(o)
  o = o or {}
  o.now = o.now or os.time
  return setmetatable(o, self)
end

local function who(user_id) return tonumber(user_id) or 0 end
local function metaKey(user_id, status_id) return "shelf:" .. tostring(who(user_id)) .. ":" .. tostring(status_id) end

-- { fingerprint, complete, saved_at, checked_at } as last saved, or nil when the shelf
-- was never saved. `checked_at` is when Hardcover last said the shelf is as saved.
function ShelfStore:meta(user_id, status_id)
  local meta = Codec.decode(self.db:getBlob(metaKey(user_id, status_id)))
  if meta and meta.saved_at then return meta end
end

local function putMeta(self, user_id, status_id, meta)
  local text = Codec.encode(meta)
  return text and self.db:putBlob(metaKey(user_id, status_id), text) or false
end

-- A shelf entry (Shelf.normalizeEntry's shape) from a saved book row and its shelf row.
local function entryOf(row, member)
  local entry = {}
  for k, v in pairs(row) do entry[k] = v end
  entry.user_book_id = member.user_book_id
  entry.status_id = member.status_id
  entry.user_rating = member.rating
  entry.date_added = member.date_added
  return entry
end

-- The shelf's books as shelf entries, in Hardcover's order, and its meta; nil when the
-- shelf was never saved. A book whose row is missing is left out.
function ShelfStore:entries(user_id, status_id)
  local meta = self:meta(user_id, status_id)
  if not meta then return nil end
  local members = self.db:getMembers(who(user_id), status_id)
  local ids = {}
  for i, m in ipairs(members) do ids[i] = m.book_id end
  local rows = self.books:rows(ids)
  local out = {}
  for _, m in ipairs(members) do
    local row = rows[m.book_id]
    if row then out[#out + 1] = entryOf(row, m) end
  end
  return out, meta
end

-- The shelf row of one book: { status_id, user_book_id, rating, date_added }, or nil when
-- it is on none of your saved shelves. One indexed lookup, no book decoded.
function ShelfStore:member(user_id, book_id)
  book_id = tonumber(book_id)
  if not book_id then return nil end
  return self.db:getMember(who(user_id), book_id)
end

-- The book as a shelf entry, from whichever shelf it is on, or nil.
function ShelfStore:findEntry(user_id, book_id)
  local m = self:member(user_id, book_id)
  if not m then return nil end
  local row = self.books:rows({ m.book_id })[m.book_id]
  return row and entryOf(row, m) or nil
end

local function membersOf(entries, status_id)
  local members, seen = {}, {}
  for _, e in ipairs(entries) do
    local book_id = tonumber(e.book_id)
    if book_id and not seen[book_id] then
      seen[book_id] = true
      members[#members + 1] = {
        user_book_id = tonumber(e.user_book_id),
        book_id = book_id,
        rating = tonumber(e.user_rating or e.rating),
        date_added = e.date_added,
        status_id = status_id,
      }
    end
  end
  return members
end

local function save(self, user_id, status_id, members, complete, fingerprint)
  local now = self.now()
  local meta = {
    fingerprint = fingerprint,
    complete = complete and true or false,
    saved_at = now,
    checked_at = fingerprint and now or nil,
  }
  local ok = self.db:putMembers(who(user_id), status_id, members, metaKey(user_id, status_id), Codec.encode(meta))
  -- a book that left the shelf may now be held by nothing
  self.books:evict()
  return ok
end

--
-- A shelf downloaded in full (Api:getShelf's entries): its books go into the book store
-- and the shelf remembers which they are. `fingerprint` is the one Hardcover gave before
-- the download began (nil when not known: the next look then asks again).
--
function ShelfStore:putEntries(user_id, status_id, entries, complete, fingerprint)
  if type(entries) ~= "table" then return false end
  self.books:saveRows(entries)
  return save(self, user_id, status_id, membersOf(entries, status_id), complete, fingerprint)
end

-- A shelf re-downloaded as membership only (Api:getShelfMembers's rows); the books not
-- saved yet were fetched and saved by the caller.
function ShelfStore:putMembers(user_id, status_id, members, complete, fingerprint)
  if type(members) ~= "table" then return false end
  return save(self, user_id, status_id, membersOf(members, status_id), complete, fingerprint)
end

-- Hardcover says the shelf is as saved: note when, so a screen opened shortly after need
-- not ask again.
function ShelfStore:markChecked(user_id, status_id)
  local meta = self:meta(user_id, status_id)
  if not meta then return false end
  meta.checked_at = self.now()
  return putMeta(self, user_id, status_id, meta)
end

-- The saved shelf no longer matches Hardcover (a change made here): the next look asks
-- again, however recently it last did, and downloads the membership.
function ShelfStore:markStale(user_id, status_id)
  local meta = self:meta(user_id, status_id)
  if not meta then return false end
  meta.fingerprint = nil
  meta.checked_at = nil
  return putMeta(self, user_id, status_id, meta)
end

-- ------------------------------------------------------------------ changes made here

-- The book went onto shelf `status_id` (from another, or new to the library). It keeps
-- your rating; a book new to the shelf goes first, as Hardcover orders shelves.
function ShelfStore:moveBook(user_id, book_id, status_id, user_book_id)
  book_id = tonumber(book_id)
  if not (book_id and status_id) then return false end
  local old = self:member(user_id, book_id)
  self.db:putMember(who(user_id), {
    status_id = status_id,
    user_book_id = tonumber(user_book_id) or (old and old.user_book_id),
    book_id = book_id,
    rating = old and old.rating,
    date_added = (old and old.date_added) or os.date("%Y-%m-%d"),
  })
  if old and old.status_id ~= status_id then self:markStale(user_id, old.status_id) end
  self:markStale(user_id, status_id)
  return true
end

-- Your rating on the book changed (0 or nil clears it).
function ShelfStore:rateBook(user_id, book_id, rating)
  local old = self:member(user_id, book_id)
  if not old then return false end
  rating = tonumber(rating)
  old.rating = (rating and rating > 0) and rating or nil
  self.db:putMember(who(user_id), old)
  self:markStale(user_id, old.status_id)
  return true
end

-- The book left the library.
function ShelfStore:removeBook(user_id, book_id)
  local old = self:member(user_id, book_id)
  if not old then return false end
  self.db:deleteMember(who(user_id), old.book_id)
  self:markStale(user_id, old.status_id)
  return true
end

-- ------------------------------------------------------------------ the whole library

-- Is every one of `status_ids` saved whole? Then a book on none of them is truly not in
-- your library, as far as Hardcover last said.
function ShelfStore:synced(user_id, status_ids)
  for _, status_id in ipairs(status_ids or {}) do
    local meta = self:meta(user_id, status_id)
    if not (meta and meta.complete) then return false end
  end
  return true
end

--
-- Carry the shelves saved by an earlier version (in the shelf cache's file) over, once.
-- Their books keep what they had, but a synopsis that file cut short is marked partial,
-- so the book is fetched whole the first time its shelf is downloaded. The shelves have
-- no fingerprint, so the next look downloads their membership (a small request) rather
-- than the books again. A shelf already saved here is left alone.
--
function ShelfStore:convert(user_id, legacy, status_ids)
  if not (legacy and legacy.get) then return false end
  local moved = false
  for _, status_id in ipairs(status_ids or {}) do
    local old = legacy:get(user_id, status_id)
    if old and type(old.entries) == "table" and not self:meta(user_id, status_id) then
      local whole, cut = {}, {}
      for _, e in ipairs(old.entries) do
        if BookStore.isCut(e.description) then cut[#cut + 1] = e else whole[#whole + 1] = e end
      end
      self.books:saveRows(whole)
      self.books:saveRows(cut, true)
      local now = self.now()
      local meta = { complete = old.complete and true or false, saved_at = tonumber(old.saved_at) or now }
      self.db:putMembers(who(user_id), status_id, membersOf(old.entries, status_id), metaKey(user_id, status_id),
        Codec.encode(meta))
      moved = true
    end
  end
  if legacy.dropShelves then legacy:dropShelves(user_id) end
  return moved
end

return ShelfStore
