-- The activity store: what the Activity tab last showed, kept per account so the tab opens
-- offline.
--
-- Over the in-memory stand-in for the SQLite file (spec/lib/memory_store.lua); the file
-- itself is checked in the emulator (spec/emu/scenarios/activity.lua).
--
-- Run with:  lua spec/activity_store_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
local json = dofile(PLUGIN .. "/spec/json.lua")
package.preload["json"] = function() return json end
local r = support.reporter()

local MemoryStore = dofile(PLUGIN .. "/spec/lib/memory_store.lua")
local ActivityStore = require("hardcover/lib/activity_store")

local check = r.test

local clock = 5000
local function store(db)
  db = db or MemoryStore.new()
  return ActivityStore:new { db = db, now = function() return clock end }, db
end

local function entry(n, extra)
  local e = { key = "journal:" .. n, kind = "note", at = "2026-10-" .. string.format("%02d", n % 28 + 1) .. "T10:00:00+00:00",
              date = "2026-10-01", who = "Dana", book_id = 5, title = "Dune", text = "Note " .. n,
              excerpt = "Note " .. n, page = 12 }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end

print("\n== saving and reading back ==")

check("nothing saved is nil", function()
  local activity = store()
  assert(activity:get(1) == nil)
end)

check("what was saved comes back in order, with when it was saved", function()
  local activity, db = store()
  assert(activity:put(1, { entry(3), entry(2, { kind = "quote" }), entry(1, { kind = "review", spoilers = true, rating = 4.5 }) }, true))
  assert(type(db.blobs["activity:1"]) == "string", "kept as text, as the SQLite file keeps it")
  local saved = activity:get(1)
  assert(#saved.entries == 3 and saved.entries[1].key == "journal:3" and saved.entries[3].key == "journal:1", "order lost")
  assert(saved.entries[2].kind == "quote" and saved.entries[2].page == 12 and saved.entries[2].title == "Dune")
  assert(saved.entries[3].spoilers == true and saved.entries[3].rating == 4.5)
  assert(saved.more == true and saved.saved_at == 5000)
end)

check("an empty answer is saved too: the tab knows there is nothing", function()
  local activity = store()
  assert(activity:put(1, {}, false))
  local saved = activity:get(1)
  assert(saved and #saved.entries == 0 and saved.more == false)
end)

check("a newer save replaces the old one", function()
  local activity = store()
  activity:put(1, { entry(1), entry(2) }, true)
  clock = 6000
  activity:put(1, { entry(9) }, false)
  local saved = activity:get(1)
  assert(#saved.entries == 1 and saved.entries[1].key == "journal:9" and saved.more == false and saved.saved_at == 6000)
  clock = 5000
end)

print("\n== accounts ==")

check("each account has its own, and another account sees none", function()
  local activity = store()
  activity:put(1, { entry(1) }, false)
  activity:put(2, { entry(2), entry(3) }, false)
  assert(#activity:get(1).entries == 1 and activity:get(1).entries[1].key == "journal:1")
  assert(#activity:get(2).entries == 2)
  assert(activity:get(3) == nil, "an account that saved nothing must not see another's")
end)

print("\n== the limit ==")

check("only the newest KEEP entries are kept, and the copy then says there is more", function()
  local activity = store()
  local many = {}
  for n = 1, ActivityStore.KEEP + 7 do many[n] = entry(n) end
  assert(activity:put(1, many, false))
  local saved = activity:get(1)
  assert(#saved.entries == ActivityStore.KEEP, "kept " .. #saved.entries)
  assert(saved.entries[1].key == "journal:1" and saved.entries[ActivityStore.KEEP].key == "journal:" .. ActivityStore.KEEP)
  assert(saved.more == true, "a cut list has more")
end)

print("\n== a store that cannot help ==")

check("without a store nothing is saved and nothing comes back", function()
  local activity = ActivityStore:new {}
  assert(activity:put(1, { entry(1) }, false) == false)
  assert(activity:get(1) == nil)
end)

check("a store that fails is not an error", function()
  local activity, db = store()
  activity:put(1, { entry(1) }, false)
  db.fail = true
  assert(activity:put(1, { entry(2) }, false) == false)
  assert(activity:get(1) == nil)
  db.fail = false
  assert(activity:get(1).entries[1].key == "journal:1", "a failed save must leave the old copy")
end)

check("something that is not a saved copy is ignored", function()
  local activity, db = store()
  db.blobs["activity:1"] = "not json"
  assert(activity:get(1) == nil)
  db.blobs["activity:1"] = '{"more":true}'
  assert(activity:get(1) == nil)
  assert(activity:put(1, nil, false) == false)
end)

r.finish()
