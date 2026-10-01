-- The shelf cache: what is stored, what comes back, and what never leaks.
--
-- Run with:  lua spec/shelf_cache_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_ui_stubs()
local r = support.reporter()

local ShelfCache = require("hardcover/lib/shelf_cache")
local Shelf = require("hardcover/lib/shelf")

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

-- A LuaSettings stand-in backed by a table; counts flushes.
local function newStore()
  local data, store = {}, {}
  store.flushes = 0
  function store:readSetting(k) return data[k] end
  function store:saveSetting(k, v) data[k] = v end
  function store:flush() self.flushes = self.flushes + 1 end
  return store
end

local function newCache(store, open_counter)
  store = store or newStore()
  return ShelfCache:new {
    path = "/x",
    open = function() if open_counter then open_counter.n = open_counter.n + 1 end return store end,
  }, store
end

local function entry(id, title) return { book_id = id, title = title or ("Book " .. id), status_id = 1 } end

print("\n== storing and reading pages ==")

check("a stored page comes back with its paging flag and a timestamp", function()
  local c = newCache()
  assert(c:putPage(1, 1, 0, { entry(1), entry(2) }, true))
  local page = c:getPage(1, 1, 0)
  assert(#page.entries == 2 and page.has_more == true and page.saved_at, "page lost data")
end)

check("an unseen page is nil", function()
  local c = newCache()
  assert(c:getPage(1, 1, 0) == nil)
  c:putPage(1, 1, 0, { entry(1) }, false)
  assert(c:getPage(1, 1, 20) == nil)
end)

check("pages are kept by offset", function()
  local c = newCache()
  c:putPage(1, 1, 0, { entry(1) }, true)
  c:putPage(1, 1, 20, { entry(2) }, false)
  assert(c:getPage(1, 1, 20).entries[1].book_id == 2)
  assert(c:getPage(1, 1, 0).entries[1].book_id == 1)
end)

check("refreshing the first page drops the later ones (their offsets shifted)", function()
  local c = newCache()
  c:putPage(1, 1, 0, { entry(1) }, true)
  c:putPage(1, 1, 20, { entry(2) }, false)
  c:putPage(1, 1, 0, { entry(9) }, true)
  assert(c:getPage(1, 1, 20) == nil, "a stale later page survived")
  assert(c:getPage(1, 1, 0).entries[1].book_id == 9)
end)

check("each write reaches disk", function()
  local c, store = newCache()
  c:putPage(1, 1, 0, { entry(1) }, false)
  assert(store.flushes == 1, "flushes: " .. store.flushes)
end)

check("an empty shelf is cacheable (it is an answer)", function()
  local c = newCache()
  assert(c:putPage(1, 1, 0, {}, false))
  assert(c:getPage(1, 1, 0) and #c:getPage(1, 1, 0).entries == 0)
end)

check("pages far down a large library are not kept", function()
  local c = newCache()
  assert(c:putPage(1, 1, 400, { entry(1) }, false) == false)
  assert(c:getPage(1, 1, 400) == nil)
end)

print("\n== scoping ==")

check("shelves are separate per status", function()
  local c = newCache()
  c:putPage(1, 1, 0, { entry(1) }, false)
  assert(c:getPage(1, 2, 0) == nil)
end)

check("another account never sees this account's shelf", function()
  local c = newCache()
  c:putPage(1, 1, 0, { entry(1) }, false)
  assert(c:getPage(2, 1, 0) == nil, "a different user read the cached library")
  assert(c:findEntry(2, 1) == nil, "a different user found a cached book")
end)

check("clear removes everything", function()
  local c, store = newCache()
  c:putPage(1, 1, 0, { entry(1) }, false)
  c:putPage(1, 2, 0, { entry(2) }, false)
  assert(c:clear())
  assert(c:getPage(1, 1, 0) == nil and c:getPage(1, 2, 0) == nil)
end)

print("\n== finding a book ==")

check("a book is found across shelves and pages", function()
  local c = newCache()
  c:putPage(1, 1, 0, { entry(1) }, true)
  c:putPage(1, 2, 0, { entry(5, "Five") }, false)
  c:putPage(1, 1, 20, { entry(7, "Seven") }, false)
  assert(c:findEntry(1, 5).title == "Five")
  assert(c:findEntry(1, 7).title == "Seven")
  assert(c:findEntry(1, 99) == nil)
end)

print("\n== resilience ==")

check("nothing is opened until the cache is used", function()
  local n = { n = 0 }
  newCache(nil, n)
  assert(n.n == 0, "opened at construction")
end)

check("a store that cannot be opened fails soft, once", function()
  local n = 0
  local c = ShelfCache:new { path = "/x", open = function() n = n + 1 error("corrupt") end }
  assert(c:getPage(1, 1, 0) == nil)
  assert(c:putPage(1, 1, 0, { entry(1) }, false) == false)
  assert(c:findEntry(1, 1) == nil)
  assert(c:clear() == false)
  assert(n == 1, "retried a broken file " .. n .. " times")
end)

check("a failing flush does not raise", function()
  local store = newStore()
  store.flush = function() error("disk full") end
  local c = newCache(store)
  c:putPage(1, 1, 0, { entry(1) }, false) -- must not raise
end)

print("\n== details from a cached row ==")

check("a shelf row keeps what the detail screen needs", function()
  local row = Shelf.normalizeEntry({
    id = 10, status_id = 2, rating = 4,
    book = {
      book_id = 7, title = "T", pages = 300, release_year = 2001, description = "D",
      rating = 4.2, ratings_count = 10, users_count = 99,
      contributions = { { author = { name = "A. Author" } } },
      book_series = { { position = 3, series = { name = "Saga" } } },
    },
  })
  local detail = Shelf.detailFromEntry(row)
  assert(detail.book.title == "T" and detail.book.pages == 300 and detail.status_id == 2)
  assert(detail.user_rating == 4 and detail.user_book_id == 10)
  local rows = Shelf.detailRows(detail.book)
  local labels = {}
  for _, rw in ipairs(rows) do labels[#labels + 1] = rw[1] or rw.label end
  local text = table.concat(labels, ",")
  assert(text:find("Author") and text:find("Series") and text:find("Description"), "rows: " .. text)
end)

r.finish()
