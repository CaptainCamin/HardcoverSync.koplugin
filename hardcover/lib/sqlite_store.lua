-- The on-disk side of the book store: a small SQLite database, through the
-- lua-ljsqlite3 that KOReader ships (its Statistics plugin uses the same library,
-- so every KOReader this plugin supports has it).
--
-- Only SQL lives here. What goes in and comes out is strings (JSON, encoded by
-- book_store.lua and list_store.lua) and numbers, so the logic above can be checked
-- under stock Lua against an in-memory stand-in with the same methods
-- (spec/lib/memory_store.lua), and this file is checked in the emulator, against the
-- real library.
--
-- Nothing is required or opened until the first call, so loading the plugin costs
-- nothing. Every call is best-effort: SQLite raises on a locked or damaged file, and a
-- store that cannot be read must never break the screen that asked. A failed open is
-- not retried on every call.
--
-- Tables:
--   books    one row per book: what a list or shelf row shows (JSON)
--   details  a book's details screen as last fetched, per edition (0 = no edition)
--   blobs    small keyed records: a user's list index, one list's books
--   refs     which saved list holds which book, so books no list holds can go

local SqliteStore = {}
SqliteStore.__index = SqliteStore

-- Bumped when the tables change; open() brings an older file up to date.
SqliteStore.SCHEMA_VERSION = 1

-- SQLite (before 3.32) allows 999 bound values in one statement.
local CHUNK = 400

local SCHEMA = {
  "CREATE TABLE IF NOT EXISTS books (book_id INTEGER PRIMARY KEY, row TEXT NOT NULL, saved_at INTEGER)",
  "CREATE TABLE IF NOT EXISTS details (book_id INTEGER NOT NULL, edition_id INTEGER NOT NULL, data TEXT NOT NULL, opened_at INTEGER, PRIMARY KEY (book_id, edition_id))",
  "CREATE TABLE IF NOT EXISTS blobs (key TEXT PRIMARY KEY, data TEXT NOT NULL)",
  "CREATE TABLE IF NOT EXISTS refs (owner TEXT NOT NULL, book_id INTEGER NOT NULL)",
  "CREATE INDEX IF NOT EXISTS refs_owner ON refs (owner)",
  "CREATE INDEX IF NOT EXISTS refs_book ON refs (book_id)",
  "CREATE INDEX IF NOT EXISTS details_opened ON details (opened_at)",
}

function SqliteStore:new(o)
  return setmetatable(o or {}, self)
end

-- `sqlite` and `device` can be handed in (the emulator does); otherwise KOReader's.
function SqliteStore:_open()
  local SQ3 = self.sqlite or require("lua-ljsqlite3/init")
  local conn = SQ3.open(self.path)
  local device = self.device
  if device == nil then
    local ok, Device = pcall(require, "device")
    device = ok and Device or false
  end
  -- what the Statistics plugin does: WAL needs mmap on the file system, which not every
  -- e-reader's storage has
  if device and device.canUseWAL and device:canUseWAL() then
    conn:exec("PRAGMA journal_mode=WAL;")
  else
    conn:exec("PRAGMA journal_mode=TRUNCATE;")
  end
  local version = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
  if version < SqliteStore.SCHEMA_VERSION then
    for _, statement in ipairs(SCHEMA) do conn:exec(statement) end
    conn:exec(string.format("PRAGMA user_version=%d;", SqliteStore.SCHEMA_VERSION))
  end
  return conn
end

-- The connection, or nil when the file cannot be opened. false (not nil) once that has
-- failed, so a broken file is not tried again on every call.
function SqliteStore:conn()
  if self.closed then return nil end
  if self.connection == nil then
    local ok, conn = pcall(self._open, self)
    self.connection = ok and conn or false
  end
  return self.connection or nil
end

-- Run `fn(conn)` and return what it returns, or nil when there is no store or it raised.
function SqliteStore:_try(fn)
  local conn = self:conn()
  if not conn then return nil end
  local ok, a, b = pcall(fn, conn)
  if ok then return a, b end
  return nil
end

-- Run `fn(conn)` inside one transaction: one write to flash instead of one per row,
-- and all of it or none of it.
function SqliteStore:_write(fn)
  return self:_try(function(conn)
    conn:exec("BEGIN;")
    local ok, err = pcall(fn, conn)
    if not ok then
      pcall(conn.exec, conn, "ROLLBACK;")
      error(err)
    end
    conn:exec("COMMIT;")
    return true
  end) or false
end

local function placeholders(n)
  local marks = {}
  for i = 1, n do marks[i] = "?" end
  return table.concat(marks, ",")
end

local function chunks(ids)
  local out, current = {}, {}
  for _, id in ipairs(ids or {}) do
    current[#current + 1] = id
    if #current >= CHUNK then
      out[#out + 1] = current
      current = {}
    end
  end
  if #current > 0 then out[#out + 1] = current end
  return out
end

-- Every row of a statement, each as { values... } with integers made Lua numbers
-- (lua-ljsqlite3 hands them back as 64-bit cdata).
local function rows(conn, sql, ...)
  local stmt = conn:prepare(sql)
  local out = {}
  local ok, err = pcall(function(...)
    stmt:bind(...)
    local row = stmt:step()
    while row do
      local copy = {}
      for i = 1, #row do
        local v = row[i]
        copy[i] = type(v) == "cdata" and tonumber(v) or v
      end
      out[#out + 1] = copy
      row = stmt:step()
    end
  end, ...)
  stmt:close()
  if not ok then error(err) end
  return out
end

local function run(conn, sql, ...)
  local stmt = conn:prepare(sql)
  local ok, err = pcall(function(...) stmt:bind(...):step() end, ...)
  stmt:close()
  if not ok then error(err) end
end

-- ------------------------------------------------------------------ books

-- { [book_id] = row_json } for the ids that are saved.
function SqliteStore:getRows(ids)
  return self:_try(function(conn)
    local out = {}
    for _, chunk in ipairs(chunks(ids)) do
      local found = rows(conn, "SELECT book_id, row FROM books WHERE book_id IN (" .. placeholders(#chunk) .. ")",
        unpack(chunk))
      for _, r in ipairs(found) do out[r[1]] = r[2] end
    end
    return out
  end) or {}
end

-- `books` is { { book_id = n, row = json }, ... }: saved, replacing what was there.
function SqliteStore:putRows(books, now)
  return self:_write(function(conn)
    local stmt = conn:prepare("INSERT OR REPLACE INTO books (book_id, row, saved_at) VALUES (?, ?, ?)")
    local ok, err = pcall(function()
      for _, b in ipairs(books) do
        stmt:reset():bind(b.book_id, b.row, now):step()
      end
    end)
    stmt:close()
    if not ok then error(err) end
  end)
end

-- The ids among `ids` that have a saved row.
function SqliteStore:knownIds(ids)
  return self:_try(function(conn)
    local out = {}
    for _, chunk in ipairs(chunks(ids)) do
      local found = rows(conn, "SELECT book_id FROM books WHERE book_id IN (" .. placeholders(#chunk) .. ")",
        unpack(chunk))
      for _, r in ipairs(found) do out[r[1]] = true end
    end
    return out
  end) or {}
end

-- ------------------------------------------------------------------ details

function SqliteStore:getDetail(book_id, edition_id)
  return self:_try(function(conn)
    local found = rows(conn, "SELECT data FROM details WHERE book_id = ? AND edition_id = ?", book_id, edition_id or 0)
    return found[1] and found[1][1] or nil
  end)
end

-- Any saved details of the book, the most recently opened first: what to show for a
-- book whose own edition was never opened.
function SqliteStore:anyDetail(book_id)
  return self:_try(function(conn)
    local found = rows(conn, "SELECT data FROM details WHERE book_id = ? ORDER BY opened_at DESC LIMIT 1", book_id)
    return found[1] and found[1][1] or nil
  end)
end

function SqliteStore:putDetail(book_id, edition_id, data, now)
  return self:_write(function(conn)
    run(conn, "INSERT OR REPLACE INTO details (book_id, edition_id, data, opened_at) VALUES (?, ?, ?, ?)",
      book_id, edition_id or 0, data, now)
  end)
end

-- ------------------------------------------------------------------ blobs

function SqliteStore:getBlob(key)
  return self:_try(function(conn)
    local found = rows(conn, "SELECT data FROM blobs WHERE key = ?", key)
    return found[1] and found[1][1] or nil
  end)
end

function SqliteStore:putBlob(key, data)
  return self:_write(function(conn)
    run(conn, "INSERT OR REPLACE INTO blobs (key, data) VALUES (?, ?)", key, data)
  end)
end

-- ------------------------------------------------------------------ lists of books

-- What one owner (a saved list) holds: replaces whatever it held, and its blob with it,
-- in one transaction. `blob` nil leaves the blob alone.
function SqliteStore:putOwned(owner, book_ids, blob)
  return self:_write(function(conn)
    run(conn, "DELETE FROM refs WHERE owner = ?", owner)
    local stmt = conn:prepare("INSERT INTO refs (owner, book_id) VALUES (?, ?)")
    local ok, err = pcall(function()
      for _, id in ipairs(book_ids) do stmt:reset():bind(owner, id):step() end
    end)
    stmt:close()
    if not ok then error(err) end
    if blob ~= nil then
      run(conn, "INSERT OR REPLACE INTO blobs (key, data) VALUES (?, ?)", owner, blob)
    end
  end)
end

-- Forget owners (and their blobs): the exact key, or every key starting with `prefix`
-- when `prefix` ends in ":".
function SqliteStore:dropOwned(key)
  return self:_write(function(conn)
    if key:sub(-1) == ":" then
      local pattern = key:gsub("[%%_]", "\\%0") .. "%"
      run(conn, "DELETE FROM refs WHERE owner LIKE ? ESCAPE '\\'", pattern)
      run(conn, "DELETE FROM blobs WHERE key LIKE ? ESCAPE '\\'", pattern)
    else
      run(conn, "DELETE FROM refs WHERE owner = ?", key)
      run(conn, "DELETE FROM blobs WHERE key = ?", key)
    end
  end)
end

-- Keep the `keep_opened` most recently opened details, and the books some list holds
-- or that still have details; delete the rest.
function SqliteStore:evict(keep_opened)
  return self:_write(function(conn)
    run(conn, "DELETE FROM details WHERE rowid NOT IN (SELECT rowid FROM details ORDER BY opened_at DESC LIMIT ?)",
      keep_opened)
    conn:exec("DELETE FROM books WHERE book_id NOT IN (SELECT book_id FROM refs) AND book_id NOT IN (SELECT book_id FROM details);")
  end)
end

-- Everything, for sign out.
function SqliteStore:clear()
  return self:_write(function(conn)
    conn:exec("DELETE FROM books; DELETE FROM details; DELETE FROM blobs; DELETE FROM refs;")
  end)
end

-- Let the file go (the screen it served is closing). Later calls do nothing.
function SqliteStore:close()
  local conn = self.connection
  self.closed = true
  self.connection = false
  if conn then pcall(conn.close, conn) end
end

return SqliteStore
