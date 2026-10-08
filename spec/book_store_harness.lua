-- The book store and the list store: each book kept once, a list kept as which books it
-- holds, what comes back, and what goes.
--
-- Over the in-memory stand-in for the SQLite file (spec/lib/memory_store.lua), with the
-- real JSON on the way in and out. The SQLite file itself is checked in the emulator
-- (spec/emu/scenarios/offline_lists.lua).
--
-- Run with:  lua spec/book_store_harness.lua [plugin-root]

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
local Lists = require("hardcover/lib/lists")

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local clock = 1000
local function stores()
  local db = MemoryStore.new()
  local books = BookStore:new { db = db, now = function() return clock end }
  local lists = ListStore:new { db = db, books = books, now = function() return clock end }
  return books, lists, db
end

local function entry(id, extra)
  local e = {
    book_id = id, title = "Book " .. id, authors = "A. Writer", description = "Synopsis of " .. id,
    release_year = 2001, pages = 300, community_rating = 4.2, ratings_count = 10,
    cached_image = { url = "https://x/" .. id .. ".jpg", width = 300, height = 450 },
    contributions = { { author = { name = "A. Writer" } } },
    book_series = { { position = 1, series = { name = "S" } } },
    -- what a list or shelf row also carries, and must not end up in the book's record
    user_book_id = 77, status_id = 3, user_rating = 5, list_book_id = 900 + id, rank = 1, date_added = "2024-01-01",
  }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end

local function listRow(id, extra)
  local row = { id = id, source = "mine", name = "List " .. id, count = 2, ranked = false,
                updated_at = "2026-10-08T15:22:25.183388+00:00", covers = {} }
  for k, v in pairs(extra or {}) do row[k] = v end
  row.fingerprint = Lists.fingerprint(row)
  return row
end

print("\n== books, once each ==")

check("a book's row keeps what describes the book and none of your own data", function()
  local books = stores()
  assert(books:saveRows({ entry(1) }))
  local row = books:rows({ 1 })[1]
  assert(row and row.title == "Book 1" and row.description == "Synopsis of 1", "row lost the book")
  assert(row.cached_image.url == "https://x/1.jpg" and row.contributions[1].author.name == "A. Writer")
  for _, field in ipairs({ "user_book_id", "status_id", "user_rating", "list_book_id", "rank", "date_added" }) do
    assert(row[field] == nil, field .. " was kept in the book's record")
  end
end)

check("a book on two lists is saved once", function()
  local books, _, db = stores()
  books:saveRows({ entry(1), entry(2) })
  books:saveRows({ entry(1), entry(3) })
  assert(db:count("books") == 3, "books: " .. db:count("books"))
end)

check("the full synopsis is kept (the shelf cache cut it to 600 characters)", function()
  local books = stores()
  local long = string.rep("word ", 400)
  books:saveRows({ entry(1, { description = long }) })
  assert(books:rows({ 1 })[1].description == long)
end)

check("missing says which books are not saved, in order, each once", function()
  local books = stores()
  books:saveRows({ entry(2) })
  local m = books:missing({ 3, 2, 1, 3, "4" })
  assert(#m == 3 and m[1] == 3 and m[2] == 1 and m[3] == 4, table.concat(m, ","))
end)

check("an entry with no book id is skipped, not saved as junk", function()
  local books, _, db = stores()
  assert(books:saveRows({ { title = "no id" }, entry(5), "junk" }))
  assert(db:count("books") == 1)
end)

check("a store that cannot be opened answers nothing and raises nothing", function()
  local books, lists, db = stores()
  db.fail = true
  assert(books:saveRows({ entry(1) }) == false)
  assert(next(books:rows({ 1 })) == nil)
  assert(books:detail(1) == nil)
  assert(lists:index(1) == nil and lists:entries(1, listRow(1)) == nil)
end)

print("\n== a book's details ==")

local function detail(id, extra)
  local book = { book_id = id, title = "Book " .. id, subtitle = "Sub", description = "Full synopsis",
    rating = 4.5, ratings_count = 99, users_count = 1000, release_date = "2001-02-03",
    cached_tags = { Genre = { { tag = "Fantasy" } } },
    user_books = { { id = 77, status_id = 2, rating = 4 } } }
  for k, v in pairs(extra or {}) do book[k] = v end
  return { book = book, user_book_id = 77, status_id = 2, user_rating = 4 }
end

check("details fetched online come back offline, without your status or rating", function()
  local books = stores()
  assert(books:saveDetail(1, nil, detail(1)))
  local d, source = books:detail(1)
  assert(source == "details" and d.book.subtitle == "Sub" and d.book.cached_tags.Genre[1].tag == "Fantasy")
  assert(d.book.user_books == nil and d.user_book_id == nil and d.status_id == nil, "your data was kept")
end)

check("opening a book refreshes the numbers its list row shows", function()
  local books = stores()
  books:saveRows({ entry(1, { community_rating = 3.0, ratings_count = 1 }) })
  books:saveDetail(1, nil, detail(1))
  local row = books:rows({ 1 })[1]
  assert(row.community_rating == 4.5 and row.ratings_count == 99, "row kept the old numbers")
end)

check("an edition's details are kept apart, and do not overwrite the book's row", function()
  local books = stores()
  books:saveRows({ entry(1, { pages = 300 }) })
  books:saveDetail(1, 55, detail(1, { pages = 999, publisher = { name = "Tor" } }))
  assert(books:rows({ 1 })[1].pages == 300, "the edition's page count reached the book's row")
  local d = books:detail(1, 55)
  assert(d.book.publisher.name == "Tor")
  -- asked for without an edition, the only saved details are still better than a row
  local any, source = books:detail(1)
  assert(source == "details" and any.book.publisher.name == "Tor")
end)

check("a book only a list knows still opens, from its row", function()
  local books = stores()
  books:saveRows({ entry(1) })
  local d, source = books:detail(1)
  assert(source == "row" and d.book.description == "Synopsis of 1" and d.book.rating == 4.2)
end)

check("a book nothing knows is nil", function()
  assert(stores():detail(42) == nil)
end)

check("only the last OPENED_CAP books opened keep their details", function()
  local books, _, db = stores()
  local cap = BookStore.OPENED_CAP
  BookStore.OPENED_CAP = 3
  for id = 1, 5 do books:saveDetail(id, nil, detail(id)) end
  BookStore.OPENED_CAP = cap
  assert(db:count("details") == 3, "details: " .. db:count("details"))
  assert(books:detail(1) == nil and books:detail(5) ~= nil, "the oldest were not the ones dropped")
end)

check("a JSON null read back is nil, not a placeholder", function()
  local books, _, db = stores()
  db:putRows({ { book_id = 9, row = '{"book_id":9,"title":"T","pages":null}' } }, 0)
  local row = books:rows({ 9 })[9]
  assert(row.title == "T" and row.pages == nil)
end)

print("\n== your lists ==")

check("the index comes back as saved, with when it was checked", function()
  local _, lists = stores()
  clock = 2000
  assert(lists:putIndex(1, { mine = { listRow(10) }, following = { listRow(11, { source = "followed" }) } }))
  local index = lists:index(1)
  assert(#index.mine == 1 and index.mine[1].name == "List 10" and index.following[1].source == "followed")
  assert(index.checked_at == 2000 and index.saved_at == 2000)
  clock = 2100
  lists:markChecked(1)
  assert(lists:index(1).checked_at == 2100 and lists:index(1).saved_at == 2000)
end)

check("another account never sees your lists", function()
  local _, lists = stores()
  lists:putIndex(1, { mine = { listRow(10) }, following = {} })
  assert(lists:index(2) == nil)
end)

check("a list comes back in its order, its books from the book store, ranked from 1", function()
  local _, lists = stores()
  local row = listRow(10, { ranked = true })
  local a, b = entry(1, { position = 0 }), entry(2, { position = 1 })
  assert(lists:putEntries(1, row, { a, b }, true))
  local shown, saved = lists:entries(1, row)
  assert(#shown == 2 and shown[1].book_id == 1 and shown[2].book_id == 2)
  assert(shown[1].rank == 1 and shown[2].rank == 2, "ranks: " .. tostring(shown[1].rank))
  assert(shown[1].list_book_id == 901 and shown[1].description == "Synopsis of 1")
  assert(saved.complete == true and saved.fingerprint == row.fingerprint)
end)

check("an unranked list carries no rank", function()
  local _, lists = stores()
  local row = listRow(10)
  lists:putEntries(1, row, { entry(1, { position = 0 }) }, true)
  assert(lists:entries(1, row)[1].rank == nil)
end)

check("a list saved as membership joins the books already saved", function()
  local books, lists = stores()
  books:saveRows({ entry(1), entry(2) })
  local row = listRow(10)
  assert(lists:putMembers(1, row, {
    { list_book_id = 5, position = 0, book_id = 2, date_added = "x" },
    { list_book_id = 6, position = 1, book_id = 1, date_added = "y" },
  }, true))
  local shown = lists:entries(1, row)
  assert(#shown == 2 and shown[1].book_id == 2 and shown[1].list_book_id == 5 and shown[2].date_added == "y")
end)

check("a list never saved is nil; an empty list is an answer", function()
  local _, lists = stores()
  assert(lists:entries(1, listRow(10)) == nil)
  lists:putEntries(1, listRow(10), {}, true)
  local shown, saved = lists:entries(1, listRow(10))
  assert(shown and #shown == 0 and saved.complete)
end)

check("a list that left the index is forgotten, and its books can go", function()
  local books, lists, db = stores()
  lists:putIndex(1, { mine = { listRow(10), listRow(11) }, following = {} })
  lists:putEntries(1, listRow(10), { entry(1) }, true)
  lists:putEntries(1, listRow(11), { entry(2) }, true)
  lists:putIndex(1, { mine = { listRow(11) }, following = {} })
  assert(lists:contents(1, 10) == nil, "the deleted list is still saved")
  assert(db:count("books") == 1 and books:rows({ 2 })[2], "the deleted list's book stayed, or the wrong one went")
end)

check("a book a list no longer holds goes when the list is saved again", function()
  local _, lists, db = stores()
  lists:putEntries(1, listRow(10), { entry(1), entry(2) }, true)
  lists:putMembers(1, listRow(10), { { list_book_id = 5, position = 0, book_id = 2 } }, true)
  assert(db:count("books") == 1 and db.books[2], "the dropped book stayed")
end)

check("eviction keeps books a list holds, and books opened recently", function()
  local books, lists, db = stores()
  lists:putEntries(1, listRow(10), { entry(1) }, true)
  books:saveRows({ entry(2), entry(3) })
  books:saveDetail(3, nil, detail(3))
  books:evict()
  assert(books:rows({ 1 })[1] and books:rows({ 3 })[3], "a kept book went")
  assert(books:rows({ 2 })[2] == nil, "a book nothing holds stayed")
  assert(db:count("books") == 2)
end)

check("sign out clears everything", function()
  local books, lists, db = stores()
  lists:putIndex(1, { mine = { listRow(10) }, following = {} })
  lists:putEntries(1, listRow(10), { entry(1) }, true)
  books:saveDetail(1, nil, detail(1))
  assert(books:clear())
  assert(lists:index(1) == nil and books:detail(1) == nil and db:count("books") == 0)
end)

print("\n== real data round trip ==")

-- The shelf rows saved on this Mac by KOReader, when there are any: every one must come
-- back from the store exactly as it went in.
check("every saved shelf row on this machine survives the store unchanged", function()
  local path = (os.getenv("HOME") or "") .. "/Library/Application Support/koreader/settings/hardcovershelf_cache.lua"
  local chunk = loadfile(path)
  if not chunk then return end -- no KOReader here: nothing to compare
  local ok, saved = pcall(chunk)
  if not ok or type(saved) ~= "table" or type(saved.shelves) ~= "table" then return end
  local books = stores()
  local n = 0
  local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end
  for _, shelf in pairs(saved.shelves) do
    for _, e in ipairs(shelf.entries or {}) do
      books:saveRows({ e })
      local back = books:rows({ e.book_id })[e.book_id]
      assert(same(BookStore.rowOf(e), back), "book " .. tostring(e.book_id) .. " changed on the way")
      n = n + 1
    end
  end
  print("    (" .. n .. " real rows)")
end)

r.finish()
