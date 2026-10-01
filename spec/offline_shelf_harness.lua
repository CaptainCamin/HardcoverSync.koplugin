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

local Api = real_require("hardcover/lib/hardcover_api")
local User = real_require("hardcover/lib/user")
local StatusDialogs = real_require("hardcover/lib/ui/status_dialogs")
local ShelfCache = real_require("hardcover/lib/shelf_cache")
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
User.getId = function() return 1 end

-- ------------------------------------------------------------ recorders
local api_calls, pending_shelf, pending_detail
Api.getShelfAsync = function(_, _, _, offset, _, cb) api_calls[#api_calls + 1] = "shelf@" .. offset; pending_shelf = cb end
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
    o.setEntries = function(self, entries, has_more) self.shown = entries; self.shown_more = has_more end
    o.setEmptyState = function(self, m) self.empty = m end
    o.setDetail = function(self, d) self.detail = d end
    o.free = function() end
    fake[#fake + 1] = o
    return o
  end
end
fakeClass("hardcover/lib/ui/shelf_dialog")
fakeClass("hardcover/lib/ui/book_detail_dialog")

local store_data
local function newManager()
  store_data = {}
  local store = {
    readSetting = function(_, k) return store_data[k] end,
    saveSetting = function(_, k, v) store_data[k] = v end,
    flush = function() end,
  }
  api_calls, pending_shelf, pending_detail = {}, nil, nil
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

print("\n== opening a shelf ==")

check("online with nothing saved: loading message, then the list, and it is saved", function()
  online = true
  local m = newManager()
  m:showShelf(1, "Want to Read")
  assert(loadings == 1 and #api_calls == 1, "should wait on the network")
  pending_shelf({ book(1, "One") }, nil, false)
  assert(fake[1].shown and #fake[1].shown == 1, "list not shown")
  assert(m.shelf_cache:getPage(1, 1, 0), "list was not saved")
end)

check("online with a saved list: shown at once, then refreshed quietly", function()
  online = true
  local m = newManager()
  m.shelf_cache:putPage(1, 1, 0, { book(1, "Old") }, false)
  m:showShelf(1, "Want to Read")
  assert(fake[1].shown and fake[1].shown[1].title == "Old", "saved list was not on screen before the network answered")
  assert(loadings == 0, "a saved list should not put up a loading message")
  assert(#api_calls == 1, "should still refresh")
  pending_shelf({ book(2, "New") }, nil, false)
  assert(fake[1].shown[1].title == "New", "refresh did not replace the list")
  assert(m.shelf_cache:getPage(1, 1, 0).entries[1].title == "New", "refresh was not saved")
end)

check("offline with a saved list: shows it, says so, makes no request", function()
  online = false
  local m = newManager()
  m.shelf_cache:putPage(1, 1, 0, { book(1, "Saved") }, false)
  m:showShelf(1, "Want to Read")
  assert(fake[1].shown[1].title == "Saved")
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

check("online refresh fails but a saved list is showing: it stays, no interruption", function()
  online = true
  local m = newManager()
  m.shelf_cache:putPage(1, 1, 0, { book(1, "Saved") }, false)
  m:showShelf(1, "Want to Read")
  pending_shelf(nil, { completed = false }, nil)
  assert(fake[1].shown[1].title == "Saved" and #retries == 0)
end)

check("online failure with nothing saved: a retry whose text is readable", function()
  online = true
  local m = newManager()
  m:showShelf(1, "Want to Read")
  pending_shelf(nil, { completed = false }, nil)
  assert(#retries == 1, "no retry offered")
  local text = StatusDialogs.describe(retries[1].err)
  assert(not text:find("table:"), "error table was printed: " .. text)
end)

check("an empty shelf is still said to be empty", function()
  online = true
  local m = newManager()
  m:showShelf(1, "Want to Read")
  pending_shelf({}, nil, false)
  assert(fake[1].empty, "no empty state")
end)

print("\n== paging ==")

check("a next page seen before is served offline", function()
  online = false
  local m = newManager()
  m.shelf_cache:putPage(1, 1, 0, { book(1, "A") }, true)
  m.shelf_cache:putPage(1, 1, 20, { book(2, "B") }, false)
  m:showShelf(1, "Want to Read")
  local got
  fake[1].fetch_page(20, 20, function(entries) got = entries end)
  assert(got and got[1].title == "B", "cached page not served")
  assert(#api_calls == 0)
end)

check("a next page never seen reports it plainly offline", function()
  online = false
  local m = newManager()
  m.shelf_cache:putPage(1, 1, 0, { book(1, "A") }, true)
  m:showShelf(1, "Want to Read")
  local entries, err
  fake[1].fetch_page(20, 20, function(e, er) entries, err = e, er end)
  assert(entries == nil and type(err) == "string")
end)

check("online, a fetched page is saved for next time", function()
  online = true
  local m = newManager()
  m:showShelf(1, "Want to Read")
  pending_shelf({ book(1, "A") }, nil, true)
  local got
  fake[1].fetch_page(20, 20, function(e) got = e end)
  pending_shelf({ book(2, "B") }, nil, false)
  assert(got and m.shelf_cache:getPage(1, 1, 20).entries[1].title == "B")
end)

print("\n== book details ==")

local function savedBook(m)
  m.shelf_cache:putPage(1, 1, 0, { {
    book_id = 7, title = "Seven", pages = 100, status_id = 2, description = "About seven",
  } }, false)
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

r.finish()
