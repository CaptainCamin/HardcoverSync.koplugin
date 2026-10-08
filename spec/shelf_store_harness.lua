-- The shelf store: your shelves as which books are on each, with your status and rating,
-- changes made on this device, and carrying the old saved-shelves file over.
--
-- Over the in-memory stand-in for the SQLite file (spec/lib/memory_store.lua); the file
-- itself is checked in the emulator.
--
-- Run with:  lua spec/shelf_store_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
local json = dofile(PLUGIN .. "/spec/json.lua")
package.preload["json"] = function() return json end
local r = support.reporter()

local MemoryStore = dofile(PLUGIN .. "/spec/lib/memory_store.lua")
local BookStore = require("hardcover/lib/book_store")
local ListStore = require("hardcover/lib/list_store")
local ShelfStore = require("hardcover/lib/shelf_store")
local ShelfCache = require("hardcover/lib/shelf_cache")
local Shelf = require("hardcover/lib/shelf")

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local clock = 5000
local function stores()
  local db = MemoryStore.new()
  local books = BookStore:new { db = db, now = function() return clock end }
  return ShelfStore:new { db = db, books = books, now = function() return clock end },
    books, ListStore:new { db = db, books = books, now = function() return clock end }, db
end

local function entry(id, status, extra)
  local e = { user_book_id = 900 + id, book_id = id, status_id = status or 1, user_rating = nil,
              date_added = "2026-01-0" .. (id % 9 + 1), title = "Book " .. id, description = "Synopsis " .. id }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end

local FP = "3|2026-10-08T15:22:25.183388+00:00|7.5"

print("\n== a shelf ==")

check("a shelf comes back in Hardcover's order, with your status, rating and date added", function()
  local shelves = stores()
  assert(shelves:putEntries(1, 3, { entry(5, 3, { user_rating = 4.5 }), entry(2, 3), entry(9, 3) }, true, FP))
  local shown, meta = shelves:entries(1, 3)
  assert(#shown == 3 and shown[1].book_id == 5 and shown[3].book_id == 9, "order lost")
  assert(shown[1].user_rating == 4.5 and shown[1].status_id == 3 and shown[1].user_book_id == 905)
  assert(shown[2].title == "Book 2" and shown[2].description == "Synopsis 2")
  assert(meta.complete and meta.fingerprint == FP and meta.checked_at == clock)
end)

check("a shelf never saved is nil; an empty one is an answer", function()
  local shelves = stores()
  assert(shelves:entries(1, 1) == nil)
  shelves:putEntries(1, 1, {}, true, "0||")
  local shown, meta = shelves:entries(1, 1)
  assert(shown and #shown == 0 and meta.complete)
end)

check("another account never sees your shelves", function()
  local shelves = stores()
  shelves:putEntries(1, 3, { entry(5, 3) }, true, FP)
  assert(shelves:entries(2, 3) == nil and shelves:member(2, 5) == nil)
end)

check("a shelf saved as membership joins the books already saved", function()
  local shelves, books = stores()
  books:saveRows({ entry(1), entry(2) })
  shelves:putMembers(1, 1, { { user_book_id = 11, book_id = 2, rating = 3, date_added = "x" },
                             { user_book_id = 12, book_id = 1, date_added = "y" } }, true, FP)
  local shown = shelves:entries(1, 1)
  assert(#shown == 2 and shown[1].book_id == 2 and shown[1].user_rating == 3 and shown[2].user_book_id == 12)
end)

check("a book that moved shelves on Hardcover moves here when the new shelf is saved", function()
  local shelves = stores()
  shelves:putEntries(1, 2, { entry(5, 2), entry(6, 2) }, true, FP)
  shelves:putEntries(1, 3, { entry(5, 3) }, true, FP)
  assert(shelves:member(1, 5).status_id == 3)
  local reading = shelves:entries(1, 2)
  assert(#reading == 1 and reading[1].book_id == 6, "the book is on two shelves")
end)

check("which shelf a book is on is one lookup, and the whole entry comes with it", function()
  local shelves = stores()
  shelves:putEntries(1, 3, { entry(5, 3, { user_rating = 5 }) }, true, FP)
  local m = shelves:member(1, 5)
  assert(m.status_id == 3 and m.rating == 5 and m.user_book_id == 905)
  local e = shelves:findEntry(1, 5)
  assert(e.title == "Book 5" and e.status_id == 3 and e.user_rating == 5)
  assert(shelves:findEntry(1, 42) == nil)
end)

check("the fingerprint tells the count, the latest change and the ratings apart", function()
  local a = Shelf.fingerprint({ count = 3, max = { updated_at = "T" }, sum = { rating = 7.5 } })
  assert(a == "3|T|7.5", a)
  assert(Shelf.fingerprint({ count = 3, max = { updated_at = "T" }, sum = { rating = 8 } }) ~= a)
  assert(Shelf.fingerprint({ count = 0, max = {}, sum = {} }) == "0||")
  assert(Shelf.fingerprint({ count = 3, max = { updated_at = "T" }, sum = { rating = 7.50 } }) == a, "7.5 and 7.50 differ")
  assert(Shelf.fingerprint(nil) == nil and Shelf.fingerprint({}) == nil)
end)

print("\n== changes made on this device ==")

check("a book moved to another shelf moves at once, to the top, and both shelves will be asked again", function()
  local shelves = stores()
  shelves:putEntries(1, 2, { entry(5, 2, { user_rating = 4 }), entry(6, 2) }, true, FP)
  shelves:putEntries(1, 3, { entry(7, 3) }, true, FP)
  shelves:moveBook(1, 5, 3)
  local read = shelves:entries(1, 3)
  assert(read[1].book_id == 5 and read[1].user_rating == 4, "not at the top, or the rating was lost")
  assert(#shelves:entries(1, 2) == 1)
  assert(shelves:meta(1, 2).fingerprint == nil and shelves:meta(1, 3).fingerprint == nil, "not marked to ask again")
end)

check("a book new to the library goes on its shelf with its id", function()
  local shelves, books = stores()
  -- as from its details screen: opened online, so its details are kept
  books:saveDetail(8, nil, { book = { book_id = 8, title = "Book 8", description = "x" } })
  shelves:putEntries(1, 1, { entry(1, 1) }, true, FP)
  shelves:moveBook(1, 8, 1, 4242)
  local m = shelves:member(1, 8)
  assert(m.status_id == 1 and m.user_book_id == 4242)
  assert(shelves:entries(1, 1)[1].book_id == 8)
end)

check("a rating changes at once, and a cleared one is gone", function()
  local shelves = stores()
  shelves:putEntries(1, 3, { entry(5, 3, { user_rating = 2 }) }, true, FP)
  shelves:rateBook(1, 5, 4.5)
  assert(shelves:member(1, 5).rating == 4.5 and shelves:meta(1, 3).fingerprint == nil)
  shelves:rateBook(1, 5, 0)
  assert(shelves:member(1, 5).rating == nil)
end)

check("a book removed from the library leaves its shelf", function()
  local shelves = stores()
  shelves:putEntries(1, 3, { entry(5, 3), entry(6, 3) }, true, FP)
  shelves:removeBook(1, 5)
  assert(shelves:member(1, 5) == nil and #shelves:entries(1, 3) == 1 and shelves:meta(1, 3).fingerprint == nil)
end)

check("checked marks the time; a shelf is synced only when every shelf is saved whole", function()
  local shelves = stores()
  shelves:putEntries(1, 1, {}, true, "0||")
  shelves:putEntries(1, 2, { entry(1, 2) }, false, FP)
  assert(not shelves:synced(1, { 1, 2 }))
  shelves:putEntries(1, 2, { entry(1, 2) }, true, FP)
  assert(shelves:synced(1, { 1, 2 }) and not shelves:synced(1, { 1, 2, 3 }))
  clock = clock + 10
  shelves:markChecked(1, 2)
  assert(shelves:meta(1, 2).checked_at == clock)
end)

print("\n== books kept and dropped ==")

check("saving a list never drops a book only a shelf holds", function()
  local shelves, books, lists, db = stores()
  shelves:putEntries(1, 3, { entry(5, 3) }, true, FP)
  lists:putEntries(1, { id = 70, fingerprint = "x" }, { { book_id = 6, title = "On a list" } }, true)
  books:evict()
  assert(books:rows({ 5 })[5], "the shelf's book was dropped")
  assert(db:count("books") == 2)
end)

check("a book that left every shelf and list goes", function()
  local shelves, books = stores()
  shelves:putEntries(1, 3, { entry(5, 3), entry(6, 3) }, true, FP)
  shelves:putEntries(1, 3, { entry(6, 3) }, true, FP)
  assert(books:rows({ 5 })[5] == nil and books:rows({ 6 })[6])
end)

check("sign out clears the shelves too", function()
  local shelves, books = stores()
  shelves:putEntries(1, 3, { entry(5, 3) }, true, FP)
  books:clear()
  assert(shelves:entries(1, 3) == nil and shelves:member(1, 5) == nil)
end)

print("\n== the old saved-shelves file ==")

local function legacyCache()
  local data = {}
  local store = { readSetting = function(_, k) return data[k] end, saveSetting = function(_, k, v) data[k] = v end,
                  flush = function() end }
  return ShelfCache:new { path = "/x", open = function() return store end }, data
end

check("shelves saved by an earlier version are carried over once, and leave the old file", function()
  local shelves, books = stores()
  local legacy, data = legacyCache()
  local cut = string.rep("a", 600) .. "\226\128\166"
  legacy:put(1, 3, { entry(5, 3, { user_rating = 5 }), entry(6, 3, { description = cut }) }, true)
  legacy:put(1, 1, { entry(7, 1) }, false)
  legacy:putGoals(1, { { id = 1 } })
  assert(shelves:convert(1, legacy, { 1, 2, 3, 5 }))

  local read, meta = shelves:entries(1, 3)
  assert(#read == 2 and read[1].user_rating == 5 and meta.complete and meta.fingerprint == nil,
    "the shelf did not come over whole, or claims a fingerprint it never had")
  assert(shelves:meta(1, 1).complete == false)
  -- the book whose synopsis was cut counts as not saved, so it is fetched whole
  local missing = books:missing({ 5, 6 })
  assert(#missing == 1 and missing[1] == 6, "missing: " .. table.concat(missing, ","))
  assert(data.shelves["1:3"] == nil, "the old file still holds the shelves")
  assert(legacy:goals(1), "goals went with the shelves")
  assert(shelves:convert(1, legacy, { 1, 2, 3, 5 }) == false, "converted twice")
end)

check("a shelf already saved here is not overwritten by the old file", function()
  local shelves = stores()
  local legacy = legacyCache()
  legacy:put(1, 3, { entry(5, 3) }, true)
  shelves:putEntries(1, 3, { entry(8, 3) }, true, FP)
  shelves:convert(1, legacy, { 3 })
  local read = shelves:entries(1, 3)
  assert(#read == 1 and read[1].book_id == 8)
end)

check("the old file's cut synopses are recognised, real ones are not", function()
  assert(BookStore.isCut(string.rep("a", 600) .. "\226\128\166"))
  assert(not BookStore.isCut("A short synopsis\226\128\166"))
  assert(not BookStore.isCut(string.rep("a", 900)))
  assert(not BookStore.isCut(nil))
end)

r.finish()
