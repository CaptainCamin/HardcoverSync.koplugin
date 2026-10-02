-- Shelves and book details with and without a connection.
--
-- Drives DialogManager:showShelf, its page fetcher and showBookDetail against a
-- real shelf cache, a switchable network and fake dialog classes, and checks
-- what the reader would see: a saved list immediately, a refresh behind it, an
-- honest message when there is nothing saved, and no readable text ever
-- replaced by "table: 0x...".
--
-- Run with:  lua spec/offline_shelf_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function make()
  local t = {}
  return setmetatable(t, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end

local online = true
local stack, ticks = {}, {}
package.preload["ui/uimanager"] = function()
  return {
    show = function(_, w) stack[#stack + 1] = w end,
    close = function(_, w) for i = #stack, 1, -1 do if stack[i] == w then table.remove(stack, i) end end end,
    isWidgetShown = function(_, w) for _, x in ipairs(stack) do if x == w then return true end end return false end,
    setDirty = function() end, scheduleIn = function() end, unschedule = function() end,
    forceRePaint = function() end,
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
  }
end
package.preload["ui/trapper"] = function()
  return {
    wrap = function(_, fn)
      local co = coroutine.create(fn)
      local ok, err = coroutine.resume(co)
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

local UIManager_close = function(w) require("ui/uimanager"):close(w) end
local Api = real_require("hardcover/lib/hardcover_api")
local User = real_require("hardcover/lib/user")
local StatusDialogs = real_require("hardcover/lib/ui/status_dialogs")
local ShelfCache = real_require("hardcover/lib/shelf_cache")
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
User.getId = function() return 1 end

-- ------------------------------------------------------------ recorders
local api_calls, pending_shelf, pending_detail
local shelf_pages -- queue of results for Api.getShelf: { entries } or { nil, err }
local seen_in_coroutine
Api.getShelf = function(_, _, _, offset, limit)
  api_calls[#api_calls + 1] = "shelf@" .. offset
  if not coroutine.running() then seen_in_coroutine = false end
  local nextpage = table.remove(shelf_pages, 1)
  if nextpage == nil then return {}, nil, false end
  return nextpage[1], nextpage[2], false
end
local series_results, series_calls
Api.getSeriesBooks = function(_, series_id)
  series_calls = series_calls + 1
  if not coroutine.running() then seen_in_coroutine = false end
  local nextresult = table.remove(series_results, 1)
  if nextresult == nil then return nil, { completed = false } end
  return nextresult
end
local count_results, count_calls
Api.getShelfCounts = function()
  count_calls = count_calls + 1
  if not coroutine.running() then seen_in_coroutine = false end
  local nextresult = table.remove(count_results, 1)
  if nextresult == nil then return nil, { completed = false } end
  return nextresult
end
Api.getShelfAsync = function(_, _, _, offset, _, cb) api_calls[#api_calls + 1] = "async@" .. offset; pending_shelf = cb end
Api.getBookDetailAsync = function(_, _, _, _, cb) api_calls[#api_calls + 1] = "detail"; pending_detail = cb end

local infos, retries, loadings
StatusDialogs.info = function(text) infos[#infos + 1] = text end
StatusDialogs.loading = function() loadings = loadings + 1; return { __loading = true } end
StatusDialogs.close = function() end
StatusDialogs.retry = function(err, op) retries[#retries + 1] = { err = err, op = op } end

local fake = {}
local function fakeClass(path)
  local class = real_require(path)
  class.new = function(_, o)
    o = o or {}
    o.updates = 0
    o.setEntries = function(self, entries, has_more, keep)
      self.shown = entries; self.shown_more = has_more; self.kept_position = keep
      self.updates = self.updates + 1
    end
    o.setEmptyState = function(self, m) self.empty = m end
    o.setDetail = function(self, d) self.detail = d end
    o.setSeries = function(self, card, on_open) self.series = card; self.on_open_book = on_open end
    o.setRows = function(self, rows) self.rows = rows; self.row_updates = (self.row_updates or 0) + 1 end
    o.free = function() end
    fake[#fake + 1] = o
    return o
  end
end
fakeClass("hardcover/lib/ui/shelf_dialog")
fakeClass("hardcover/lib/ui/book_detail_dialog")
fakeClass("hardcover/lib/ui/home_dialog")

local store_data
local function newManager()
  store_data = {}
  local store = {
    readSetting = function(_, k) return store_data[k] end,
    saveSetting = function(_, k, v) store_data[k] = v end,
    flush = function() end,
  }
  api_calls, pending_shelf, pending_detail = {}, nil, nil
  shelf_pages, seen_in_coroutine = {}, true
  count_results, count_calls = {}, 0
  series_results, series_calls = {}, 0
  infos, retries, loadings = {}, {}, 0
  stack, ticks, fake = {}, {}, {}
  return setmetatable({
    settings = { compatibilityMode = function() return false end },
    shelf_cache = ShelfCache:new { path = "/x", open = function() return store end },
  }, { __index = DialogManager })
end

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end
local function book(id, title) return { book_id = id, title = title, status_id = 1, description = "d" } end

local function page(n, from)
  local rows = {}
  for i = 1, n do rows[i] = { user_book_id = from + i, book_id = from + i, title = "B" .. (from + i), status_id = 1 } end
  return { rows }
end

print("\n== loading the whole shelf ==")

check("every page is loaded, in the background, until one comes back empty", function()
  online = true
  local m = newManager()
  shelf_pages = { page(50, 0), page(50, 50), page(10, 100), { {} } }
  m:showShelf(1, "Want to Read")
  local d = fake[1]
  assert(#d.shown == 110, "showed " .. #d.shown .. " of 110")
  assert(d.shown_more == false, "a finished list still offers 'load more'")
  assert(seen_in_coroutine, "a page was requested on the main thread (it would freeze the UI)")
  assert(#api_calls == 4, "requests: " .. table.concat(api_calls, ","))
end)

check("the complete list is saved", function()
  online = true
  local m = newManager()
  shelf_pages = { page(50, 0), page(5, 50), { {} } }
  m:showShelf(1, "Want to Read")
  local saved = m.shelf_cache:get(1, 1)
  assert(saved and #saved.entries == 55 and saved.complete == true)
end)

check("with nothing saved, rows appear as pages arrive and keep the reader's page", function()
  online = true
  local m = newManager()
  shelf_pages = { page(50, 0), page(50, 50), { {} } }
  m:showShelf(1, "Want to Read")
  local d = fake[1]
  assert(d.updates >= 3, "no progressive updates: " .. d.updates)
  assert(d.kept_position == true, "the list jumped back to page one")
  assert(loadings == 1, "should show a loading message until the first page")
end)

check("a server that returns fewer rows than asked for still yields everything", function()
  online = true
  local m = newManager()
  shelf_pages = { page(25, 0), page(25, 25), page(25, 50), { {} } }
  m:showShelf(1, "Want to Read")
  assert(#fake[1].shown == 75, "stopped early at " .. #fake[1].shown)
end)

check("a book that shifts into two pages is shown once", function()
  online = true
  local m = newManager()
  local overlap = { { { user_book_id = 50, book_id = 50, title = "dup" }, { user_book_id = 51, book_id = 51, title = "new" } } }
  shelf_pages = { page(50, 0), overlap, { {} } }
  m:showShelf(1, "Want to Read")
  assert(#fake[1].shown == 51, "rows: " .. #fake[1].shown)
end)

check("an empty shelf is still said to be empty", function()
  online = true
  local m = newManager()
  shelf_pages = { { {} } }
  m:showShelf(1, "Want to Read")
  assert(fake[1].empty, "no empty state")
end)

print("\n== a tap that cancels a page ==")

check("a cancelled page is asked for again", function()
  online = true
  local m = newManager()
  shelf_pages = { page(50, 0), { nil, { completed = false } }, page(50, 50), { {} } }
  m:showShelf(1, "Want to Read")
  assert(#fake[1].shown == 100, "gave up after one cancelled page: " .. #fake[1].shown)
end)

check("after repeated cancels it stops, keeps what arrived and offers to continue", function()
  online = true
  local m = newManager()
  local c = { nil, { completed = false } }
  shelf_pages = { page(50, 0), c, c, c, c, c }
  m:showShelf(1, "Want to Read")
  local d = fake[1]
  assert(#d.shown == 50 and d.shown_more == true, "partial list / reload icon not kept")
  assert(m.shelf_cache:get(1, 1).complete == false, "a partial list was saved as complete")
  assert(#retries == 0, "interrupted a list that has rows")
end)

check("a real failure with nothing saved offers a readable retry", function()
  online = true
  local m = newManager()
  shelf_pages = { { nil, { status = 500 } } }
  m:showShelf(1, "Want to Read")
  assert(#retries == 1, "no retry offered")
  assert(not StatusDialogs.describe(retries[1].err):find("table:"))
end)

print("\n== with a saved list ==")

check("the whole saved list is on screen before the network answers", function()
  online = true
  local m = newManager()
  local rows = page(120, 0)[1]
  m.shelf_cache:put(1, 1, rows, true)
  shelf_pages = {} -- the load would be empty; check the first paint
  local d
  -- capture what was shown first by pausing the load: make getShelf record the screen state
  local first_paint
  local real = Api.getShelf
  Api.getShelf = function(...)
    first_paint = first_paint or (fake[1] and fake[1].shown and #fake[1].shown)
    return real(...)
  end
  m:showShelf(1, "Want to Read")
  Api.getShelf = real
  assert(first_paint == 120, "first paint had " .. tostring(first_paint) .. " rows")
  assert(loadings == 0, "a saved list should not put up a loading message")
end)

check("the fresh list replaces it only once it is complete", function()
  online = true
  local m = newManager()
  m.shelf_cache:put(1, 1, page(120, 0)[1], true)
  shelf_pages = { page(50, 1000), page(50, 1050), { {} } }
  local sizes = {}
  m:showShelf(1, "Want to Read")
  local d = fake[1]
  assert(#d.shown == 100 and d.shown[1].title == "B1001", "refresh did not replace the list")
  assert(d.updates == 2, "the list was swapped mid-refresh (" .. d.updates .. " updates): it would shrink while loading")
  assert(#m.shelf_cache:get(1, 1).entries == 100, "refresh was not saved")
end)

check("a refresh that fails midway leaves the saved list alone", function()
  online = true
  local m = newManager()
  m.shelf_cache:put(1, 1, page(120, 0)[1], true)
  shelf_pages = { page(50, 1000), { nil, { status = 500 } } }
  m:showShelf(1, "Want to Read")
  assert(#fake[1].shown == 120, "the saved list was replaced by a partial one")
  assert(#m.shelf_cache:get(1, 1).entries == 120, "the saved list was overwritten")
  assert(#retries == 0, "interrupted for a failed refresh")
end)

print("\n== offline ==")

check("offline with a saved list: all of it, with the date, and no request", function()
  online = false
  local m = newManager()
  m.shelf_cache:put(1, 1, page(120, 0)[1], true)
  m:showShelf(1, "Want to Read")
  assert(#fake[1].shown == 120)
  assert(#api_calls == 0, "made a request while offline")
  assert(#infos == 1 and infos[1]:find("Offline"), "no offline notice")
  assert(#retries == 0)
end)

check("offline with nothing saved: a readable retry, no request", function()
  online = false
  local m = newManager()
  m:showShelf(1, "Want to Read")
  assert(#api_calls == 0)
  assert(#retries == 1 and type(retries[1].err) == "string", "error was not text")
end)

check("closing the shelf stops the loading", function()
  online = true
  local m = newManager()
  shelf_pages = { page(50, 0), page(50, 50), page(50, 100), { {} } }
  -- close the dialog as soon as the first request is made
  local real = Api.getShelf
  Api.getShelf = function(...)
    local r1, r2, r3 = real(...)
    if fake[1] then UIManager_close(fake[1]) end
    return r1, r2, r3
  end
  m:showShelf(1, "Want to Read")
  Api.getShelf = real
  assert(#api_calls == 1, "kept requesting after the dialog closed: " .. #api_calls)
end)

check("the reload icon continues from where a partial list stops", function()
  online = true
  local m = newManager()
  m:showShelf(1, "Want to Read")
  local got
  fake[1].fetch_page(50, 50, function(e) got = e end)
  assert(api_calls[#api_calls] == "async@50", "asked for " .. tostring(api_calls[#api_calls]))
  online = false
  local err
  fake[1].fetch_page(50, 50, function(_, e) err = e end)
  assert(type(err) == "string", "offline reload should say so")
end)

print("\n== the home screen ==")

local function rowFor(d, status_id)
  for _, row in ipairs(d.rows) do if row.status_id == status_id then return row end end
end

check("it opens at once with the counts that were saved", function()
  online = true
  local m = newManager()
  m.shelf_cache:putCounts(1, { [1] = 42, [2] = 3 })
  m:showHome()
  local d = fake[1]
  assert(d and d.rows, "no screen")
  assert(rowFor(d, 1).count == 42 and rowFor(d, 2).count == 3, "saved counts not shown")
end)

check("online, fresh counts replace them and are saved", function()
  online = true
  local m = newManager()
  m.shelf_cache:putCounts(1, { [1] = 42 })
  count_results = { { [1] = 45, [2] = 4, [3] = 130, [5] = 2 } }
  m:showHome()
  local d = fake[1]
  assert(seen_in_coroutine, "the request ran on the main thread (it would freeze the UI)")
  assert(rowFor(d, 1).count == 45 and rowFor(d, 3).count == 130, "counts were not refreshed")
  assert(m.shelf_cache:counts(1, { 1 })[1] == 45, "fresh counts were not saved")
end)

check("offline, it opens with the saved counts and makes no request", function()
  online = false
  local m = newManager()
  m.shelf_cache:putCounts(1, { [1] = 42 })
  m:showHome()
  assert(rowFor(fake[1], 1).count == 42)
  assert(count_calls == 0, "made a request while offline")
end)

check("offline with nothing saved, it still opens, with no counts", function()
  online = false
  local m = newManager()
  m:showHome()
  assert(fake[1] and #fake[1].rows == 4 and rowFor(fake[1], 1).count == nil)
end)

check("a shelf that was loaded in full gives its count offline", function()
  online = false
  local m = newManager()
  m.shelf_cache:put(1, 2, { { book_id = 1 }, { book_id = 2 }, { book_id = 3 } }, true)
  m:showHome()
  assert(rowFor(fake[1], 2).count == 3)
end)

check("a failed refresh leaves the saved counts on screen", function()
  online = true
  local m = newManager()
  m.shelf_cache:putCounts(1, { [1] = 42 })
  count_results = {} -- the stub answers a failure
  m:showHome()
  assert(rowFor(fake[1], 1).count == 42 and (fake[1].row_updates or 0) == 0, "the saved counts were replaced")
end)

check("choosing a shelf opens that shelf", function()
  online = true
  local m = newManager()
  m:showHome()
  fake[1].select_cb({ status_id = 2, title = "Currently Reading" })
  local shelf
  for _, d in ipairs(fake) do if d.status_id == 2 then shelf = d end end
  assert(shelf and shelf.title == "Currently Reading", "no shelf screen for that status")
end)

check("counts that arrive after the screen was closed are ignored", function()
  online = true
  local m = newManager()
  count_results = { { [1] = 99 } }
  local real = Api.getShelfCounts
  Api.getShelfCounts = function(...)
    UIManager_close(fake[1])
    return real(...)
  end
  m:showHome()
  Api.getShelfCounts = real
  assert((fake[1].row_updates or 0) == 0, "updated a screen that was closed")
end)

print("\n== book details ==")

local function savedBook(m)
  m.shelf_cache:put(1, 1, { {
    book_id = 7, title = "Seven", pages = 100, status_id = 2, description = "About seven",
  } }, true)
end

check("offline with a saved row: details are shown from it, no request", function()
  online = false
  local m = newManager()
  savedBook(m)
  m:showBookDetail(7)
  assert(#api_calls == 0, "made a request while offline")
  assert(fake[1].detail and fake[1].detail.book.title == "Seven", "no saved detail shown")
  assert(#infos == 1 and infos[1]:find("saved"), "no notice that these are saved details")
end)

check("offline with no saved row: a readable retry", function()
  online = false
  local m = newManager()
  m:showBookDetail(7)
  assert(#retries == 1 and type(retries[1].err) == "string")
end)

check("online but the request fails: the saved row is the fallback", function()
  online = true
  local m = newManager()
  savedBook(m)
  m:showBookDetail(7)
  pending_detail(nil)
  assert(fake[1].detail and fake[1].detail.book.title == "Seven")
  assert(#retries == 0)
end)

check("online and it works: the fresh record wins", function()
  online = true
  local m = newManager()
  savedBook(m)
  m:showBookDetail(7)
  pending_detail({ book = { title = "Fresh" } })
  assert(fake[1].detail.book.title == "Fresh")
end)

print("\n== the series card on book details ==")

local function inSeries(book_id)
  return { book = { book_id = book_id, title = "T", book_series = { { position = 2, series = { id = 12, name = "Hainish" } } } } }
end
local HAINISH = { name = "Hainish", is_completed = true, books = {
  { book_id = 7, title = "Seven", position = 2 }, { book_id = 8, title = "Eight", position = 3, status_id = 3 } } }

check("online, the rest of the series is fetched in the background and added", function()
  online = true
  local m = newManager()
  series_results = { HAINISH }
  m:showBookDetail(7)
  pending_detail(inSeries(7))
  assert(series_calls == 1, "series requests: " .. series_calls)
  assert(seen_in_coroutine, "the series request ran on the main thread (it would freeze the UI)")
  local d = fake[1]
  assert(d.series and d.series.title == "More in Hainish", "the card was not added")
  assert(#d.series.rows == 2 and d.series.rows[1].current == true)
end)

check("tapping a row opens that book's details on top", function()
  online = true
  local m = newManager()
  series_results = { HAINISH }
  m:showBookDetail(7)
  pending_detail(inSeries(7))
  fake[1].on_open_book(8)
  assert(#fake == 2, "no second details screen: " .. #fake)
  assert(api_calls[#api_calls] == "detail", "the sibling's details were not requested")
end)

check("offline, no series request is made and the screen is left alone", function()
  online = false
  local m = newManager()
  m.shelf_cache:put(1, 1, { { book_id = 7, title = "Seven", book_series = { { position = 2, series = { id = 12, name = "H" } } } } }, true)
  m:showBookDetail(7) -- shown from the saved row
  assert(series_calls == 0, "asked for a series while offline")
  assert(fake[1].series == nil)
end)

check("a book in no series asks for nothing", function()
  online = true
  local m = newManager()
  m:showBookDetail(7)
  pending_detail({ book = { book_id = 7, title = "T" } })
  assert(series_calls == 0, "asked for the series of a book that is in none")
end)

check("a failed series request leaves the screen as it is, without an error", function()
  online = true
  local m = newManager()
  series_results = {} -- the stub answers a failure
  m:showBookDetail(7)
  pending_detail(inSeries(7))
  assert(fake[1].series == nil and #retries == 0 and #infos == 0, "interrupted for a failed series request")
end)

check("a series of one book gets no card", function()
  online = true
  local m = newManager()
  series_results = { { name = "Solo", books = { { book_id = 7, title = "Seven", position = 1 } } } }
  m:showBookDetail(7)
  pending_detail(inSeries(7))
  assert(fake[1].series == nil)
end)

check("an answer that arrives after the screen was closed is ignored", function()
  online = true
  local m = newManager()
  series_results = { HAINISH }
  local real = Api.getSeriesBooks
  Api.getSeriesBooks = function(...)
    UIManager_close(fake[1])
    return real(...)
  end
  m:showBookDetail(7)
  pending_detail(inSeries(7))
  Api.getSeriesBooks = real
  assert(fake[1].series == nil, "updated a screen that was closed")
end)

r.finish()
