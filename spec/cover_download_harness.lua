-- Settings > Download covers for offline: what it plans, how it runs, and the screen side
-- (the estimate, the progress window and Stop, keeping the device awake, Wi-Fi, and what
-- it says at the end).
--
-- Run with:  lua spec/cover_download_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local json = dofile(PLUGIN .. "/spec/json.lua")
package.preload["json"] = function() return json end

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

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
local stack, standby = {}, 0
local UIManager = {
  show = function(_, w) stack[#stack + 1] = w end,
  close = function(_, w) for i = #stack, 1, -1 do if stack[i] == w then table.remove(stack, i) end end end,
  isWidgetShown = function(_, w) for _, x in ipairs(stack) do if x == w then return true end end return false end,
  setDirty = function() end, scheduleIn = function() end, unschedule = function() end,
  nextTick = function(_, fn) fn() end,
  preventStandby = function() standby = standby + 1 end,
  allowStandby = function() standby = standby - 1 end,
}
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn)
    local ok, err = coroutine.resume(coroutine.create(fn))
    if not ok then error("wrapped function raised: " .. tostring(err), 0) end
  end }
end
package.preload["ui/network/manager"] = function() return { isConnected = function() return online end } end
package.preload["gettext"] = function() return setmetatable({}, { __call = function(_, s) return s end }) end
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
-- the progress window and the question: record what is shown
local dialogs = {}
package.preload["ui/widget/buttondialog"] = function()
  return { new = function(_, o) o.kind = "progress"; dialogs[#dialogs + 1] = o; return o end }
end
package.preload["ui/widget/confirmbox"] = function()
  return { new = function(_, o) o.kind = "confirm"; dialogs[#dialogs + 1] = o; return o end }
end

-- a fake image loader: covers "on the device" are tables of keys
local pinned, seen, fetched, fail = {}, {}, {}, {}
local stop_after
local Loader = {
  getPinned = function() return { has = function(_, k) return pinned[k] ~= nil end } end,
  getCache = function() return { has = function(_, k) return seen[k] ~= nil end } end,
  fetchUrl = function(_, url) return "small:" .. url end,
  copyForOffline = function(_, key) pinned[key] = seen[key]; return true end,
  keepForOffline = function(_, url)
    fetched[#fetched + 1] = url
    if stop_after and #fetched >= stop_after then require("hardcover/lib/ui/dialog_manager").__stop() end
    if fail[url] then return false end
    pinned["small:" .. url] = "img"
    return true
  end,
}
package.loaded["hardcover/lib/ui/image_loader"] = Loader

local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local CoverDownload = real_require("hardcover/lib/cover_download")
local StatusDialogs = real_require("hardcover/lib/ui/status_dialogs")
local User = real_require("hardcover/lib/user")
local BookStore = real_require("hardcover/lib/book_store")
local ShelfStore = real_require("hardcover/lib/shelf_store")
local ListStore = real_require("hardcover/lib/list_store")
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
local MemoryStore = dofile(PLUGIN .. "/spec/lib/memory_store.lua")
User.getId = function() return 1 end

local infos
StatusDialogs.info = function(text) infos[#infos + 1] = text end

print("\n== the plan ==")

check("covers kept for offline are skipped, ones seen are copied, the rest downloaded", function()
  local plan = CoverDownload.plan({ "a", "b", "c" }, function(u) return "k" .. u end,
    function(k) return k == "ka" end, function(k) return k == "kb" end)
  assert(plan.total == 3 and plan.done == 1 and #plan.copy == 1 and #plan.fetch == 1)
  assert(plan.copy[1].url == "b" and plan.fetch[1].key == "kc")
  assert(CoverDownload.missing(plan) == 2)
end)

check("the estimate is about 30 KB a download, said plainly", function()
  local plan = { fetch = {}, copy = {} }
  for i = 1, 800 do plan.fetch[i] = {} end
  assert(CoverDownload.size(CoverDownload.estimate(plan)) == "23 MB", CoverDownload.size(CoverDownload.estimate(plan)))
  assert(CoverDownload.size(1000) == "less than 1 MB")
end)

check("the run copies first, then downloads, counts what failed, and stops when asked", function()
  local order, stop = {}, false
  local result = CoverDownload.run {
    plan = { copy = { { key = "c1" } }, fetch = { { url = "f1" }, { url = "f2" }, { url = "f3" } } },
    copy = function(i) order[#order + 1] = i.key return true end,
    fetch = function(i) order[#order + 1] = i.url; if i.url == "f2" then stop = true end; return i.url ~= "f1" end,
    stopped = function() return stop end,
  }
  assert(table.concat(order, ",") == "c1,f1,f2", table.concat(order, ","))
  assert(result.copied == 1 and result.fetched == 1 and result.failed == 1 and result.stopped)
end)

print("\n== Settings > Download covers for offline ==")

local function manager()
  pinned, seen, fetched, fail, infos, dialogs, stack, standby, stop_after = {}, {}, {}, {}, {}, {}, {}, 0, nil
  online = true
  local db = MemoryStore.new()
  local books = BookStore:new { db = db }
  local m = setmetatable({
    book_store = books,
    shelf_store = ShelfStore:new { db = db, books = books },
    list_store = ListStore:new { db = db, books = books },
    wifi = {
      cancelled = 0, scheduled = 0,
      withWifi = function(self, cb) cb(self.turn_on or false) end,
      cancelScheduledDisable = function(self) self.cancelled = self.cancelled + 1 end,
      scheduleDisable = function(self) self.scheduled = self.scheduled + 1 end,
    },
  }, { __index = DialogManager })
  DialogManager.__stop = function() m:stopCoverDownload() end
  return m
end

local function book(id) return { user_book_id = id, book_id = id, title = "B" .. id,
                                 cached_image = { url = "https://assets.hardcover.app/" .. id .. ".jpg" } } end

local function confirm()
  local box
  for _, d in ipairs(dialogs) do if d.kind == "confirm" then box = d end end
  assert(box, "no question was asked")
  box.ok_callback()
end

check("nothing saved yet: it says to open Home online first", function()
  local m = manager()
  m:downloadCoversForOffline()
  assert(infos[1]:find("Open Home once while online"), tostring(infos[1]))
end)

check("the covers of books on shelves and lists, each once, books without one left out", function()
  local m = manager()
  m.shelf_store:putEntries(1, 3, { book(1), book(2), { book_id = 3, title = "No cover" } }, true, "x")
  m.list_store:putEntries(1, { id = 9, fingerprint = "y" }, { book(2), book(4) }, true)
  local urls = m.book_store:libraryCovers(1)
  assert(#urls == 3, "covers: " .. #urls)
end)

check("it asks first, with how many and about how much, then keeps them all", function()
  local m = manager()
  m.shelf_store:putEntries(1, 3, { book(1), book(2), book(3) }, true, "x")
  seen["small:https://assets.hardcover.app/3.jpg"] = "img" -- seen before: copied, not downloaded
  assert(m:coversMenuText() == "Download covers for offline (3 missing)", m:coversMenuText())
  m:downloadCoversForOffline()
  assert(dialogs[1].kind == "confirm" and dialogs[1].text:find("Keep 3 covers for offline"), dialogs[1].text)
  confirm()
  assert(#fetched == 2, "downloaded " .. #fetched .. " (a seen cover was downloaded again?)")
  assert(infos[#infos] == "Every cover is kept for offline (3).", tostring(infos[#infos]))
  assert(m:coversMenuText() == "Download covers for offline", "the count was not taken again")
end)

check("the device is kept awake while it runs, and allowed to sleep after", function()
  local m = manager()
  m.shelf_store:putEntries(1, 3, { book(1) }, true, "x")
  m:downloadCoversForOffline()
  local during
  Loader.keepForOffline = (function(orig) return function(...) during = standby; return orig(...) end end)(Loader.keepForOffline)
  confirm()
  assert(during == 1 and standby == 0, "standby during " .. tostring(during) .. ", after " .. standby)
end)

check("Stop ends it after the cover it is on, and running it again carries on", function()
  local m = manager()
  local many = {}
  for i = 1, 25 do many[i] = book(i) end
  m.shelf_store:putEntries(1, 3, many, true, "x")
  stop_after = 5
  m:downloadCoversForOffline()
  confirm()
  assert(#fetched == 5, "fetched " .. #fetched)
  assert(infos[#infos]:find("Stopped: 5 of 25"), infos[#infos])
  assert(m:coversMenuText():find("20 missing"), m:coversMenuText())
  stop_after = nil
  fetched, dialogs = {}, {}
  m:downloadCoversForOffline()
  confirm()
  assert(#fetched == 20, "carried on with " .. #fetched)
end)

check("the progress window is redrawn every ten covers, not every one, and goes away at the end", function()
  local m = manager()
  local many = {}
  for i = 1, 25 do many[i] = book(i) end
  m.shelf_store:putEntries(1, 3, many, true, "x")
  m:downloadCoversForOffline()
  confirm()
  local progress = 0
  for _, d in ipairs(dialogs) do if d.kind == "progress" then progress = progress + 1 end end
  assert(progress == 3, "progress windows: " .. progress) -- 0, 10, 20
  for _, w in ipairs(stack) do assert(w.kind ~= "progress", "the progress window was left up") end
end)

check("covers that fail are counted, and the message says to run it again", function()
  local m = manager()
  m.shelf_store:putEntries(1, 3, { book(1), book(2) }, true, "x")
  fail["https://assets.hardcover.app/1.jpg"] = true
  m:downloadCoversForOffline()
  confirm()
  assert(infos[#infos]:find("1 could not be downloaded"), infos[#infos])
end)

check("Wi-Fi the plugin switched on stays up through the run and goes off after", function()
  local m = manager()
  m.shelf_store:putEntries(1, 3, { book(1), book(2) }, true, "x")
  m.wifi.turn_on = true
  m:downloadCoversForOffline()
  confirm()
  assert(m.wifi.cancelled == 2 and m.wifi.scheduled == 1)
  local m2 = manager()
  m2.shelf_store:putEntries(1, 3, { book(1) }, true, "x")
  m2:downloadCoversForOffline()
  confirm()
  assert(m2.wifi.scheduled == 0, "switched off Wi-Fi it did not switch on")
end)

check("offline it says it needs a connection and downloads nothing", function()
  local m = manager()
  m.shelf_store:putEntries(1, 3, { book(1) }, true, "x")
  m:downloadCoversForOffline()
  online = false
  confirm()
  assert(#fetched == 0 and infos[#infos]:find("needs an internet connection"))
end)

check("with every cover kept, it says so instead of asking", function()
  local m = manager()
  m.shelf_store:putEntries(1, 3, { book(1) }, true, "x")
  pinned["small:https://assets.hardcover.app/1.jpg"] = "img"
  m:downloadCoversForOffline()
  assert(#dialogs == 0 and infos[1] == "Every cover is already kept for offline (1).", tostring(infos[1]))
end)

r.finish()
