-- The Activity tab through DialogManager: the saved copy on screen at once and offline, with a
-- note saying when it is from; a fresh answer replacing and saving it; a failed check leaving it
-- quietly; and what is still waiting to send listed first.
--
-- A fake tab and a recording API; the store and the queues are the real ones, over the in-memory
-- stand-in for the SQLite file and a settings table.
--
-- Run with:  lua spec/activity_flows_harness.lua [plugin-root]

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
local ActivityStore = real_require("hardcover/lib/activity_store")
local JournalQueue = real_require("hardcover/lib/journal_queue")
local ReviewQueue = real_require("hardcover/lib/review_queue")
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
local Feed = real_require("hardcover/lib/feed")
local MemoryStore = dofile(PLUGIN .. "/spec/lib/memory_store.lua")
User.getId = function() return 1 end

-- ------------------------------------------------------------ the API, recorded
local requests, answer
Api.getFeedAsync = function(_, opts, cb)
  requests[#requests + 1] = opts
  if answer then cb(answer(opts)) end
end

local infos, retries
StatusDialogs.info = function(text) infos[#infos + 1] = text end
StatusDialogs.retry = function() retries = retries + 1 end

-- ------------------------------------------------------------ the tab, faked
local tab
local Body = real_require("hardcover/lib/ui/activity_body")
Body.new = function(_, o)
  o = o or {}
  o.entries = o.entries or {}
  o.setEntries = function(self, entries, more)
    self.message = nil
    self.entries, self.has_more = entries or {}, more == true
    if #self.entries == 0 then self.message = "No activity yet." end
  end
  o.setMessage = function(self, m) self.message = m end
  o.setLoading = function() end
  o.free = function() end
  tab = o
  return o
end

local clock = 1000000
local function entry(n)
  return { key = "journal:" .. n, kind = "note", at = string.format("2026-10-%02dT10:00:00+00:00", n),
           date = string.format("2026-10-%02d", n), who = "Dana", book_id = 5, title = "Dune",
           text = "Note " .. n, excerpt = "Note " .. n }
end
local function page(from, to, more)
  local entries = {}
  for n = from, to, -1 do entries[#entries + 1] = entry(n) end
  return { entries = entries, cursor = entries[#entries] and entries[#entries].at, more = more }
end

local function fakeSettings()
  local data = {}
  return { readSetting = function(_, k) return data[k] end, saveSetting = function(_, k, v) data[k] = v end,
           flush = function() end }
end

local function newManager()
  requests, infos, retries, stack, tab, answer = {}, {}, 0, {}, nil, nil
  online = true
  Api.auth = nil
  local m = setmetatable({
    settings = { compatibilityMode = function() return false end, readSetting = function() end,
                 updateSetting = function() end },
    activity_store = ActivityStore:new { db = MemoryStore.new(), now = function() return clock end },
    journal_queue = JournalQueue:new { settings = fakeSettings() },
    review_queue = ReviewQueue:new { settings = fakeSettings() },
  }, { __index = DialogManager })
  return m
end

local check = r.test

print("\n== the first time ==")

check("online with nothing saved: it says it is loading, then shows and keeps the answer", function()
  local m = newManager()
  m:showActivity()
  assert(tab.message and tab.message:find("Loading"), "should say it is loading: " .. tostring(tab.message))
  assert(#requests == 1 and requests[1].mine == true and requests[1].me_id == 1 and requests[1].before == nil)
  -- the answer arrives
  answer = function() return page(25, 6, true) end
  m:showActivity()
  assert(#tab.entries == 20 and tab.has_more == true and tab.message == nil)
  local saved = m.activity_store:get(1)
  assert(saved and #saved.entries == 20 and saved.more == true and saved.saved_at == clock, "the answer was not kept")
end)

check("offline with nothing saved: it says it needs a connection the first time, and asks nothing", function()
  local m = newManager()
  online = false
  m:showActivity()
  assert(#requests == 0, "asked while offline")
  assert(tab.message and tab.message:find("the first time"), tostring(tab.message))
  assert(#infos == 0)
end)

print("\n== the saved copy ==")

check("offline: the saved copy opens at once, with when it is from", function()
  local m = newManager()
  m.activity_store:put(1, page(25, 6, true).entries, true)
  online = false
  m:showActivity()
  assert(#requests == 0, "asked while offline")
  assert(tab.message == nil and #tab.entries == 20 and tab.entries[1].key == "journal:25")
  assert(tab.has_more == false, "Load more needs a connection")
  assert(#infos == 1 and infos[1]:find("Offline: showing your activity as of", 1, true), tostring(infos[1]))
end)

check("offline: a saved copy with nothing in it says there is nothing, not that it needs a connection", function()
  local m = newManager()
  m.activity_store:put(1, {}, false)
  online = false
  m:showActivity()
  assert(tab.message and tab.message:find("No activity"), tostring(tab.message))
end)

check("online: the saved copy is on screen while the newest page is asked for, then replaced", function()
  local m = newManager()
  m.activity_store:put(1, page(10, 1, false).entries, false)
  m:showActivity()
  assert(tab.message == nil and #tab.entries == 10 and tab.entries[1].key == "journal:10", "the saved copy was not shown")
  assert(#infos == 0, "online needs no note")
  assert(#requests == 1)
  answer = function() return page(12, 3, false) end
  m:showActivity()
  assert(#tab.entries == 10 and tab.entries[1].key == "journal:12")
  assert(m.activity_store:get(1).entries[1].key == "journal:12", "the fresh page was not kept")
end)

check("online: a failed check leaves the saved copy without asking to retry", function()
  local m = newManager()
  m.activity_store:put(1, page(10, 1, false).entries, false)
  answer = function() return nil, "timeout" end
  m:showActivity()
  assert(retries == 0, "should not interrupt over a saved copy")
  assert(tab.message == nil and #tab.entries == 10)
  assert(m.activity_store:get(1).entries[1].key == "journal:10", "the saved copy must stay")
end)

check("online with nothing saved: a failure asks to retry", function()
  local m = newManager()
  answer = function() return nil, "timeout" end
  m:showActivity()
  assert(retries == 1)
end)

check("Load more keeps the longer list, and the copy is saved under each account", function()
  local m = newManager()
  answer = function(opts)
    if opts.before then return page(5, 1, false) end
    return page(25, 6, true)
  end
  m:showActivity()
  tab.more_cb()
  assert(#tab.entries == 25 and tab.has_more == false)
  assert(#m.activity_store:get(1).entries == 25 and m.activity_store:get(1).more == false)
  assert(m.activity_store:get(2) == nil, "another account must not see this one's activity")
end)

print("\n== waiting to send ==")

check("notes, quotes and reviews still on the device come first, saying they are waiting", function()
  local m = newManager()
  m.journal_queue:queue({ user_id = 1, book_id = 5, event = "note", text = "Older note", title = "Dune" })
  m.journal_queue:queue({ user_id = 1, book_id = 6, event = "quote", text = "Newer quote", title = "Kindred", page = 3 })
  m.journal_queue:queue({ user_id = 2, book_id = 6, event = "note", text = "Not yours", title = "Kindred" })
  m.review_queue:queue(900, "My review", false, "Dune")
  m.activity_store:put(1, page(10, 1, false).entries, false)
  online = false
  m:showActivity()
  assert(#tab.entries == 13, "shown " .. #tab.entries)
  assert(tab.entries[1].text == "Newer quote" and tab.entries[1].waiting)
  assert(tab.entries[2].text == "Older note" and tab.entries[3].kind == "review")
  assert(tab.entries[4].key == "journal:10")
  assert(Feed.row(tab.entries[1]).support:find(Feed.WAITING, 1, true) == 1)
end)

check("offline with only waiting entries: they show, with a note that the rest needs a connection", function()
  local m = newManager()
  m.journal_queue:queue({ user_id = 1, book_id = 5, event = "note", text = "Written offline", title = "Dune" })
  online = false
  m:showActivity()
  assert(tab.message == nil and #tab.entries == 1 and tab.entries[1].waiting)
  assert(#infos == 1 and infos[1]:find("waiting to send", 1, true), tostring(infos[1]))
end)

check("online: waiting entries stay above each fresh page, and are not saved as Hardcover's", function()
  local m = newManager()
  m.journal_queue:queue({ user_id = 1, book_id = 5, event = "note", text = "Not sent yet", title = "Dune" })
  answer = function() return page(10, 1, false) end
  m:showActivity()
  assert(#tab.entries == 11 and tab.entries[1].waiting and tab.entries[2].key == "journal:10")
  local saved = m.activity_store:get(1)
  assert(#saved.entries == 10, "the waiting entry was saved as if Hardcover had it")
  for _, e in ipairs(saved.entries) do assert(not e.waiting) end
end)

print("\n== permission ==")

check("a sign-in without journal access says so online and asks nothing", function()
  local m = newManager()
  Api.auth = { hasScope = function(_, scope) return scope ~= "read:journal" end }
  m:showActivity()
  Api.auth = nil
  assert(#requests == 0)
  assert(tab.message and tab.message:find("reading journal"), tostring(tab.message))
end)

r.finish()
