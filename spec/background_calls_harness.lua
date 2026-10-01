-- Menu and dialog actions that talk to Hardcover must not block the UI.
--
-- They are reached from callbacks that run outside Trapper:wrap, where
-- HardcoverApi:query silently falls back to a blocking in-process request. Each
-- action below is driven the way a menu tap drives it -- from the main thread,
-- not a coroutine -- and every Hardcover call it makes records whether it ran
-- inside a coroutine, which is what lets the real query() fork and yield.
--
-- Run with:  lua spec/background_calls_harness.lua [plugin-root]

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

local ticks = {}
package.preload["ui/uimanager"] = function()
  return {
    show = function() end, setDirty = function() end, close = function() end,
    scheduleIn = function() end, unschedule = function() end, forceRePaint = function() end,
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
local HardcoverMenu = real_require("hardcover/lib/ui/hardcover_menu")
local Hardcover = real_require("hardcover/lib/hardcover")
local Background = real_require("hardcover/lib/background")

local blocking = {}
-- A stand-in for a Hardcover request: records the call and whether it could
-- have yielded (coroutine) or would have blocked (main thread).
local function probe(name, result)
  return function()
    if not coroutine.running() then blocking[#blocking + 1] = name end
    return result
  end
end

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local function reset() blocking = {}; ticks = {} end
local function pump() while #ticks > 0 do table.remove(ticks, 1)() end end
local function assertNoBlocking(what)
  assert(#blocking == 0, what .. " blocked the UI: " .. table.concat(blocking, ", "))
end

print("\n== the helper ==")

check("outside a coroutine, work runs in one (so requests can yield)", function()
  local inside
  Background.run(function() inside = coroutine.running() ~= nil end)
  assert(inside, "ran on the main thread")
end)

check("already in a coroutine, work runs inline rather than nesting", function()
  local order = {}
  Background.run(function()
    order[#order + 1] = "before"
    Background.run(function() order[#order + 1] = "inner" end)
    order[#order + 1] = "after"
  end)
  assert(table.concat(order, ",") == "before,inner,after", table.concat(order, ","))
end)

print("\n== menu actions ==")

local shown_errors
local function newMenu(book_status)
  shown_errors = {}
  local updates = 0
  local menu_instance = { updateItems = function() updates = updates + 1 end, updates = function() return updates end }
  local menu = setmetatable({
    state = { book_status = book_status or { id = 5, edition_id = 9 } },
    ui = { document = { file = "/books/a.epub" } },
    dialog_manager = { showError = function(_, msg) shown_errors[#shown_errors + 1] = "x" end },
    cache = { updateBookStatus = probe("cache.updateBookStatus", true) },
  }, { __index = HardcoverMenu })
  return menu, menu_instance
end

check("changing the book status", function()
  reset()
  local menu = newMenu()
  menu:setStatus(1)
  assertNoBlocking("setStatus")
end)

check("removing the current read", function()
  reset()
  Api.removeRead = probe("removeRead", { id = 1 })
  local menu, mi = newMenu()
  menu:removeCurrentRead(mi)
  assertNoBlocking("removeCurrentRead")
  assert(next(menu.state.book_status) == nil, "state was not cleared")
  assert(mi.updates() == 1, "menu was not refreshed")
end)

check("setting the page on an existing read", function()
  reset()
  Api.updatePage = probe("updatePage", { id = 5, status_id = 2 })
  local menu, mi = newMenu()
  menu:savePage({ id = 3, edition_id = 9, started_at = "2026-01-01" }, 120, mi)
  assertNoBlocking("savePage")
  assert(menu.state.book_status.status_id == 2 and mi.updates() == 1)
end)

check("setting the page when there is no read yet", function()
  reset()
  Api.createRead = probe("createRead", { id = 5, status_id = 2 })
  local menu, mi = newMenu()
  menu:savePage(nil, 120, mi)
  assertNoBlocking("savePage (new read)")
  assert(mi.updates() == 1)
end)

check("a failed page save is reported, not silent", function()
  reset()
  Api.updatePage = probe("updatePage", nil)
  local menu, mi = newMenu()
  menu:savePage({ id = 3 }, 120, mi)
  assert(#shown_errors == 1, "no error shown")
end)

check("saving a rating, and reporting a failure", function()
  reset()
  Api.updateRating = probe("updateRating", { id = 5, rating = 4 })
  local menu, mi = newMenu()
  menu:saveRating(4, mi)
  assertNoBlocking("saveRating")
  assert(menu.state.book_status.rating == 4)
  Api.updateRating = probe("updateRating", nil)
  menu:saveRating(4, mi)
  assert(#shown_errors == 1, "failure was not reported")
end)

check("clearing a rating fails quietly, as before", function()
  reset()
  Api.updateRating = probe("updateRating", nil)
  local menu, mi = newMenu()
  menu:saveRating(0, mi, true)
  assertNoBlocking("saveRating(quiet)")
  assert(#shown_errors == 0, "the long-press clear should not show an error")
end)

print("\n== Hardcover actions ==")

local function newHardcover()
  local status_calls = 0
  local h = setmetatable({
    ui = { document = { file = "/books/a.epub", getProps = function() return {} end } },
    settings = { getLinkedBookId = function() return 1 end },
    state = { book_status = { id = 5, status_id = 2 } },
    dialog_manager = { showError = function() end },
    cache = {
      updateBookStatus = probe("cache.updateBookStatus", true),
      cacheUserBook = probe("cache.cacheUserBook", nil),
    },
    wifi = { withWifi = function(_, fn) fn() end },
  }, { __index = Hardcover })
  return h
end

check("changing the visibility of the book", function()
  reset()
  local h = newHardcover()
  h:changeBookVisibility(1)
  assertNoBlocking("changeBookVisibility")
  assert(#blocking == 0)
end)

check("updating the current status", function()
  reset()
  newHardcover():updateCurrentBookStatus(2, 1)
  assertNoBlocking("updateCurrentBookStatus")
end)

check("linking a book from the picker, and the lookups behind it", function()
  reset()
  local captured
  local h = newHardcover()
  h.dialog_manager.buildLoadingSearchDialog = function(_, _, fetch, _, select_cb) captured = { fetch = fetch, select = select_cb } end
  h.findBookOptions = function(self)
    if not coroutine.running() then blocking[#blocking + 1] = "findBookOptions" end
    return "title", { { title = "t" } }, nil
  end
  h.linkBook = function(self, book)
    if not coroutine.running() then blocking[#blocking + 1] = "linkBook" end
    return true
  end
  h:showLinkBookDialog(false)
  local delivered
  captured.fetch(function(books) delivered = books end)
  captured.select({ title = "t" })
  assertNoBlocking("the link dialog")
  pump()
  assert(delivered and delivered[1].title == "t", "lookup results never reached the dialog")
end)

check("automatic linking", function()
  reset()
  local h = newHardcover()
  local linked = false
  h._runAutolink = function()
    if not coroutine.running() then blocking[#blocking + 1] = "_runAutolink" end
    linked = true
  end
  h.settings = {
    bookLinked = function() return false end,
    readSetting = function() return true end,
  }
  h.ui.document.getProps = function() return { title = "A Book", identifiers = "" } end
  h:tryAutolink()
  assertNoBlocking("tryAutolink")
  assert(linked, "autolink never ran")
end)

r.finish()
