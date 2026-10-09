-- An in-memory stand-in for hardcover/lib/sqlite_store.lua: the same methods, the same
-- answers, kept in tables. The harnesses run under stock Lua, where there is no SQLite;
-- the real file is checked in the emulator (spec/emu/scenarios/offline_lists.lua).
--
-- Values are stored exactly as given (strings: the JSON the logic encodes), so the
-- logic's own serialisation is what the harnesses exercise. `fail = true` makes every
-- call behave as a store that cannot be opened. `writes` counts transactions.

local MemoryStore = {}
MemoryStore.__index = MemoryStore

function MemoryStore.new()
  return setmetatable({
    books = {}, details = {}, blobs = {}, refs = {}, shelf = {}, writes = 0, clock = 0,
  }, MemoryStore)
end

local function write(self)
  if self.fail then return false end
  self.writes = self.writes + 1
  return true
end

function MemoryStore:getRows(ids)
  if self.fail then return {} end
  local out = {}
  for _, id in ipairs(ids or {}) do
    if self.books[id] then out[id] = self.books[id].row end
  end
  return out
end

function MemoryStore:putRows(books, now)
  if not write(self) then return false end
  for _, b in ipairs(books) do self.books[b.book_id] = { row = b.row, saved_at = now, partial = b.partial and true or false } end
  return true
end

function MemoryStore:knownIds(ids)
  if self.fail then return {} end
  local out = {}
  for _, id in ipairs(ids or {}) do
    if self.books[id] and not self.books[id].partial then out[id] = true end
  end
  return out
end

local function detailKey(book_id, edition_id) return tostring(book_id) .. "/" .. tostring(edition_id or 0) end

function MemoryStore:getDetail(book_id, edition_id)
  if self.fail then return nil end
  local d = self.details[detailKey(book_id, edition_id)]
  return d and d.data
end

function MemoryStore:anyDetail(book_id)
  if self.fail then return nil end
  local best
  for _, d in pairs(self.details) do
    if d.book_id == book_id and (not best or d.order > best.order) then best = d end
  end
  return best and best.data
end

function MemoryStore:touchDetail(book_id, edition_id, now)
  if not write(self) then return false end
  local d = self.details[detailKey(book_id, edition_id)]
  if d then
    self.clock = self.clock + 1
    d.opened_at, d.order = now, self.clock
  end
  return true
end

function MemoryStore:putDetail(book_id, edition_id, data, now)
  if not write(self) then return false end
  -- `order` breaks ties between details saved in the same second, as SQLite's ORDER BY
  -- opened_at would only by luck
  self.clock = self.clock + 1
  self.details[detailKey(book_id, edition_id)] = {
    book_id = book_id, edition_id = edition_id or 0, data = data, opened_at = now, order = self.clock,
  }
  return true
end

function MemoryStore:getBlob(key)
  if self.fail then return nil end
  return self.blobs[key]
end

function MemoryStore:putBlob(key, data)
  if not write(self) then return false end
  self.blobs[key] = data
  return true
end

function MemoryStore:putOwned(owner, book_ids, blob)
  if not write(self) then return false end
  local copy = {}
  for i, id in ipairs(book_ids) do copy[i] = id end
  self.refs[owner] = copy
  if blob ~= nil then self.blobs[owner] = blob end
  return true
end

function MemoryStore:dropOwned(key)
  if not write(self) then return false end
  local prefix = key:sub(-1) == ":"
  for owner in pairs(self.refs) do
    if owner == key or (prefix and owner:sub(1, #key) == key) then self.refs[owner] = nil end
  end
  for k in pairs(self.blobs) do
    if k == key or (prefix and k:sub(1, #key) == key) then self.blobs[k] = nil end
  end
  return true
end

function MemoryStore:evict(keep_opened)
  if not write(self) then return false end
  local all = {}
  for k, d in pairs(self.details) do all[#all + 1] = { key = k, d = d } end
  table.sort(all, function(a, b) return a.d.order > b.d.order end)
  for i = keep_opened + 1, #all do self.details[all[i].key] = nil end

  local keep = {}
  for _, ids in pairs(self.refs) do for _, id in ipairs(ids) do keep[id] = true end end
  for _, d in pairs(self.details) do keep[d.book_id] = true end
  for _, m in pairs(self.shelf) do keep[m.book_id] = true end
  for id in pairs(self.books) do
    if not keep[id] then self.books[id] = nil end
  end
  return true
end

function MemoryStore:clear()
  if not write(self) then return false end
  self.books, self.details, self.blobs, self.refs, self.shelf = {}, {}, {}, {}, {}
  return true
end

-- ------------------------------------------------------------------ shelves
-- self.shelf is keyed "<user>/<book_id>" (a book is on one shelf at most)

local function memberKey(user_id, book_id) return tostring(user_id) .. "/" .. tostring(book_id) end

local function copyMember(m)
  return { status_id = m.status_id, user_book_id = m.user_book_id, book_id = m.book_id, rating = m.rating,
           date_added = m.date_added, position = m.position }
end

function MemoryStore:putMembers(user_id, status_id, members, key, blob)
  if not write(self) then return false end
  for k, m in pairs(self.shelf) do
    if m.user_id == user_id and m.status_id == status_id then self.shelf[k] = nil end
  end
  for i, m in ipairs(members) do
    local row = copyMember(m)
    row.user_id, row.status_id, row.position = user_id, status_id, i
    self.shelf[memberKey(user_id, m.book_id)] = row
  end
  if key and blob then self.blobs[key] = blob end
  return true
end

function MemoryStore:getMembers(user_id, status_id)
  if self.fail then return {} end
  local out = {}
  for _, m in pairs(self.shelf) do
    if m.user_id == user_id and m.status_id == status_id then out[#out + 1] = copyMember(m) end
  end
  table.sort(out, function(a, b) return a.position < b.position end)
  return out
end

function MemoryStore:getMember(user_id, book_id)
  if self.fail then return nil end
  local m = self.shelf[memberKey(user_id, book_id)]
  return m and copyMember(m) or nil
end

function MemoryStore:putMember(user_id, m)
  if not write(self) then return false end
  local key = memberKey(user_id, m.book_id)
  local old = self.shelf[key]
  local position
  if old and old.status_id == m.status_id then
    position = old.position
  else
    local top
    for _, x in pairs(self.shelf) do
      if x.user_id == user_id and x.status_id == m.status_id and (not top or x.position < top) then top = x.position end
    end
    position = (top or 1) - 1
  end
  local row = copyMember(m)
  row.user_id, row.position = user_id, position
  self.shelf[key] = row
  return true
end

function MemoryStore:deleteMember(user_id, book_id)
  if not write(self) then return false end
  self.shelf[memberKey(user_id, book_id)] = nil
  return true
end

function MemoryStore:close()
  self.closed = true
end

function MemoryStore:libraryBookIds(user_id)
  if self.fail then return {} end
  local seen, out = {}, {}
  for _, m in pairs(self.shelf) do
    if m.user_id == user_id and not seen[m.book_id] then seen[m.book_id] = true; out[#out + 1] = m.book_id end
  end
  local prefix = "list:" .. tostring(user_id) .. ":"
  for owner, ids in pairs(self.refs) do
    if owner:sub(1, #prefix) == prefix then
      for _, id in ipairs(ids) do
        if not seen[id] then seen[id] = true; out[#out + 1] = id end
      end
    end
  end
  table.sort(out)
  return out
end

-- for assertions
function MemoryStore:count(name)
  local n = 0
  for _ in pairs(self[name]) do n = n + 1 end
  return n
end

return MemoryStore
