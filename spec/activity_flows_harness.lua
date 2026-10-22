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
-- the screens an entry opens, as plain tables: what they were given, to read and tap
local opened = {}
local function fakeScreen(kind)
  return function()
    return { new = function(_, o)
      o = o or {}
      o.kind = kind
      o.getInputText = function(self) return self.typed or self.input end
      opened[#opened + 1] = o
      return o
    end }
  end
end
package.preload["hardcover/lib/ui/text_screen"] = fakeScreen("text")
package.preload["hardcover/lib/ui/components/input_dialog"] = fakeScreen("input")
package.preload["hardcover/lib/ui/picker"] = function()
  return { new = function(o) o.kind = "picker"; opened[#opened + 1] = o; return o end }
end
local function last(kind)
  for i = #opened, 1, -1 do if opened[i].kind == kind then return opened[i] end end
end
local function button(widget, label)
  for _, b in ipairs(widget.buttons or {}) do if b.label == label then return b end end
  error("no " .. label .. " button")
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

local infos, retries, confirms
StatusDialogs.info = function(text) infos[#infos + 1] = text end
StatusDialogs.retry = function() retries = retries + 1 end
StatusDialogs.confirm = function(options) confirms[#confirms + 1] = options end

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

local flushes
local function newManager()
  requests, infos, retries, confirms, stack, tab, answer, opened, flushes = {}, {}, 0, {}, {}, nil, nil, {}, 0
  online = true
  Api.auth = nil
  local m = setmetatable({
    flush_goals = function() flushes = flushes + 1 end,
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

print("\n== editing and deleting your entries ==")

-- the tab open offline on a saved copy: a note, a quote, a review and a status change
local function savedTab()
  local m = newManager()
  m.activity_store:put(1, {
    { key = "note:4001", id = 4001, kind = "note", user_id = 1, who = "Dana", book_id = 5, title = "Dune",
      text = "Old words", excerpt = "Old words", at = "2026-10-20T10:00:00+00:00", date = "2026-10-20" },
    { key = "quote:4002", id = 4002, kind = "quote", user_id = 1, who = "Dana", book_id = 5, title = "Dune",
      text = "Fear is the mind-killer.", excerpt = "Fear is the mind-killer.", at = "2026-10-19T10:00:00+00:00", date = "2026-10-19" },
    { key = "review:900", id = 900, kind = "review", user_id = 1, who = "Dana", book_id = 6, title = "Kindred",
      text = "Fine", excerpt = "Fine", at = "2026-10-18", date = "2026-10-18" },
    { key = "status:7", kind = "status", user_id = 1, who = "Dana", book_id = 6, title = "Kindred",
      text = "Finished", at = "2026-10-17T10:00:00+00:00", date = "2026-10-17" },
  }, false)
  online = false
  m:showActivity()
  infos = {}
  return m
end
local function find(key)
  for _, e in ipairs(tab.entries) do if e.key == key then return e end end
end

check("your note opens in full with Edit and Delete; another reader's has neither", function()
  local m = savedTab()
  tab.select_cb(find("note:4001"))
  local screen = last("text")
  assert(screen and screen.text == "Old words")
  button(screen, "Edit"); button(screen, "Delete")
  m:openActivityEntry({ key = "note:1", id = 1, kind = "note", user_id = 2, who = "Sam", text = "Theirs" })
  assert(last("text").buttons == nil, "someone else's note must not offer Edit or Delete")
end)

check("editing a note offline keeps the change, shows it in place, and says it waits", function()
  local m = savedTab()
  tab.select_cb(find("note:4001"))
  button(last("text"), "Edit").callback()
  local input = last("input")
  assert(input.input == "Old words", "the field should start with the note")
  input.typed = "  New words \r\n"
  button(input, "Save").callback()
  local op = m.journal_queue:changeFor(4001)
  assert(op and op.action == "update" and op.text == "New words" and op.book_id == 5 and op.event == "note")
  local shown = find("note:4001")
  assert(shown.text == "New words" and shown.waiting, "the tab should show the change at once")
  assert(infos[#infos]:find("offline", 1, true), tostring(infos[#infos]))
  assert(flushes == 0)
  assert(m.activity_store:get(1).entries[1].text == "Old words", "the saved copy keeps what Hardcover has until it takes the change")
end)

check("an empty edit is refused and the field stays open; an unchanged one does nothing", function()
  local m = savedTab()
  tab.select_cb(find("note:4001"))
  button(last("text"), "Edit").callback()
  local input = last("input")
  input.typed = "   "
  button(input, "Save").callback()
  assert(infos[#infos]:find("Use Delete", 1, true), tostring(infos[#infos]))
  assert(m.journal_queue:count() == 0)
  input.typed = "Old words"
  button(input, "Save").callback()
  assert(m.journal_queue:count() == 0, "nothing changed, nothing to send")
end)

check("editing online sends it now", function()
  local m = savedTab()
  online = true
  tab.select_cb(find("quote:4002"))
  button(last("text"), "Edit").callback()
  last("input").typed = "Fear is the little-death."
  button(last("input"), "Save").callback()
  assert(flushes == 1, "the change should go now")
  assert(infos[#infos] == "Quote saved.", tostring(infos[#infos]))
end)

check("a note not sent yet is edited where it waits", function()
  local m = savedTab()
  local id = m.journal_queue:queue({ user_id = 1, book_id = 5, event = "note", text = "Draft", title = "Dune" })
  m:showActivity()
  tab.select_cb(tab.entries[1])
  button(last("text"), "Edit").callback()
  last("input").typed = "Final"
  button(last("input"), "Save").callback()
  assert(m.journal_queue:count() == 1 and m.journal_queue:list()[1].id == id and m.journal_queue:list()[1].text == "Final")
  assert(tab.entries[1].text == "Final")
end)

check("deleting a quote asks first, then hides it and keeps the delete", function()
  local m = savedTab()
  tab.select_cb(find("quote:4002"))
  button(last("text"), "Delete").callback()
  local ask = confirms[#confirms]
  assert(ask and ask.title == "Delete this quote?" and ask.ok_text == "Delete", tostring(ask and ask.title))
  assert(m.journal_queue:count() == 0, "nothing is deleted before the answer")
  ask.ok_callback()
  local op = m.journal_queue:changeFor(4002)
  assert(op and op.action == "delete")
  assert(find("quote:4002") == nil, "the deleted quote is still listed")
  assert(#tab.entries == 3)
end)

check("deleting a note not sent yet discards it", function()
  local m = savedTab()
  m.journal_queue:queue({ user_id = 1, book_id = 5, event = "note", text = "Oops", title = "Dune" })
  m:showActivity()
  tab.select_cb(tab.entries[1])
  button(last("text"), "Delete").callback()
  local ask = confirms[#confirms]
  assert(ask.title == "Discard this note?" and ask.ok_text == "Discard", ask.title)
  ask.ok_callback()
  assert(m.journal_queue:count() == 0)
  assert(tab.entries[1].key == "note:4001")
end)

check("deleting your review keeps its removal and hides it", function()
  local m = savedTab()
  tab.select_cb(find("review:900"))
  button(last("text"), "Delete").callback()
  assert(confirms[#confirms].title == "Delete your review?")
  confirms[#confirms].ok_callback()
  local waiting = m.review_queue:get(900)
  assert(waiting and waiting.text == "", "the removal should wait in the review queue")
  assert(find("review:900") == nil)
end)

check("editing your review goes through the review form and shows in place", function()
  local m = savedTab()
  tab.select_cb(find("review:900"))
  button(last("text"), "Edit").callback()
  local input = last("input")
  assert(input.input == "Fine", "the form should start with the review")
  input.typed = "Wonderful after all"
  button(input, "Next").callback()
  local picker = last("picker")
  picker.rows[2].callback() -- has spoilers
  local waiting = m.review_queue:get(900)
  assert(waiting and waiting.text == "Wonderful after all" and waiting.spoilers == true)
  local shown = find("review:900")
  assert(shown and shown.waiting and shown.text == "Wonderful after all" and shown.spoilers == true)
end)

check("once Hardcover has a change, the saved copy shows it", function()
  local m = savedTab()
  m:journalChangeSent({ action = "update", event = "note", journal_id = 4001, text = "Sent words" })
  m:journalChangeSent({ action = "delete", event = "quote", journal_id = 4002 })
  m:journalChangeSent({ event = "note", book_id = 5, text = "a new one is fetched, not patched" })
  m:reviewChangeSent(900, nil)
  local entries = m.activity_store:get(1).entries
  assert(#entries == 2, "kept " .. #entries)
  assert(entries[1].key == "note:4001" and entries[1].text == "Sent words" and entries[1].excerpt == "Sent words")
  assert(entries[2].key == "status:7")
  m:reviewChangeSent(901, "not listed")
  assert(#m.activity_store:get(1).entries == 2)
end)

r.finish()
