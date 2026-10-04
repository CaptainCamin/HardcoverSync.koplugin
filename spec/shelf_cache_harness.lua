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

print("\n== storing and reading a shelf ==")

check("a stored list comes back with its completeness and a timestamp", function()
  local c = newCache()
  assert(c:put(1, 1, { entry(1), entry(2) }, true))
  local shelf = c:get(1, 1)
  assert(#shelf.entries == 2 and shelf.complete == true and shelf.saved_at, "list lost data")
end)

check("an unseen shelf is nil", function()
  assert(newCache():get(1, 1) == nil)
end)

check("a partial list is marked as partial", function()
  local c = newCache()
  c:put(1, 1, { entry(1) }, false)
  assert(c:get(1, 1).complete == false)
end)

check("saving again replaces the list", function()
  local c = newCache()
  c:put(1, 1, { entry(1), entry(2), entry(3) }, true)
  c:put(1, 1, { entry(9) }, true)
  local shelf = c:get(1, 1)
  assert(#shelf.entries == 1 and shelf.entries[1].book_id == 9, "old rows survived")
end)

check("each write reaches disk", function()
  local c, store = newCache()
  c:put(1, 1, { entry(1) }, true)
  assert(store.flushes == 1, "flushes: " .. store.flushes)
end)

check("an empty shelf is cacheable (it is an answer)", function()
  local c = newCache()
  assert(c:put(1, 1, {}, true))
  assert(c:get(1, 1) and #c:get(1, 1).entries == 0)
end)

check("the caller's rows are not modified", function()
  local c = newCache()
  local rows = { { book_id = 1, description = string.rep("x", 5000) } }
  c:put(1, 1, rows, true)
  assert(#rows[1].description == 5000, "the original row was truncated")
end)

check("a very long shelf is kept, but marked incomplete", function()
  local c = newCache()
  local rows = {}
  for i = 1, 3200 do rows[i] = entry(i) end
  c:put(1, 1, rows, true)
  local shelf = c:get(1, 1)
  assert(#shelf.entries == 3000, "kept " .. #shelf.entries)
  assert(shelf.complete == false, "a truncated list claimed to be complete")
end)

print("\n== descriptions ==")

check("a long description is shortened", function()
  local c = newCache()
  c:put(1, 1, { { book_id = 1, description = string.rep("a", 5000) } }, true)
  local d = c:get(1, 1).entries[1].description
  assert(#d < 700 and #d > 500, "length " .. #d)
end)

check("shortening never splits a multi-byte character", function()
  local c = newCache()
  -- 3-byte characters, so any cut that is not a multiple of 3 lands mid-character
  local text = string.rep("\228\184\150", 400) -- U+4E16 as bytes
  for _, extra in ipairs({ "", "a", "ab" }) do
    c:put(1, 1, { { book_id = 1, description = extra .. text } }, true)
    local d = c:get(1, 1).entries[1].description
    -- strip the ellipsis, then what is left must be whole characters
    local body = d:gsub("\226\128\166$", "")
    local ok = true
    local i = 1 + #extra
    body = body:sub(1 + #extra)
    assert(#body % 3 == 0, "cut inside a character (extra=" .. #extra .. ", left " .. #body .. " bytes)")
  end
end)

check("a short description is left alone", function()
  local c = newCache()
  c:put(1, 1, { { book_id = 1, description = "short" } }, true)
  assert(c:get(1, 1).entries[1].description == "short")
end)

print("\n== scoping ==")

check("shelves are separate per status", function()
  local c = newCache()
  c:put(1, 1, { entry(1) }, true)
  assert(c:get(1, 2) == nil)
end)

check("another account never sees this account's shelf", function()
  local c = newCache()
  c:put(1, 1, { entry(1) }, true)
  assert(c:get(2, 1) == nil, "a different user read the cached library")
  assert(c:findEntry(2, 1) == nil, "a different user found a cached book")
end)

check("clear removes everything", function()
  local c = newCache()
  c:put(1, 1, { entry(1) }, true)
  c:put(1, 2, { entry(2) }, true)
  assert(c:clear())
  assert(c:get(1, 1) == nil and c:get(1, 2) == nil)
end)

print("\n== finding a book ==")

check("a book is found across shelves", function()
  local c = newCache()
  c:put(1, 1, { entry(1), entry(7, "Seven") }, true)
  c:put(1, 2, { entry(5, "Five") }, true)
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
  assert(c:get(1, 1) == nil)
  assert(c:put(1, 1, { entry(1) }, false) == false)
  assert(c:findEntry(1, 1) == nil)
  assert(c:clear() == false)
  assert(n == 1, "retried a broken file " .. n .. " times")
end)

check("a failing flush does not raise", function()
  local store = newStore()
  store.flush = function() error("disk full") end
  local c = newCache(store)
  c:put(1, 1, { entry(1) }, false) -- must not raise
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

print("\n== the home screen's small file ==")

-- two files, as on a device: the shelves, and the counts and reading list
local function newPair()
  local stores = {}
  local opened = {}
  local c = ShelfCache:new {
    path = "/data/shelf_cache.lua",
    open = function(path)
      opened[#opened + 1] = path
      stores[path] = stores[path] or newStore()
      return stores[path]
    end,
  }
  return c, stores, opened
end

check("counts and the reading list live in a file of their own", function()
  local c, stores = newPair()
  c:putCounts(1, { [1] = 5 })
  c:putReading(1, { { book_id = 3, title = "T" } })
  c:put(1, 1, { entry(1) }, true)
  local small, big = stores["/data/shelf_cache_home.lua"], stores["/data/shelf_cache.lua"]
  assert(small and small:readSetting("counts") and small:readSetting("reading"), "home data is not in the small file")
  assert(big:readSetting("counts") == nil and big:readSetting("reading") == nil, "home data leaked into the shelf file")
  assert(small:readSetting("shelves") == nil, "shelves leaked into the small file")
end)

check("opening home never reads the shelf file when the numbers are saved", function()
  local c, stores = newPair()
  c:putCounts(1, { [1] = 5, [2] = 3, [3] = 9, [5] = 0 })
  c:putReading(1, { { book_id = 3, title = "T" } })
  -- a later session: a new object over the same files, noting what it opens
  local opened = {}
  local later = ShelfCache:new {
    path = "/data/shelf_cache.lua",
    open = function(path) opened[#opened + 1] = path; stores[path] = stores[path] or newStore(); return stores[path] end,
  }
  local counts = later:counts(1, { 1, 2, 3, 5 })
  assert(later:reading(1)[1].book_id == 3)
  assert(counts[1] == 5 and counts[5] == 0, "counts did not come back")
  for _, path in ipairs(opened) do
    assert(path ~= "/data/shelf_cache.lua", "the shelf file was opened to read counts and the reading list")
  end
end)

check("saving the counts it already has writes nothing", function()
  local c, stores = newPair()
  c:putCounts(1, { [1] = 5, [2] = 3 })
  local small = stores["/data/shelf_cache_home.lua"]
  local before = small.flushes
  assert(c:putCounts(1, { [1] = 5, [2] = 3 }) == true)
  assert(small.flushes == before, "an unchanged count was written again")
  c:putCounts(1, { [1] = 6, [2] = 3 })
  assert(small.flushes == before + 1, "a changed count was not written")
  assert(c:counts(1, { 1 })[1] == 6)
end)

check("saving the reading list it already has writes nothing", function()
  local c, stores = newPair()
  c:putReading(1, { { book_id = 3, title = "T", progress_pages = 10 } })
  local small = stores["/data/shelf_cache_home.lua"]
  local before = small.flushes
  c:putReading(1, { { book_id = 3, title = "T", progress_pages = 10, description = "dropped anyway" } })
  assert(small.flushes == before, "an unchanged reading list was written again")
  c:putReading(1, { { book_id = 3, title = "T", progress_pages = 11 } })
  assert(small.flushes == before + 1, "progress did not reach disk")
  assert(c:reading(1)[1].progress_pages == 11)
end)

check("a shelf that comes back unchanged is not rewritten, a changed one is", function()
  local c, stores = newPair()
  c:put(1, 1, { entry(1), entry(2) }, true)
  local big = stores["/data/shelf_cache.lua"]
  local before = big.flushes
  c:put(1, 1, { entry(1), entry(2) }, true)
  assert(big.flushes == before, "an unchanged shelf was written again")
  c:put(1, 1, { entry(1), entry(2), entry(3) }, true)
  assert(big.flushes == before + 1, "a changed shelf was not written")
  c:put(1, 1, { entry(1), entry(2), entry(3) }, false)
  assert(big.flushes == before + 2, "a shelf that stopped being complete was not written")
end)

check("counts and a reading list saved by an earlier version are still read", function()
  local c, stores = newPair()
  local big = newStore()
  stores["/data/shelf_cache.lua"] = big
  big:saveSetting("counts", { ["1"] = { s1 = 42 } })
  big:saveSetting("reading", { ["1"] = { entries = { { book_id = 9, title = "Old" } } } })
  assert(c:counts(1, { 1 })[1] == 42, "old counts were lost")
  assert(c:reading(1)[1].book_id == 9, "the old reading list was lost")
end)

check("invalidate and clear empty the small file too, and the old copy does not return", function()
  local c, stores = newPair()
  local big = newStore()
  stores["/data/shelf_cache.lua"] = big
  big:saveSetting("counts", { ["1"] = { s1 = 42 } })
  c:putCounts(1, { [1] = 7 })
  c:putReading(1, { { book_id = 3, title = "T" } })
  c:invalidate(1, { 1 })
  assert(c:counts(1, { 1 })[1] == nil, "counts survived invalidate")
  assert(c:reading(1) == nil, "the reading list survived invalidate")
  c:putCounts(1, { [1] = 7 })
  c:clear()
  assert(c:counts(1, { 1 })[1] == nil and c:reading(1) == nil, "clear left home data behind")
end)

check("the For you picks are saved apart, with when, per user; descriptions are dropped; clear forgets them", function()
  local c = newPair()
  assert(c:forYou(1) == nil, "something saved from the start")
  assert(c:putForYou(1, { { book_id = 5, title = "T", reason = "Wool", description = "long text" } }) ~= false)
  local entries, at = c:forYou(1)
  assert(#entries == 1 and entries[1].reason == "Wool" and entries[1].description == nil, "entry")
  assert(type(at) == "number", "no date")
  assert(c:forYou(2) == nil, "another user's picks")
  assert(c:counts(1, { 1 })[1] == nil and c:reading(1) == nil, "the picks leaked into the home data")
  c:clear()
  assert(c:forYou(1) == nil, "clear left the picks behind")
  assert(c:putForYou(1, "junk") == false)
end)

check("Stats rows are saved per user, marked stale by a shelf change (and kept), and cleared with the rest", function()
  local c = newCache()
  assert(c:stats(1) == nil)
  assert(c:putStats(1, { rows = { { id = 1 } }, genres = { { label = "A", value = 1 } }, complete = true }))
  local saved = c:stats(1)
  assert(#saved.rows == 1 and saved.saved_at and not saved.stale and saved.complete == true)
  assert(c:stats(2) == nil, "another user's stats")
  c:invalidate(1, { 3 })
  assert(c:stats(1) and c:stats(1).stale == true and #c:stats(1).rows == 1, "stale copy not kept")
  assert(c:putStats(1, "junk") == false)
  c:putStats(1, { rows = {} })
  assert(not c:stats(1).stale, "a fresh save is not stale")
  c:clear()
  assert(c:stats(1) == nil, "clear left stats behind")
end)

r.finish()
