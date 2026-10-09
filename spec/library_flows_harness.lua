-- The rest of the library on the device, through DialogManager: a book's details shown
-- from the device and brought up to date by the similar-books request, the series kept
-- for a week, changes made here applied to the saved shelves, Home keeping every shelf
-- saved, and Stats and For you fetched only when what they come from changed.
--
-- Fake dialogs and a recording API; the stores are the real ones over the in-memory
-- stand-in for the SQLite file.
--
-- Run with:  lua spec/library_flows_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local json = dofile(PLUGIN .. "/spec/json.lua")
package.preload["json"] = function() return json end

local function make()
  return setmetatable({}, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end

local online = true
local stack = {}
package.preload["ui/uimanager"] = function()
  return {
    show = function(_, w) stack[#stack + 1] = w end,
    close = function(_, w) for i = #stack, 1, -1 do if stack[i] == w then table.remove(stack, i) end end end,
    isWidgetShown = function(_, w) for _, x in ipairs(stack) do if x == w then return true end end return false end,
    setDirty = function() end, scheduleIn = function() end, unschedule = function() end,
    nextTick = function(_, fn) fn() end,
  }
end
package.preload["ui/trapper"] = function()
  return {
    wrap = function(_, fn)
      local ok, err = coroutine.resume(coroutine.create(fn))
      if not ok then error("wrapped function raised: " .. tostring(err), 0) end
    end,
  }
end
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return online end }
end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["ffi/util"] = function()
  return { template = function(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
  end }
end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local Api = real_require("hardcover/lib/hardcover_api")
local User = real_require("hardcover/lib/user")
local StatusDialogs = real_require("hardcover/lib/ui/status_dialogs")
local BookStore = real_require("hardcover/lib/book_store")
local ShelfStore = real_require("hardcover/lib/shelf_store")
local ShelfCache = real_require("hardcover/lib/shelf_cache")
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
local MemoryStore = dofile(PLUGIN .. "/spec/lib/memory_store.lua")
real_require("hardcover/lib/background").sleep = function() end
User.getId = function() return 1 end
User.refreshName = function() end

-- ------------------------------------------------------------ the API, recorded
local calls, answers
local function call(name, ...) calls[#calls + 1] = { name = name, args = { ... } } end
local function named(name)
  local n = 0
  for _, c in ipairs(calls) do if c.name == name then n = n + 1 end end
  return n
end

local pending = {}
Api.getBookDetailAsync = function(_, book_id, _, _, cb) call("getBookDetail", book_id); pending.detail = cb end
Api.getSeriesBooks = function(_, series_id) call("getSeriesBooks", series_id) return answers.series end
Api.getSimilarBooksAsync = function(_, book_id, _, user_id, cb)
  call("getSimilarBooks", book_id, user_id)
  cb({}, nil, answers.about)
end
Api.getShelfCounts = function(_, _, ids)
  call("getShelfCounts", ids)
  local prints = {}
  for _, id in ipairs(ids) do prints[id] = answers.prints and answers.prints[id] end
  return {}, nil, prints
end
Api.getShelfCountsAsync = function(_, user_id, ids, cb) cb(Api.getShelfCounts(Api, user_id, ids)) end
Api.getShelf = function(_, _, status_id, offset)
  call("getShelf", status_id, offset)
  return {}, nil, false
end
Api.getShelfMembers = function(_, _, status_id, offset)
  call("getShelfMembers", status_id, offset)
  return {}, nil, false
end
Api.getBooksByIds = function(_, ids) call("getBooksByIds", ids) return {} end
Api.getStatsAsync = function(_, _, cb) call("getStats"); cb({ rows = { { title = "x" } }, genres = {}, complete = true }) end
Api.getForYouAsync = function(_, cb) call("getForYou"); cb({ { book_id = 77, title = "Pick" } }) end
Api.getCurrentlyReading = function() call("getCurrentlyReading") return nil end
Api.getListCount = function() call("getListCount") return nil end
Api.getGoals = function() call("getGoals") return nil end

local infos
StatusDialogs.info = function(text) infos[#infos + 1] = text end
StatusDialogs.loading = function() return {} end
StatusDialogs.close = function() end
StatusDialogs.retry = function() end

-- ------------------------------------------------------------ fake screens
local shown = {}
local function fakeClass(path, kind)
  local class = real_require(path)
  class.new = function(_, o)
    o = o or {}
    o.setEntries = function(self, entries) self.entries = entries end
    o.setEmptyState = function(self, m) self.empty = m end
    o.setDetail = function(self, d) self.detail = d; self.details_set = (self.details_set or 0) + 1 end
    o.setSeries = function(self, card) self.series = card end
    o.setSimilar = function(self, card) self.similar = card end
    o.setStatus = function(self, status_id, ubid)
      self.detail.status_id, self.detail.user_book_id = status_id, ubid
      self.status_set = (self.status_set or 0) + 1
    end
    o.setRating = function(self, rating)
      self.detail.user_rating = (tonumber(rating) or 0) > 0 and rating or nil
      self.rating_set = (self.rating_set or 0) + 1
    end
    o.setStats = function(self, stats) self.stats = stats end
    o.setRows = function() end
    o.setReading = function() end
    o.rebuild = function() end
    o.rebuildSoon = function() end
    o.free = function() end
    shown[kind] = o
    return o
  end
end
fakeClass("hardcover/lib/ui/book_detail_dialog", "detail")
fakeClass("hardcover/lib/ui/shelf_dialog", "shelf")
fakeClass("hardcover/lib/ui/stats_dialog", "stats")
fakeClass("hardcover/lib/ui/home_dialog", "home")
fakeClass("hardcover/lib/ui/lists_dialog", "lists")

local clock = 1000000
local FP = { [1] = "1|A|", [2] = "1|B|", [3] = "2|C|9.0", [5] = "0||" }

local function newManager(opts)
  opts = opts or {}
  calls, infos, stack, shown, pending = {}, {}, {}, {}, {}
  online = true
  answers = { prints = {} }
  for k, v in pairs(FP) do answers.prints[k] = v end
  local db = MemoryStore.new()
  local books = BookStore:new { db = db, now = function() return clock end }
  local shelves = ShelfStore:new { db = db, books = books, now = function() return clock end }
  local cache_data, home_data = {}, {}
  local function settings(data)
    return { readSetting = function(_, k) return data[k] end, saveSetting = function(_, k, v) data[k] = v end,
             flush = function() end }
  end
  local m = setmetatable({
    settings = { compatibilityMode = function() return false end, readSetting = function() end,
                 updateSetting = function() end },
    shelf_cache = ShelfCache:new { path = "/x.lua", open = function(p)
      return p:find("_home") and settings(home_data) or settings(cache_data)
    end },
    book_store = books,
    shelf_store = shelves,
  }, { __index = DialogManager })
  if opts.synced ~= false then
    -- every shelf saved whole, as Home leaves them; book 5 on Read with your 4.5
    shelves:putEntries(1, 1, { { user_book_id = 101, book_id = 1, title = "One" } }, true, FP[1])
    shelves:putEntries(1, 2, { { user_book_id = 102, book_id = 2, title = "Two" } }, true, FP[2])
    shelves:putEntries(1, 3, { { user_book_id = 105, book_id = 5, title = "Five", user_rating = 4.5 },
                               { user_book_id = 106, book_id = 6, title = "Six" } }, true, FP[3])
    shelves:putEntries(1, 5, {}, true, FP[5])
  end
  return m
end

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local function settledDetail(id, extra)
  local book = { book_id = id, title = "Book " .. id, description = "A synopsis", cached_image = { url = "u" },
                 pages = 300, first_release_date = "2001-01-01", release_year = 2001,
                 book_series = { { position = 1, series = { id = 9, name = "Saga" } } },
                 rating = 4.0, ratings_count = 10 }
  for k, v in pairs(extra or {}) do book[k] = v end
  return { book = book }
end

print("\n== a book's details from the device ==")

check("a settled book opens from the device: no loading line, no request for the book", function()
  local m = newManager()
  m.book_store:saveDetail(5, nil, settledDetail(5))
  answers.about = { rating = 4.0, ratings_count = 10, user_book = { id = 105, status_id = 3, rating = 4.5 } }
  m:showBookDetail(5)
  local d = shown.detail
  assert(named("getBookDetail") == 0, "the book was asked for")
  assert(d.detail and d.detail.book.title == "Book 5" and d.detail.book.description == "A synopsis")
  assert(d.detail.status_id == 3 and d.detail.user_rating == 4.5 and d.detail.user_book_id == 105,
    "status or rating did not come from the shelves")
  assert(named("getSimilarBooks") == 1, "the similar request (which brings your status) was not made")
  assert((d.status_set or 0) == 0 and (d.rating_set or 0) == 0, "redrawn though nothing changed")
end)

check("a status changed on Hardcover arrives with the similar request, and the shelves follow", function()
  local m = newManager()
  m.book_store:saveDetail(5, nil, settledDetail(5))
  answers.about = { rating = 4.1, ratings_count = 11, user_book = { id = 105, status_id = 2, rating = 5 } }
  m:showBookDetail(5)
  local d = shown.detail
  assert(d.status_set == 1 and d.detail.status_id == 2, "the new status was not shown")
  assert(d.rating_set == 1 and d.detail.user_rating == 5, "the new rating was not shown")
  local member = m.shelf_store:member(1, 5)
  assert(member.status_id == 2 and member.rating == 5, "the saved shelves still say Read")
  -- the numbers are kept for next time, without a redraw now
  assert(d.details_set == 1, "the screen was redrawn for the numbers")
  assert(m.book_store:detail(5).book.rating == 4.1)
end)

check("a book removed from the library on Hardcover leaves the saved shelf", function()
  local m = newManager()
  m.book_store:saveDetail(5, nil, settledDetail(5))
  answers.about = { user_book = false }
  m:showBookDetail(5)
  assert(shown.detail.detail.status_id == nil and m.shelf_store:member(1, 5) == nil)
end)

check("a book still to come is asked for again after a week", function()
  local m = newManager()
  m.book_store:saveDetail(5, nil, settledDetail(5, { first_release_date = "2099-01-01", release_year = 2099 }))
  m:showBookDetail(5)
  assert(named("getBookDetail") == 0, "asked again within the week")
  clock = clock + BookStore.RECHECK_AFTER + 10
  local m2 = newManager()
  m2.book_store:saveDetail(5, nil, settledDetail(5, { first_release_date = "2099-01-01", release_year = 2099 }))
  clock = clock + BookStore.RECHECK_AFTER + 10
  m2:showBookDetail(5)
  assert(named("getBookDetail") == 1, "an unreleased book was trusted past a week")
end)

check("until every shelf is saved, the book is asked for as before", function()
  local m = newManager { synced = false }
  m.book_store:saveDetail(5, nil, settledDetail(5))
  m:showBookDetail(5)
  assert(named("getBookDetail") == 1)
end)

check("a book only a list knows is asked for (its details were never fetched)", function()
  local m = newManager()
  m.book_store:saveRows({ { book_id = 8, title = "Listed", description = "x" } })
  m:showBookDetail(8)
  assert(named("getBookDetail") == 1)
end)

check("the reload icon fetches the book again, settled or not", function()
  local m = newManager()
  m.book_store:saveDetail(5, nil, settledDetail(5))
  m:showBookDetail(5)
  shown.detail.on_refresh(shown.detail)
  assert(named("getBookDetail") == 1, "the reload icon did not fetch")
end)

print("\n== the series ==")

local SERIES = { id = 9, name = "Saga", books = {
  { book_id = 5, title = "Book 5", position = 1, status_id = 1 },
  { book_id = 6, title = "Book 6", position = 2 },
} }

check("a series is kept, and shown for a week with no request", function()
  local m = newManager()
  m.book_store:saveDetail(5, nil, settledDetail(5))
  answers.series = SERIES
  m:showBookDetail(5)
  assert(named("getSeriesBooks") == 1 and shown.detail.series, "the series was not fetched the first time")
  m:showBookDetail(5)
  assert(named("getSeriesBooks") == 1, "a series saved this week was asked for again")
  assert(shown.detail.series, "the saved series was not shown")
end)

check("offline, the saved series is shown", function()
  local m = newManager()
  m.book_store:putSeries(1, 9, SERIES)
  m.book_store:saveDetail(5, nil, settledDetail(5))
  online = false
  m:showBookDetail(5)
  assert(shown.detail.series and named("getSeriesBooks") == 0)
end)

print("\n== changes made here ==")

check("moving a book to another shelf moves it in the saved shelves at once", function()
  local m = newManager()
  m:shelfChanged(6, 3, 1, 106)
  assert(m.shelf_store:member(1, 6).status_id == 1)
  assert(m.shelf_store:meta(1, 3).fingerprint == nil and m.shelf_store:meta(1, 1).fingerprint == nil,
    "the shelves will not be asked about again")
end)

check("a rating sent from the queue is on the saved shelf at once", function()
  local m = newManager()
  m:ratingSent(106, { id = 106, book_id = 6, status_id = 3, rating = 3.5 })
  assert(m.shelf_store:member(1, 6).rating == 3.5)
end)

check("a book removed from the library leaves its saved shelf", function()
  local m = newManager()
  m:shelfChanged(6, 3, nil)
  assert(m.shelf_store:member(1, 6) == nil)
end)

print("\n== Home keeps the shelves saved ==")

check("with every fingerprint as saved, Home's check downloads nothing", function()
  local m = newManager()
  calls = {}
  m:checkShelves(FP)
  assert(named("getShelf") + named("getShelfMembers") == 0, "an unchanged shelf was downloaded")
  assert(m.shelf_store:meta(1, 3).checked_at == clock)
end)

check("a changed shelf downloads its membership; one never saved downloads its books", function()
  local m = newManager { synced = false }
  m.shelf_store:putEntries(1, 3, { { user_book_id = 105, book_id = 5 } }, true, "1|old|")
  calls = {}
  m:checkShelves(FP)
  local members, full = {}, {}
  for _, c in ipairs(calls) do
    if c.name == "getShelfMembers" then members[c.args[1]] = true end
    if c.name == "getShelf" then full[c.args[1]] = true end
  end
  assert(members[3] and not full[3], "Read was downloaded in full")
  assert(full[1] and full[2] and full[5], "shelves never saved were not downloaded")
end)

check("opening Home checks the shelves after its own requests", function()
  local m = newManager { synced = false }
  m.checkForUpdate = function() end
  m:showHome()
  assert(named("getShelfCounts") == 1)
  local first_download
  for i, c in ipairs(calls) do
    if c.name == "getShelf" and not first_download then first_download = i end
  end
  local goals
  for i, c in ipairs(calls) do if c.name == "getGoals" then goals = i end end
  assert(first_download and goals and first_download > goals, "shelves were downloaded before Home finished")
end)

check("the shelves an earlier version saved are carried over before Home checks them", function()
  local m = newManager { synced = false }
  m.shelf_cache:put(1, 3, { { user_book_id = 105, book_id = 5, title = "Five", description = "s" } }, true)
  calls = {}
  m:checkShelves(FP)
  local members_for_read, full_for_read = 0, 0
  for _, c in ipairs(calls) do
    if c.args[1] == 3 and c.name == "getShelfMembers" then members_for_read = members_for_read + 1 end
    if c.args[1] == 3 and c.name == "getShelf" then full_for_read = full_for_read + 1 end
  end
  assert(members_for_read == 1 and full_for_read == 0, "the carried-over shelf was downloaded in full")
end)

print("\n== Stats ==")

check("unchanged Read, saved this week: Stats opens with no request for your books", function()
  local m = newManager()
  m.shelf_cache:putStats(1, { rows = { { title = "x" } }, genres = {} }, FP[3])
  m:showStats()
  assert(named("getStats") == 0 and named("getShelfCounts") == 0, "asked: " .. #calls)
end)

check("Read changed: Stats loads again, and keeps the new fingerprint", function()
  local m = newManager()
  m.shelf_cache:putStats(1, { rows = {}, genres = {} }, "1|old|")
  m:showStats()
  assert(named("getStats") == 1)
  assert(m.shelf_cache:stats(1).fingerprint == FP[3])
end)

check("a change made here marks Stats stale, and it loads again", function()
  local m = newManager()
  m.shelf_cache:putStats(1, { rows = {}, genres = {} }, FP[3])
  m:shelfChanged(1, 1, 3, 101)
  m.shelf_store:putEntries(1, 3, {}, true, FP[3]) -- checked again since
  m.shelf_store:putEntries(1, 1, {}, true, FP[1])
  m:showStats()
  assert(named("getStats") == 1, "stale stats were trusted")
end)

check("when Home has not checked lately, one small request decides", function()
  local m = newManager()
  m.shelf_cache:putStats(1, { rows = {}, genres = {} }, FP[3])
  clock = clock + 3600
  m:showStats()
  assert(named("getShelfCounts") == 1 and named("getStats") == 0)
end)

print("\n== For you ==")

check("ratings and shelves unchanged, picks under a week old: For you asks nothing", function()
  local m = newManager()
  local Home = real_require("hardcover/lib/home")
  local sig = real_require("hardcover/lib/shelves_sync").ratingSignature(FP, Home.statusIds())
  m.shelf_cache:putForYou(1, { { book_id = 77, title = "Pick" } }, sig)
  m:showForYou()
  assert(named("getForYou") == 0, "asked again")
  assert(#shown.shelf.entries == 1)
end)

check("a new rating makes new picks", function()
  local m = newManager()
  local Home = real_require("hardcover/lib/home")
  local sig = real_require("hardcover/lib/shelves_sync").ratingSignature(FP, Home.statusIds())
  m.shelf_cache:putForYou(1, { { book_id = 77, title = "Pick" } }, sig)
  m.shelf_store:putEntries(1, 3, {}, true, "2|C|13.5")
  m:showForYou()
  assert(named("getForYou") == 1)
end)

r.finish()
