-- Saving the details of linked books, many to a request (hardcover/lib/details_sync.lua), with the
-- store (BookStore:hasDetail, keep_all) and the batched API call (Api:getBookDetails) it uses.
--
-- Run with:  lua spec/details_sync_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_ui_stubs()
support.preload_http_stubs()
support.preload_json(PLUGIN)

local ticks = {}
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn) fn() end }
end
package.preload["ui/uimanager"] = function()
  return {
    show = function() end, setDirty = function() end, scheduleIn = function() end,
    unschedule = function() end,
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
  }
end
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return true end, isOnline = function() return true end }
end
package.preload["ffi/util"] = function()
  local util = { template = function(t) return t end }
  setmetatable(util, { __call = function(_, s) return tostring(s) end })
  return util
end
package.preload["ffi"] = function() return {} end
package.preload["ffi/pointer"] = function() return {} end
package.preload["ffi/utf8"] = function() return { char = string.char, len = string.len } end
package.preload["blitbuffer"] = function() return {} end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end

local r = support.reporter()
local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local MemoryStore = dofile(PLUGIN .. "/spec/lib/memory_store.lua")
local BookStore = require("hardcover/lib/book_store")
local DetailsSync = require("hardcover/lib/details_sync")
local BulkLink = require("hardcover/lib/bulk_link")

local function detail(id)
  return { book = { book_id = id, title = "Book " .. id, description = "About " .. id,
    editions_count = 40, release_year = 1999 } }
end

print("\n== which books need fetching ==")

check("only linked books with nothing saved, each once, in id order", function()
  local saved = { ["3/0"] = true }
  local items = DetailsSync.pending({
    ["/a.epub"] = { book_id = 9 },
    ["/b.epub"] = { book_id = 3 },              -- saved already
    ["/c.epub"] = { book_id = 9 },              -- the same book on another file
    ["/d.epub"] = { book_id = 5, edition_id = 50 },
    ["/e.epub"] = { title = "not linked" },
    ["/f.epub"] = "junk",
  }, function(book_id, edition_id) return saved[book_id .. "/" .. (edition_id or 0)] end)
  assert(#items == 2, #items)
  assert(items[1].book_id == 5 and items[1].edition_id == 50 and items[2].book_id == 9)
end)

check("a book is a different item per edition", function()
  local items = DetailsSync.pending({ ["/a"] = { book_id = 1, edition_id = 10 }, ["/b"] = { book_id = 1, edition_id = 11 },
    ["/c"] = { book_id = 1 } }, function() return false end)
  assert(#items == 3)
end)

print("\n== the scan ==")

local function itemsUpTo(n)
  local out = {}
  for i = 1, n do out[i] = { book_id = i } end
  return out
end

local function run(scan)
  local requests = 0
  while not DetailsSync.done(scan) do
    if DetailsSync.step(scan) then requests = requests + 1 end
  end
  return requests
end

check("60 books go in 3 requests of at most BATCH, each saved", function()
  local saved, batches = {}, {}
  local scan = DetailsSync.new(itemsUpTo(60), {
    fetch = function(batch)
      batches[#batches + 1] = #batch
      local out = {}
      for _, item in ipairs(batch) do out[#out + 1] = { book_id = item.book_id, detail = detail(item.book_id) } end
      return out
    end,
    save = function(book_id) saved[book_id] = true end,
  })
  assert(run(scan) == 3 and batches[1] == DetailsSync.BATCH and batches[3] == 60 - 2 * DetailsSync.BATCH)
  assert(scan.saved == 60 and scan.errors == 0 and scan.missing == 0)
end)

check("a book Hardcover has no answer for is counted as not found", function()
  local scan = DetailsSync.new(itemsUpTo(3), {
    fetch = function() return { { book_id = 1, detail = detail(1) }, { book_id = 3, detail = detail(3) } } end,
    save = function() end,
  })
  run(scan)
  assert(scan.saved == 2 and scan.missing == 1 and scan.errors == 0)
end)

check("a failed request is an error for the whole batch, not 'not found'", function()
  local scan = DetailsSync.new(itemsUpTo(30), { fetch = function() return nil end, save = function() end })
  run(scan)
  assert(scan.errors == 30 and scan.missing == 0 and scan.saved == 0)
end)

check("a request that raises is an error too, and the scan goes on", function()
  local calls = 0
  local scan = DetailsSync.new(itemsUpTo(30), {
    fetch = function(batch)
      calls = calls + 1
      if calls == 1 then error("boom") end
      local out = {}
      for _, item in ipairs(batch) do out[#out + 1] = { book_id = item.book_id, detail = detail(item.book_id) } end
      return out
    end,
    save = function() end,
  })
  run(scan)
  assert(scan.errors == 25 and scan.saved == 5, scan.errors .. "/" .. scan.saved)
end)

check("a save that fails or says false is an error, not a saved book", function()
  local n = 0
  local scan = DetailsSync.new(itemsUpTo(3), {
    fetch = function(batch)
      local out = {}
      for _, item in ipairs(batch) do out[#out + 1] = { book_id = item.book_id, detail = detail(item.book_id) } end
      return out
    end,
    save = function() n = n + 1; if n == 1 then error("disk") elseif n == 2 then return false end end,
  })
  run(scan)
  assert(scan.saved == 1 and scan.errors == 2)
end)

check("an edition's answer is matched to the edition asked for", function()
  local got = {}
  local scan = DetailsSync.new({ { book_id = 1, edition_id = 10 }, { book_id = 1 } }, {
    fetch = function() return { { book_id = 1, detail = detail(1) }, { book_id = 1, edition_id = 10, detail = detail(1) } } end,
    save = function(book_id, edition_id) got[#got + 1] = book_id .. "/" .. tostring(edition_id) end,
  })
  run(scan)
  assert(scan.saved == 2 and #got == 2)
end)

check("a run stops at MAX books and says how many were left out", function()
  local scan = DetailsSync.new(itemsUpTo(DetailsSync.MAX + 7), { fetch = function() return {} end, save = function() end })
  assert(DetailsSync.total(scan) == DetailsSync.MAX and scan.left_out == 7)
  assert(DetailsSync.summary(scan):find("7 more", 1, true))
end)

check("a cancelled scan does no more work and the summary says so", function()
  local scan = DetailsSync.new(itemsUpTo(60), { fetch = function() return {} end, save = function() end })
  DetailsSync.step(scan)
  scan.cancelled = true
  assert(DetailsSync.done(scan) and DetailsSync.step(scan) == false)
  local text = DetailsSync.summary(scan)
  assert(text:find("Stopped", 1, true) and text:find("not tried yet", 1, true), text)
end)

print("\n== the store ==")

local function store()
  local db = MemoryStore.new()
  return BookStore:new { db = db, now = function() return 1000 end }, db
end

check("hasDetail is true only for the book and edition that were saved", function()
  local books = store()
  assert(books:saveDetail(1, nil, detail(1)) and books:saveDetail(2, 20, detail(2)))
  assert(books:hasDetail(1) and books:hasDetail(2, 20))
  assert(not books:hasDetail(2) and not books:hasDetail(1, 20) and not books:hasDetail(3) and not books:hasDetail("x"))
end)

check("saving many with keep_all does not push earlier ones out until evict", function()
  local books, db = store()
  for i = 1, BookStore.OPENED_CAP + 20 do books:saveDetail(i, nil, detail(i), true) end
  assert(db:count("details") == BookStore.OPENED_CAP + 20, db:count("details"))
  books:evict()
  assert(db:count("details") == BookStore.OPENED_CAP, db:count("details"))
end)

check("saveDetail without keep_all still evicts as before", function()
  local books, db = store()
  for i = 1, BookStore.OPENED_CAP + 5 do books:saveDetail(i, nil, detail(i)) end
  assert(db:count("details") == BookStore.OPENED_CAP)
end)

print("\n== after linking ==")

check("shelves are downloaded, checked first, only when a book was linked", function()
  local asked = {}
  local download = function(status_id, opts) asked[#asked + 1] = { status_id, opts.check } end
  assert(BulkLink.syncShelves({ linked = {} }, { 1, 2, 3 }, download) == 0 and #asked == 0)
  assert(BulkLink.syncShelves({ linked = { {} } }, { 1, 2, 3 }, download) == 3)
  assert(#asked == 3 and asked[1][2] == true)
end)

check("what a scan linked is shaped for the details run", function()
  local settings = BulkLink.linkedSettings({ linked = {
    { file = "/a.epub", book_id = 4, edition_id = 8 }, { name = "no file", book_id = 5 } } })
  assert(settings["/a.epub"].book_id == 4 and settings["/a.epub"].edition_id == 8)
  local n = 0
  for _ in pairs(settings) do n = n + 1 end
  assert(n == 1)
end)

check("a linked book carries its file and ids for the details run", function()
  local scan = BulkLink.new({ "/a.epub" }, {
    read_identifiers = function() return "isbn13:9780441172719" end,
    lookup_batch = function() return { { book_id = 7, edition_id = 3, title = "Dune" } } end,
    store = function() end,
  })
  while not BulkLink.done(scan) do BulkLink.step(scan) end
  local link = scan.linked[1]
  assert(link.file == "/a.epub" and link.book_id == 7 and link.edition_id == 3)
end)

print("\n== the API call ==")

local Api = require("hardcover/lib/hardcover_api")
Api.auth = nil

local function fakeApi(books, editions)
  local calls = {}
  Api.query = function(_, query, variables)
    calls[#calls + 1] = { query = query, ids = variables.ids }
    if query:find("editions%(where") then return { editions = editions or {} } end
    return { books = books or {} }
  end
  return calls
end

check("books asked for by themselves and through an edition take two requests, however many", function()
  local calls = fakeApi({ { book_id = 1, title = "One" }, { book_id = 2, title = "Two" } },
    { { id = 30, isbn_13 = "9780000000009", book = { book_id = 3, title = "Three" } } })
  local items = {}
  for i = 1, 20 do items[i] = { book_id = i } end
  items[21] = { book_id = 3, edition_id = 30 }
  local answers = Api:getBookDetails(items, 1)
  assert(#calls == 2, #calls)
  assert(#answers == 3)
end)

check("each answer says which book and edition it is for", function()
  fakeApi({ { book_id = 1, title = "One", user_books = { { id = 9, status_id = 2 } } } },
    { { id = 30, isbn_13 = "9780000000009", pages = 500, book = { book_id = 3, title = "Three" } } })
  local answers = Api:getBookDetails({ { book_id = 1 }, { book_id = 3, edition_id = 30 } }, 1)
  local by = {}
  for _, a in ipairs(answers) do by[a.book_id .. "/" .. tostring(a.edition_id)] = a.detail end
  assert(by["1/nil"].book.title == "One" and by["1/nil"].status_id == 2)
  assert(by["3/30"].book.isbn_13 == "9780000000009" and by["3/30"].book.pages == 500 and by["3/30"].book.edition_id == 30)
end)

check("nothing to ask is no request; a failed request is nil, not an empty list", function()
  local calls = fakeApi()
  assert(#Api:getBookDetails({}, 1) == 0 and #calls == 0)
  Api.query = function() return nil end
  assert(Api:getBookDetails({ { book_id = 1 } }, 1) == nil)
  assert(Api:getBookDetails({ { book_id = 1, edition_id = 2 } }, 1) == nil)
end)

check("the single details call still gives the same answer", function()
  Api.query = function()
    return { editions = { { id = 30, isbn_13 = "9780000000009", pages = 500, book = { book_id = 3, title = "Three",
      user_books = { { id = 9, status_id = 3, rating = 5 } } } } } }
  end
  local d = Api:getBookDetail(3, 1, 30)
  assert(d.book.edition_id == 30 and d.book.pages == 500 and d.user_book_id == 9 and d.status_id == 3 and d.user_rating == 5)
  Api.query = function() return { books = { { book_id = 3, title = "Three" } } } end
  assert(Api:getBookDetail(3, 1).book.title == "Three")
  Api.query = function() return { books = {} } end
  assert(Api:getBookDetail(3, 1) == nil)
end)

r.finish()
