-- The journal store: what the Journal tab last showed, kept per account so the tab opens offline.
--
-- Over the in-memory stand-in for the SQLite file (spec/lib/memory_store.lua); the file
-- itself is checked in the emulator (spec/emu/scenarios/journal_tab.lua).
--
-- Run with:  lua spec/journal_store_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
local json = dofile(PLUGIN .. "/spec/json.lua")
package.preload["json"] = function() return json end
local r = support.reporter()

local MemoryStore = dofile(PLUGIN .. "/spec/lib/memory_store.lua")
local JournalStore = require("hardcover/lib/journal_store")

local check = r.test

local clock = 5000
local function store(db)
  db = db or MemoryStore.new()
  return JournalStore:new { db = db, now = function() return clock end }, db
end

local function entry(n, extra)
  local e = { key = "note:" .. n, id = n, kind = "note", at = "2026-10-" .. string.format("%02d", n % 28 + 1) .. "T10:00:00+00:00",
              book_id = 5, title = "Dune", authors = "Frank Herbert", cover_url = "https://example.test/dune.jpg",
              text = "Note " .. n, excerpt = "Note " .. n, page = 12 }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end

print("\n== saving and reading back ==")

check("nothing saved is nil", function()
  local journal = store()
  assert(journal:get(1) == nil)
end)

check("what was saved comes back in order, with when it was saved", function()
  local journal, db = store()
  assert(journal:put(1, { entry(3), entry(2, { kind = "quote" }), entry(1, { kind = "review", spoilers = true, user_book_id = 900 }) }, true))
  assert(type(db.blobs["journal:1"]) == "string", "kept as text, as the SQLite file keeps it")
  local saved = journal:get(1)
  assert(#saved.entries == 3 and saved.entries[1].key == "note:3" and saved.entries[3].key == "note:1", "order lost")
  assert(saved.entries[2].kind == "quote" and saved.entries[2].page == 12 and saved.entries[2].title == "Dune")
  assert(saved.entries[2].authors == "Frank Herbert" and saved.entries[2].cover_url == "https://example.test/dune.jpg")
  assert(saved.entries[3].spoilers == true and saved.entries[3].user_book_id == 900)
  assert(saved.more == true and saved.saved_at == 5000)
end)

check("an empty answer is saved too: the tab knows there is nothing", function()
  local journal = store()
  assert(journal:put(1, {}, false))
  local saved = journal:get(1)
  assert(saved and #saved.entries == 0 and saved.more == false)
end)

check("a newer save replaces the old one", function()
  local journal = store()
  journal:put(1, { entry(1), entry(2) }, true)
  clock = 6000
  journal:put(1, { entry(9) }, false)
  local saved = journal:get(1)
  assert(#saved.entries == 1 and saved.entries[1].key == "note:9" and saved.more == false and saved.saved_at == 6000)
  clock = 5000
end)

check("what the Activity tab kept, in its own shape, is not read as the journal", function()
  local journal, db = store()
  db.blobs["activity:1"] = '{"entries":[{"key":"status:1","kind":"status"}],"more":false,"saved_at":1}'
  assert(journal:get(1) == nil)
end)

print("\n== accounts ==")

check("each account has its own, and another account sees none", function()
  local journal = store()
  journal:put(1, { entry(1) }, false)
  journal:put(2, { entry(2), entry(3) }, false)
  assert(#journal:get(1).entries == 1 and journal:get(1).entries[1].key == "note:1")
  assert(#journal:get(2).entries == 2)
  assert(journal:get(3) == nil, "an account that saved nothing must not see another's")
end)

print("\n== the limit ==")

check("only the newest KEEP entries are kept, and the copy then says there is more", function()
  local journal = store()
  local many = {}
  for n = 1, JournalStore.KEEP + 7 do many[n] = entry(n) end
  assert(journal:put(1, many, false))
  local saved = journal:get(1)
  assert(#saved.entries == JournalStore.KEEP, "kept " .. #saved.entries)
  assert(saved.entries[1].key == "note:1" and saved.entries[JournalStore.KEEP].key == "note:" .. JournalStore.KEEP)
  assert(saved.more == true, "a cut list has more")
end)

print("\n== a change Hardcover took ==")

check("an entry named by its key takes the new fields, and the copy keeps when it is from", function()
  local journal = store()
  journal:put(1, { entry(1), entry(2) }, true)
  clock = 7000
  assert(journal:change(1, "note:2", { text = "Changed", excerpt = "Changed" }))
  local saved = journal:get(1)
  assert(saved.entries[2].text == "Changed" and saved.entries[2].page == 12 and saved.entries[1].text == "Note 1")
  assert(saved.saved_at == 5000 and saved.more == true)
  clock = 5000
end)

check("nil fields delete the entry; an entry not kept changes nothing", function()
  local journal = store()
  journal:put(1, { entry(1), entry(2) }, false)
  assert(journal:change(1, "note:1", nil))
  local saved = journal:get(1)
  assert(#saved.entries == 1 and saved.entries[1].key == "note:2")
  assert(journal:change(1, "note:99", { text = "x" }) == false)
  assert(journal:change(5, "note:2", { text = "x" }) == false, "nothing saved for that account")
end)

check("a test changes every entry it is about, and false clears a field", function()
  local journal = store()
  journal:put(1, {
    entry(1, { key = "reviewed:1", kind = "review", user_book_id = 900, spoilers = true }),
    entry(2),
    entry(3, { key = "reviewed:3", kind = "review", user_book_id = 900 }),
    entry(4, { key = "reviewed:4", kind = "review", user_book_id = 901 }),
  }, false)
  local function review900(e) return e.kind == "review" and e.user_book_id == 900 end
  assert(journal:change(1, review900, { text = false, excerpt = false, spoilers = false }))
  local saved = journal:get(1)
  assert(saved.entries[1].text == nil and saved.entries[1].spoilers == nil and saved.entries[1].key == "reviewed:1")
  assert(saved.entries[3].text == nil and saved.entries[2].text == "Note 2" and saved.entries[4].text == "Note 4")
  assert(journal:change(1, review900, nil))
  assert(#journal:get(1).entries == 2, "both of the book's reviews deleted")
end)

print("\n== a store that cannot help ==")

check("without a store nothing is saved and nothing comes back", function()
  local journal = JournalStore:new {}
  assert(journal:put(1, { entry(1) }, false) == false)
  assert(journal:get(1) == nil)
  assert(journal:change(1, "note:1", nil) == false)
end)

check("a store that fails is not an error", function()
  local journal, db = store()
  journal:put(1, { entry(1) }, false)
  db.fail = true
  assert(journal:put(1, { entry(2) }, false) == false)
  assert(journal:get(1) == nil)
  db.fail = false
  assert(journal:get(1).entries[1].key == "note:1", "a failed save must leave the old copy")
end)

check("something that is not a saved copy is ignored", function()
  local journal, db = store()
  db.blobs["journal:1"] = "not json"
  assert(journal:get(1) == nil)
  db.blobs["journal:1"] = '{"more":true}'
  assert(journal:get(1) == nil)
  assert(journal:put(1, nil, false) == false)
end)

r.finish()
