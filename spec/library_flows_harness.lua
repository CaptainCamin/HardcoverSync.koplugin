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
local SyncQueue = real_require("hardcover/lib/sync_queue")
local HARDCOVER = real_require("hardcover/lib/constants/hardcover")
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
Api.getStatsAsync = function(_, _, cb) call("getStats"); cb({ rows = { { title = "x" } }, history = {}, genres = {}, complete = true }) end
Api.getForYouAsync = function(_, cb) call("getForYou"); cb({ { book_id = 77, title = "Pick" } }) end
Api.getCurrentlyReading = function() call("getCurrentlyReading") return nil end
Api.getHomeSummary = function() call("getHomeSummary") return nil end
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
fakeClass("hardcover/lib/ui/home_body", "home")

-- Home is a tab of the shell: a shell that is up, for the loaders' "is it still there" check
local function homeHost()
  local shell = {}
  stack[#stack + 1] = shell
  return { shell = shell }
end
fakeClass("hardcover/lib/ui/lists_dialog", "lists")

local function UIManagerShown(w) for _, x in ipairs(stack) do if x == w then return true end end return false end
local clock = 1000000
local FP = { [1] = "1|A|", [2] = "1|B|", [3] = "2|C|9.0", [4] = "0||", [5] = "0||" }

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
    shelves:putEntries(1, 4, {}, true, FP[4])
    shelves:putEntries(1, 5, {}, true, FP[5])
  end
  return m
end

local check = r.test

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

check("the counts on Home and the Shelves tab follow a book moved between shelves", function()
  local m = newManager()
  local function screen()
    local o = { rows = { { status_id = 1, count = 4 }, { status_id = 2, count = 0 }, { status_id = 3, count = nil } } }
    o.setRows = function(self, rows) self.rows = rows end
    stack[#stack + 1] = o
    return o
  end
  local home, shelves = screen(), screen()
  m:screens():track("home", home)
  m:screens():track("shelves", shelves)
  m:shelfChanged(6, 1, 2, 106, true)
  for _, s in ipairs({ home, shelves }) do
    assert(s.rows[1].count == 3 and s.rows[2].count == 1, "counts: " .. tostring(s.rows[1].count) .. ", " .. tostring(s.rows[2].count))
    assert(s.rows[3].count == nil, "an unknown count was invented")
  end
  m:shelfChanged(6, 2, nil, nil, true) -- off the library: only the shelf it left changes
  assert(home.rows[2].count == 0 and home.rows[1].count == 3)
  m:shelfChanged(6, nil, 3, 106) -- new to the library, counts for a shelf with none stay empty
  assert(home.rows[3].count == nil)
end)

check("the Currently reading card and a hidden Stats tab follow a moved book", function()
  local m = newManager()
  local READING, FINISHED = 2, 3
  local home = { rows = {}, entries = { { book_id = 2, title = "Two" }, { book_id = 9, title = "Nine" } } }
  home.setRows = function() end
  home.setReading = function(self, entries) self.entries = entries end
  stack[#stack + 1] = home
  m:screens():track("home", home)
  m:shelfChanged(2, READING, FINISHED, 102, true) -- finished: off the card
  assert(#home.entries == 1 and home.entries[1].book_id == 9, "the finished book is still on the card")
  m:shelfChanged(6, FINISHED, READING, 106, true) -- started: on the card, from the saved shelf
  assert(#home.entries == 2 and home.entries[1].book_id == 6, "the started book is not on the card")

  local unmounted
  local shell = { active = "goals", unmount = function(_, w) unmounted = w end }
  local stats = { shell = shell, free = function() end }
  stack[#stack + 1] = shell
  m:screens():track("stats", stats)
  m:shelfChanged(6, READING, 1, 106, true) -- Read not involved: Stats stays
  assert(unmounted == nil, "Stats was dropped for a change that does not touch Read")
  m:shelfChanged(6, READING, FINISHED, 106, true)
  assert(unmounted == stats, "a hidden Stats tab was kept after a book was finished")

  local visible = { shell = { active = "stats", unmount = function() error("the tab on screen was dropped") end } }
  stack[#stack + 1] = visible.shell
  m:screens():track("stats", visible)
  m:shelfChanged(6, READING, FINISHED, 106, true)
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

check("a book with no saved row still shows on its shelf, with the title from its file", function()
  local m = newManager()
  m:shelfChanged(77, nil, 2, nil, true, { title = "From The File" })
  local entries = m.shelf_store:entries(1, 2)
  local found
  for _, e in ipairs(entries) do if e.book_id == 77 then found = e end end
  assert(found and found.title == "From The File", "the book is missing from the shelf's list")
end)

check("a saved row is not overwritten by the title from the file", function()
  local m = newManager()
  m:shelfChanged(6, 3, 2, 106, true, { title = "file name" })
  local found
  for _, e in ipairs(m.shelf_store:entries(1, 2)) do if e.book_id == 6 then found = e end end
  assert(found and found.title == "Six")
end)

check("cancelling a reader-made change puts the book and the counts back", function()
  local m = newManager()
  m:shelfChanged(6, 3, 2, 106, true, { title = "Six" })
  assert(m.shelf_store:member(1, 6).status_id == 2)
  m:pendingUndone { kind = "page", shelf_op = { kind = "status", book_id = 6, user_book_id = 106,
    status_id = 2, from_status_id = 3, known = true } }
  assert(m.shelf_store:member(1, 6).status_id == 3, "still on Currently Reading")
  for _, e in ipairs(m.shelf_store:entries(1, 2)) do assert(e.book_id ~= 6, "still listed") end
end)

check("cancelling a change for a book that was on no shelf takes it off the shelf", function()
  local m = newManager()
  m:shelfChanged(77, nil, 2, nil, true, { title = "New" })
  m:pendingUndone { kind = "status", shelf_op = { kind = "status", book_id = 77, status_id = 2, known = true } }
  assert(m.shelf_store:member(1, 77) == nil)
end)

check("a change queued before the origin was recorded is left alone", function()
  local m = newManager()
  m:shelfChanged(6, 3, 2, 106, true)
  m:pendingUndone { kind = "status", shelf_op = { kind = "status", book_id = 6, status_id = 2, known = false } }
  assert(m.shelf_store:member(1, 6).status_id == 2)
end)

print("\n== a tab that fails to load ==")

check("as a tab of the shell, cancelling a failed load says so instead of loading for good", function()
  local m = newManager()
  local shell = {}
  stack[#stack + 1] = shell
  local messages = {}
  local goals_class = real_require("hardcover/lib/ui/goals_dialog")
  local fake_new = goals_class.new
  goals_class.new = function(_, o)
    o = o or {}
    o.setMessage = function(_, text) messages[#messages + 1] = text end
    o.free = function() end
    return o
  end
  local cancel
  Api.getGoalsAsync = function(_, cb) cb(nil, { message = "boom" }) end
  StatusDialogs.retry = function(_err, _what, _retry, on_cancel) cancel = on_cancel end
  m:showGoals({ shell = shell, width = 100, height = 100, id = "goals" })
  goals_class.new = fake_new
  assert(cancel, "a failed load did not ask to retry")
  cancel()
  assert(#messages == 1 and messages[1]:find("load your goals", 1, true), "the tab says " .. table.concat(messages, "|"))
end)

check("on its own, cancelling a failed load closes the screen", function()
  local m = newManager()
  local dialog = { setMessage = function() error("no message on a screen that closes") end }
  stack[#stack + 1] = dialog
  m:loadFailed(dialog, nil, "x")()
  assert(not UIManagerShown(dialog), "the screen is still open")
end)

print("\n== Home's Sync now ==")

check("Sync now sends what is waiting; the box opens the list", function()
  local m = newManager()
  local sent, listed = 0, 0
  m.send_now = function() sent = sent + 1 end
  m.show_pending = function() listed = listed + 1 end
  m:syncNow()
  assert(sent == 1 and listed == 0, "Sync now sent " .. sent .. " times, opened the list " .. listed)
  m:showPendingChanges()
  assert(sent == 1 and listed == 1, "the box opened the list " .. listed .. " times")
end)

print("\n== no goals ==")

check("saved and fresh goals say the same thing when there are none", function()
  local m = newManager()
  local goals_class = real_require("hardcover/lib/ui/goals_dialog")
  assert(type(goals_class.NO_GOALS) == "string" and goals_class.NO_GOALS:find("+", 1, true), "the text points at the + button")
  local fake_new, made = goals_class.new, nil
  goals_class.new = function(_, o) o.free = function() end; made = o; return o end
  m.shelf_cache:putGoals(User:getId(), {})
  online = false
  m:showGoals()
  goals_class.new = fake_new
  assert(made and made.message == goals_class.NO_GOALS, "the saved empty list says " .. tostring(made and made.message))
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
  m:showHomeBody(homeHost())
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
  m.shelf_cache:putStats(1, { rows = { { title = "x" } }, history = {}, genres = {} }, FP[3])
  m:showStats()
  assert(named("getStats") == 0 and named("getShelfCounts") == 0, "asked: " .. #calls)
end)

check("legacy or incomplete Stats refreshes once, even with an unchanged Read shelf", function()
  for _, saved in ipairs({ { rows = {}, genres = {} }, { rows = {}, history = {}, complete = false } }) do
    local m = newManager()
    m.shelf_cache:putStats(1, saved, FP[3])
    m:showStats()
    assert(named("getStats") == 1 and m.shelf_cache:stats(1).history, "partial rows were trusted as full history")
    m:showStats()
    assert(named("getStats") == 1, "repeated the upgrade")
  end
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
  m.shelf_cache:putStats(1, { rows = {}, history = {}, genres = {} }, FP[3])
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

print("\n== vibe paging past unavailable books ==")

-- Keep the real API normalizer and shelf paging; replace only network and widget construction.
local ShelfDialog = real_require("hardcover/lib/ui/shelf_dialog")
local fake_shelf_new = ShelfDialog.new
ShelfDialog.new = function(self, opts)
  local dialog = fake_shelf_new(self, opts)
  dialog.setEntries = ShelfDialog.setEntries
  dialog.per_page = 10
  return dialog
end
Api.getBooksByIds = dofile(PLUGIN .. "/hardcover/lib/hardcover_api.lua").getBooksByIds

for _, case in ipairs({
  { name = "a missing book does not duplicate the next page", first = 21, last = 21 },
  { name = "an unavailable middle page does not hide later books", first = 21, last = 40 },
  { name = "an unavailable first page does not hide later books", first = 1, last = 40 },
  { name = "an unavailable final page ends the list", first = 41, last = 65 },
  { name = "a vibe with no available books shows its empty state", first = 1, last = 65 },
}) do
  check(case.name, function()
    local manager = newManager()
    local ids, expected = {}, {}
    for id = 1, 65 do
      ids[#ids + 1] = id
      if id < case.first or id > case.last then expected[#expected + 1] = id end
    end
    Api.query = function(_, _, vars)
      local books = {}
      for _, id in ipairs(vars.ids) do
        if id < case.first or id > case.last then
          books[#books + 1] = { book_id = id, title = "Book " .. id }
        end
      end
      return { books = books }
    end
    manager:showVibe({ title = "Vibe", ids = ids })
    local dialog = shown.shelf
    for _ = 1, 10 do
      if not dialog.has_more then break end
      ShelfDialog.loadMore(dialog)
    end
    assert(not dialog.has_more, "paging did not finish")
    assert(#dialog.entries == #expected, "expected " .. #expected .. " books, got " .. #dialog.entries)
    for i, id in ipairs(expected) do
      assert(dialog.entries[i].book_id == id, "wrong book at rank " .. i)
    end
    if #expected == 0 then assert(dialog.empty, "no empty state") end
  end)
end

print("\n== abandon reread through the real flow ==")

local function flowSettings()
  local store = {}
  return { readSetting = function(_, key) return store[key] end,
    saveSetting = function(_, key, value) store[key] = value end,
    flush = function() end,
    readBookSetting = function(_, _, key)
      return ({ book_id = 7, edition_id = 7, title = "Example" })[key]
    end,
    saveBookSnapshot = function() end,
    getLinkedBookId = function() return 7 end,
    getLinkedTitle = function() return "Example" end }
end

local function abandonFlow()
  local m = newManager()
  local q = SyncQueue:new { settings = flowSettings() }
  m.sync_queue, m.deviceFile, m.shelfChanged = q, function() return "/b/7.epub" end, function() end
  m.cache = { saveSnapshot = function() end }
  m.state = { book_status = {} }
  return m, q
end

local function clone(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = clone(item) end
  return out
end

check("the real flow stores the predecessor id and deletes only the reread", function()
  local m, q = abandonFlow()
  local old = { id = 10, started_at = "2020-01-01", finished_at = "2020-01-10",
    finished_at_precision = 1, edition_id = 7 }
  local active = { id = 11, started_at = "2026-11-01", edition_id = 7 }
  local record = { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.READING,
    user_book_reads = { clone(old), clone(active) } }
  local calls = {}
  local find, del, status = Api.findUserBook, Api.deleteRead, Api.updateUserBookStatus
  Api.findUserBook = function() return clone(record) end
  Api.deleteRead = function(_, id)
    calls[#calls + 1] = { op = "delete", id = id }
    for index = #record.user_book_reads, 1, -1 do
      if record.user_book_reads[index].id == id then table.remove(record.user_book_reads, index) end
    end
    return { id = id }
  end
  Api.updateUserBookStatus = function(_, id, status_id)
    calls[#calls + 1] = { op = "status", id = id, status_id = status_id }
    record.status_id = status_id
    return clone(record)
  end
  Api.findUserBooks = nil
  m:abandonReread({ book_id = 7, user_book_id = 507, status_id = HARDCOVER.STATUS.READING,
    reads = { old, active } }, nil, active)
  local action = q:readActions(7)[1]
  assert(action and action.previous_read and action.previous_read.id == 10,
    "the flow lost the predecessor id")
  assert(q:flush(Api, { user_id = 1 }) == true)
  assert(calls[1].op == "delete" and calls[1].id == 11, "the reread was not deleted")
  assert(calls[2].op == "status" and calls[2].status_id == HARDCOVER.STATUS.FINISHED)
  assert(#record.user_book_reads == 1 and record.user_book_reads[1].id == 10)
  Api.findUserBook, Api.deleteRead, Api.updateUserBookStatus = find, del, status
end)

check("a pre-sync flow abandon clears the reader's synthetic Reading state", function()
  local m, q = abandonFlow()
  local old = { id = 10, started_at = "2020-01-01", finished_at = "2020-01-10",
    finished_at_precision = 1, edition_id = 7 }
  q:startReread("/b/7.epub", { book_id = 7, user_id = 1, user_book_id = 507,
    from_status_id = HARDCOVER.STATUS.FINISHED, mapped_page = 12 })
  m.state.book_status = { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.READING,
    user_book_reads = { { started_at = "2026-11-16", progress_pages = 12, edition_id = 7 } } }
  local confirm = StatusDialogs.confirm
  StatusDialogs.confirm = function(options) options.ok_callback() end
  m:abandonReread({ book_id = 7, reads = { old } }, nil, q:pendingReread(7, { old }))
  StatusDialogs.confirm = confirm
  assert(not q:hasPending(7))
  assert(m.state.book_status.status_id == HARDCOVER.STATUS.FINISHED)
  assert(#m.state.book_status.user_book_reads == 1
    and m.state.book_status.user_book_reads[1].id == 10)
  local BookActions = real_require("hardcover/lib/book_actions")
  assert(BookActions.pageWrite(m.state.book_status.status_id) == "block",
    "tracking can still create a read after the abandon")
end)

check("the reader-panel offline history exposes the pending reread", function()
  local m, q = abandonFlow()
  local old = { id = 10, started_at = "2020-01-01", finished_at = "2020-01-10",
    finished_at_precision = 1, edition_id = 7 }
  q:startReread("/b/7.epub", { book_id = 7, user_id = 1, user_book_id = 507,
    from_status_id = HARDCOVER.STATUS.FINISHED, mapped_page = 12 })
  m.state.book_status = { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.READING,
    user_book_reads = { { started_at = "2026-11-16", progress_pages = 12 } } }
  m.read_store = { get = function() return { reads = { old } } end }
  m.settings.getLinkedBookId = function() return 7 end
  m.settings.getLinkedTitle = function() return "Example" end
  local context
  m.openReadHistoryWhenAvailable = function(_, c) context = c end
  m:showLinkedReadHistory()
  local reads = m:readHistoryProjection(context)
  assert(#reads == 2, "the saved read and pending reread were not both shown")
  assert(reads[1].id == 10 and reads[2].pending_reread)
  local Edit = real_require("hardcover/lib/ui/read_edit_dialog")
  local original, form = Edit.new, nil
  Edit.new = function(_, options) form = options; return options end
  m:editRead(context, nil, reads[2])
  Edit.new = original
  assert(form and form.on_abandon, "the pending reread offered no Abandon action")
end)

check("a DNF predecessor offers Abandon and restores its shelf", function()
  local m, q = abandonFlow()
  local old = { id = 10, started_at = "2020-01-01", edition_id = 7 }
  local active = { id = 11, started_at = "2026-11-01", edition_id = 7 }
  local historic = { id = 9, started_at = "2018-01-01", finished_at = "2018-01-10" }
  local Edit = real_require("hardcover/lib/ui/read_edit_dialog")
  local original, form = Edit.new, nil
  Edit.new = function(_, options) form = options; return options end
  m:editRead({ book_id = 7, user_book_id = 507, status_id = HARDCOVER.STATUS.READING,
    reads = { historic, old, active } }, nil, active)
  Edit.new = original
  assert(form and form.on_abandon, "a DNF predecessor offered no Abandon action")
  form.on_abandon()
  local action = q:readActions(7)[1]
  assert(action.previous_read.id == 10 and action.restore_status_id == HARDCOVER.STATUS.DNF,
    "an older finished read was mistaken for the DNF predecessor")
end)

check("an undated reread still offers Abandon", function()
  local m = abandonFlow()
  local old = { id = 10, started_at = "2020-01-01", finished_at = "2020-01-10" }
  local active = { id = 11, edition_id = 7 }
  local Edit = real_require("hardcover/lib/ui/read_edit_dialog")
  local original, form = Edit.new, nil
  Edit.new = function(_, options) form = options; return options end
  m:editRead({ book_id = 7, user_book_id = 507, status_id = HARDCOVER.STATUS.READING,
    reads = { old, active } }, nil, active)
  Edit.new = original
  assert(form and form.on_abandon, "an undated reread offered no Abandon action")
end)

check("an older DNF row does not offer Abandon", function()
  local m = abandonFlow()
  local old = { id = 10, started_at = "2020-01-01", edition_id = 7 }
  local active = { id = 11, started_at = "2026-11-01", edition_id = 7 }
  local historic = { id = 9, started_at = "2018-01-01", finished_at = "2018-01-10" }
  local Edit = real_require("hardcover/lib/ui/read_edit_dialog")
  local original, form = Edit.new, nil
  Edit.new = function(_, options) form = options; return options end
  m:editRead({ book_id = 7, user_book_id = 507, status_id = HARDCOVER.STATUS.READING,
    reads = { historic, old, active } }, nil, old)
  Edit.new = original
  assert(form and not form.on_abandon, "an older DNF row offered Abandon")
end)

check("a DNF book offers no Abandon", function()
  local m = abandonFlow()
  local dnf = { id = 10, started_at = "2020-01-01", edition_id = 7 }
  local historic = { id = 9, started_at = "2018-01-01", finished_at = "2018-01-10" }
  local Edit = real_require("hardcover/lib/ui/read_edit_dialog")
  local original, form = Edit.new, nil
  Edit.new = function(_, options) form = options; return options end
  m:editRead({ book_id = 7, user_book_id = 507, status_id = HARDCOVER.STATUS.DNF,
    reads = { historic, dnf } }, nil, dnf)
  Edit.new = original
  assert(form and not form.on_abandon, "a DNF book offered Abandon")
end)

check("a projected DNF row offers Abandon by stable identity", function()
  local m, q = abandonFlow()
  local old = { id = 10, started_at = "2020-01-01", edition_id = 7 }
  local active = { id = 11, started_at = "2026-11-01", edition_id = 7 }
  local context = { book_id = 7, user_book_id = 507, status_id = HARDCOVER.STATUS.READING,
    reads = { old, active } }
  local rows = m:readHistoryProjection(context)
  local selected
  for _, row in ipairs(rows) do if row.id == 11 then selected = row end end
  assert(selected and selected ~= active)
  local Edit = real_require("hardcover/lib/ui/read_edit_dialog")
  local original, form = Edit.new, nil
  Edit.new = function(_, options) form = options; return options end
  m:editRead(context, nil, selected)
  Edit.new = original
  assert(form and form.on_abandon, "the projected reread was counted as its own predecessor")
end)

check("fresh state wins over stale saved fields for the same read", function()
  local m = abandonFlow()
  local old = { id = 10, started_at = "2020-01-01", finished_at = "2020-01-10" }
  local saved_active = { id = 11, started_at = "2026-11-01", progress_pages = 12 }
  local fresh_active = { id = 11, started_at = "2026-11-01", progress_pages = 50 }
  m.read_store = { get = function() return { reads = { old, saved_active } } end }
  m.settings.getLinkedBookId = function() return 7 end
  m.settings.getLinkedTitle = function() return "Example" end
  m.state.book_status = { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.READING,
    user_book_reads = { old, fresh_active } }
  local context
  m.openReadHistoryWhenAvailable = function(_, c) context = c end
  m:showLinkedReadHistory()
  assert(context.reads[2].progress_pages == 50, "stale saved fields won")
end)

check("a partial reader snapshot keeps saved earlier reads", function()
  local m = abandonFlow()
  local old = { id = 10, started_at = "2020-01-01", finished_at = "2020-01-10" }
  local active = { id = 11, started_at = "2026-11-01" }
  m.read_store = { get = function() return { reads = { old, active } } end }
  m.settings.getLinkedBookId = function() return 7 end
  m.settings.getLinkedTitle = function() return "Example" end
  m.state.book_status = { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.READING,
    reads_complete = false, user_book_reads = { active } }
  local context
  m.openReadHistoryWhenAvailable = function(_, c) context = c end
  m:showLinkedReadHistory()
  assert(#context.reads == 2 and context.reads[1].id == 10 and context.reads[2].id == 11,
    "a partial reader snapshot hid the earlier read")
end)

check("a finish-only predecessor restores Finished, not an older DNF", function()
  local m, q = abandonFlow()
  local dnf = { id = 10, started_at = "2020-01-01" }
  local finish_only = { id = 11, finished_at = "2024-06-10" }
  local active = { id = 12, started_at = "2026-11-01" }
  local Edit = real_require("hardcover/lib/ui/read_edit_dialog")
  local original, form = Edit.new, nil
  Edit.new = function(_, options) form = options; return options end
  m:editRead({ book_id = 7, user_book_id = 507, status_id = HARDCOVER.STATUS.READING,
    reads = { dnf, finish_only, active } }, nil, active)
  Edit.new = original
  assert(form and form.on_abandon, "the finish-only predecessor lost Abandon")
  form.on_abandon()
  local action = q:readActions(7)[1]
  assert(action.previous_read.id == 11 and action.restore_status_id == HARDCOVER.STATUS.FINISHED,
    "the older DNF was selected instead of the finish-only read")
end)

check("an undated DNF predecessor restores Did Not Finish", function()
  local m, q = abandonFlow()
  local finished = { id = 10, started_at = "2020-01-01", finished_at = "2020-01-10" }
  local dnf = { id = 11 }
  local active = { id = 12, started_at = "2026-11-01" }
  local Edit = real_require("hardcover/lib/ui/read_edit_dialog")
  local original, form = Edit.new, nil
  Edit.new = function(_, options) form = options; return options end
  m:editRead({ book_id = 7, user_book_id = 507, status_id = HARDCOVER.STATUS.READING,
    reads = { finished, dnf, active } }, nil, active)
  Edit.new = original
  assert(form and form.on_abandon, "the undated DNF predecessor lost Abandon")
  form.on_abandon()
  local action = q:readActions(7)[1]
  assert(action.previous_read.id == 11 and action.restore_status_id == HARDCOVER.STATUS.DNF,
    "the undated DNF predecessor was not selected")
end)

check("a backfilled read does not become the reread predecessor", function()
  local m, q = abandonFlow()
  local june = { id = 10, started_at = "2024-06-01", finished_at = "2024-06-10" }
  local active = { id = 12, started_at = "2026-11-01" }
  local backfill = { id = 13, started_at = "2020-01-01", finished_at = "2020-01-10" }
  local Edit = real_require("hardcover/lib/ui/read_edit_dialog")
  local original, form = Edit.new, nil
  Edit.new = function(_, options) form = options; return options end
  m:editRead({ book_id = 7, user_book_id = 507, status_id = HARDCOVER.STATUS.READING,
    reads = { june, active, backfill } }, nil, active)
  Edit.new = original
  assert(form and form.on_abandon, "the reread lost Abandon after a backfill")
  form.on_abandon()
  local action = q:readActions(7)[1]
  assert(action.previous_read.id == 10 and action.restore_status_id == HARDCOVER.STATUS.FINISHED,
    "the backfilled read was mistaken for the predecessor")
end)

check("a backfilled read after the reread does not hide Abandon", function()
  local m = abandonFlow()
  local june = { id = 10, started_at = "2024-06-01", finished_at = "2024-06-10" }
  local backfill = { id = 11, started_at = "2020-01-01", finished_at = "2020-01-10" }
  local active = { id = 12, started_at = "2026-11-01" }
  local Edit = real_require("hardcover/lib/ui/read_edit_dialog")
  local original, form = Edit.new, nil
  Edit.new = function(_, options) form = options; return options end
  m:editRead({ book_id = 7, user_book_id = 507, status_id = HARDCOVER.STATUS.READING,
    reads = { june, backfill, active } }, nil, active)
  Edit.new = original
  assert(form and form.on_abandon, "the later backfill hid the active reread")
end)

check("an offline snapshot keeps the saved finish date", function()
  local m = abandonFlow()
  local saved = { id = 11, started_at = "2024-03-01", finished_at = "2024-03-10",
    finished_at_precision = 1, edition_id = 7 }
  local snapshot = { id = 11, started_at = "2024-03-01", edition_id = 7 }
  m.read_store = { get = function() return { reads = { saved } } end }
  m.settings.getLinkedBookId = function() return 7 end
  m.settings.getLinkedTitle = function() return "Example" end
  m.state.book_status = { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.FINISHED,
    reads_complete = false, reads_snapshot = true, user_book_reads = { snapshot } }
  local context
  m.openReadHistoryWhenAvailable = function(_, c) context = c end
  m:showLinkedReadHistory()
  assert(context.reads[1].finished_at == "2024-03-10",
    "the offline snapshot dropped the saved finish date")
end)

check("an offline snapshot does not attach another edition's details", function()
  local m = abandonFlow()
  local saved = { id = 11, started_at = "2024-03-01", edition_id = 7,
    edition = { id = 7, pages = 200, edition_format = "Paperback" } }
  local snapshot = { id = 11, started_at = "2024-03-01", edition_id = 8 }
  m.read_store = { get = function() return { reads = { saved } } end }
  m.settings.getLinkedBookId = function() return 7 end
  m.settings.getLinkedTitle = function() return "Example" end
  m.state.book_status = { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.READING,
    reads_complete = false, reads_snapshot = true, user_book_reads = { snapshot } }
  local context
  m.openReadHistoryWhenAvailable = function(_, c) context = c end
  m:showLinkedReadHistory()
  assert(context.reads[1].edition == nil, "the old edition was attached to the new one")
end)

check("a cleared start date is not filled from saved history", function()
  local m = abandonFlow()
  local saved = { id = 11, started_at = "2026-11-01", edition_id = 7 }
  local fresh = { id = 11, started_at = nil, edition_id = 7 }
  m.read_store = { get = function() return { reads = { saved } } end }
  m.settings.getLinkedBookId = function() return 7 end
  m.settings.getLinkedTitle = function() return "Example" end
  m.state.book_status = { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.READING,
    user_book_reads = { fresh } }
  local context
  m.openReadHistoryWhenAvailable = function(_, c) context = c end
  m:showLinkedReadHistory()
  assert(context.reads[1].started_at == nil, "the saved start date came back")
end)

check("a newer reader history does not bring back a deleted read", function()
  local m = abandonFlow()
  local old = { id = 10, started_at = "2020-01-01", finished_at = "2020-01-10" }
  local gone = { id = 12, started_at = "2026-11-01", finished_at = "2026-11-02" }
  m.read_store = { get = function() return { reads = { old, gone } } end }
  m.settings.getLinkedBookId = function() return 7 end
  m.settings.getLinkedTitle = function() return "Example" end
  m.state.book_status = { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.FINISHED,
    user_book_reads = { old } }
  local context
  m.openReadHistoryWhenAvailable = function(_, c) context = c end
  m:showLinkedReadHistory()
  assert(#context.reads == 1 and context.reads[1].id == 10,
    "the saved copy brought back a deleted read")
end)

check("success updates the saved shelf without an open details screen", function()
  local m = abandonFlow()
  local moved
  m.shelfChanged = function(_, book_id, old, new, id) moved = { book_id, old, new, id } end
  m.screens = function() return { open = function() return nil end } end
  local old = { id = 10, started_at = "2020-01-01", finished_at = "2020-01-10" }
  m:readSent(7, { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.FINISHED,
    user_book_reads = { old } }, { kind = "abandon_reread" })
  assert(moved and moved[3] == HARDCOVER.STATUS.FINISHED,
    "shelf transition was skipped with details closed")
end)

check("the success callback moves the details and shelf off Reading", function()
  local m = abandonFlow()
  local shelf_call
  m.shelfChanged = function(_, book_id, old, new, id) shelf_call = { book_id, old, new, id } end
  local old = { id = 10, started_at = "2020-01-01", finished_at = "2020-01-10" }
  local screen = { detail = { book = { book_id = 7 }, status_id = HARDCOVER.STATUS.READING,
    reads = { old, { id = 11, started_at = "2026-11-01" } } }, refreshState = function() end }
  m.screens = function() return { open = function(_, name) if name == "book" then return screen end end } end
  m:readSent(7, { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.FINISHED,
    user_book_reads = { old } }, { kind = "abandon_reread" })
  assert(#screen.detail.reads == 1 and screen.detail.status_id == HARDCOVER.STATUS.FINISHED)
  assert(shelf_call and shelf_call[3] == HARDCOVER.STATUS.FINISHED)
end)

r.finish()
