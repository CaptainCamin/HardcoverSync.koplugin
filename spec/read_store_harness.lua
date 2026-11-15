-- The read store: each book's reading history, kept per account so Reading history opens offline.
--
-- Over the in-memory stand-in for the SQLite file (spec/lib/memory_store.lua); the file itself is
-- checked in the emulator, as the other stores are.
--
-- Run with:  lua spec/read_store_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
local json = dofile(PLUGIN .. "/spec/json.lua")
package.preload["json"] = function() return json end
local r = support.reporter()

local MemoryStore = dofile(PLUGIN .. "/spec/lib/memory_store.lua")
local ReadStore = require("hardcover/lib/read_store")

local check = r.test

local clock = 5000
local function store(db)
  db = db or MemoryStore.new()
  return ReadStore:new { db = db, now = function() return clock end }, db
end

local function read(id, extra)
  local row = { id = id, started_at = "2024-03-1" .. (id % 10), finished_at = "2024-03-20",
    finished_at_precision = 1, progress_pages = 300, edition_id = 7,
    edition = { id = 7, pages = 304, edition_format = "Paperback", reading_format_id = 1 } }
  for k, v in pairs(extra or {}) do row[k] = v end
  return row
end

print("\n== saving and reading back ==")

check("nothing saved is nil", function()
  local reads = store()
  assert(reads:get(1, 10) == nil)
end)

check("what was saved comes back in order, with when Hardcover said so", function()
  local reads, db = store()
  assert(reads:put(1, 10, { read(2), read(1) }))
  assert(type(db.blobs["reads:1:10"]) == "string", "kept as text, as the SQLite file keeps it")
  local saved = reads:get(1, 10)
  assert(saved and #saved.reads == 2 and saved.reads[1].id == 2 and saved.reads[2].id == 1)
  assert(saved.reads[1].edition.pages == 304 and saved.reads[1].edition.edition_format == "Paperback")
  assert(saved.checked_at == 5000)
end)

check("a known empty history is not the same as no saved copy", function()
  local reads = store()
  assert(reads:put(1, 10, {}))
  local saved = reads:get(1, 10)
  assert(saved and type(saved.reads) == "table" and #saved.reads == 0)
end)

check("a newer save replaces the old one", function()
  local reads = store()
  reads:put(1, 10, { read(1) })
  clock = 6000
  reads:put(1, 10, { read(3), read(2) })
  local saved = reads:get(1, 10)
  assert(#saved.reads == 2 and saved.reads[1].id == 3 and saved.checked_at == 6000)
  clock = 5000
end)

check("editions are kept with the reads, and a reads-only save keeps them", function()
  local reads = store()
  local editions = { { edition_id = 7, pages = 304, edition_format = "Paperback" },
    { edition_id = 8, pages = 608, edition_format = "E-book" } }
  reads:put(1, 10, { read(1) }, editions)
  local saved = reads:get(1, 10)
  assert(saved.editions and #saved.editions == 2 and saved.editions[2].pages == 608)
  reads:put(1, 10, { read(2) })
  assert(#reads:get(1, 10).editions == 2, "a reads refresh threw away the editions")
  assert(reads:putEditions(1, 10, { editions[1] }))
  local one = reads:get(1, 10)
  assert(#one.editions == 1 and #one.reads == 1, "putEditions changed the reads")
end)

check("a store that cannot be opened keeps nothing and does not raise", function()
  local reads, db = store()
  db.fail = true
  assert(reads:get(1, 10) == nil)
  assert(reads:put(1, 10, { read(1) }) == false)
end)

check("the wrong shape in the file is not read as a history", function()
  local reads, db = store()
  db.blobs["reads:1:10"] = '{"checked_at":5}'
  assert(reads:get(1, 10) == nil)
  db.blobs["reads:1:10"] = '{"reads":[]}'
  assert(reads:get(1, 10) == nil)
end)

print("\n== accounts and books ==")

check("each account has its own, and another account sees none", function()
  local reads = store()
  reads:put(1, 10, { read(1) })
  assert(reads:get(1, 10) ~= nil)
  assert(reads:get(2, 10) == nil)
end)

check("each book has its own", function()
  local reads = store()
  reads:put(1, 10, { read(1) })
  reads:put(1, 11, { read(2), read(3) })
  assert(#reads:get(1, 10).reads == 1)
  assert(#reads:get(1, 11).reads == 2)
end)

print("\n== signing out ==")

check("invalidate forgets every saved history and nothing else", function()
  local reads, db = store()
  reads:put(1, 10, { read(1) })
  reads:put(2, 10, { read(2) })
  db.blobs["reviews:1:10"] = "{}"
  assert(reads:invalidate())
  assert(reads:get(1, 10) == nil and reads:get(2, 10) == nil)
  assert(db.blobs["reviews:1:10"] == "{}", "another store's blobs were dropped")
end)

check("invalidate on a store without key removal still answers", function()
  local reads = ReadStore:new { db = { getBlob = function() return nil end,
    putBlob = function() return true end } }
  assert(reads:invalidate() == true)
end)

r.finish()
