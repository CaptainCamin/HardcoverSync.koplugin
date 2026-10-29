-- The Journal tab through DialogManager: the saved copy on screen at once and offline, with a
-- note saying when it is from; a fresh answer replacing and saving it; a failed check leaving it
-- quietly; Load more asking from where the last page ended; what is still waiting to send listed
-- first; and your notes, quotes and reviews edited and deleted from there.
--
-- A fake tab and a recording API; the store and the queues are the real ones, over the in-memory
-- stand-in for the SQLite file and a settings table.
--
-- Run with:  lua spec/journal_flows_harness.lua [plugin-root]

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
local JournalStore = real_require("hardcover/lib/journal_store")
local JournalQueue = real_require("hardcover/lib/journal_queue")
local ReviewQueue = real_require("hardcover/lib/review_queue")
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
local Journal = real_require("hardcover/lib/journal")
local MemoryStore = dofile(PLUGIN .. "/spec/lib/memory_store.lua")
User.getId = function() return 1 end

-- ------------------------------------------------------------ the API, recorded
local requests, answer
Api.getJournalAsync = function(_, opts, cb)
  requests[#requests + 1] = opts
  if answer then cb(answer(opts)) end
end

local infos, retries, confirms
StatusDialogs.info = function(text) infos[#infos + 1] = text end
StatusDialogs.retry = function() retries = retries + 1 end
StatusDialogs.confirm = function(options) confirms[#confirms + 1] = options end

-- ------------------------------------------------------------ the tab, faked
local tab
local Body = real_require("hardcover/lib/ui/journal_body")
Body.new = function(_, o)
  o = o or {}
  o.entries = o.entries or {}
  o.setEntries = function(self, entries, more)
    self.message = nil
    self.loading = false
    self.entries, self.has_more = entries or {}, more == true
    if #self.entries == 0 then self.message = "Nothing in your journal yet." end
  end
  o.setMessage = function(self, m) self.message = m end
  o.setLoading = function(self, loading) self.loading = loading end
  o.loadMore = function(self) self.loading = true; self.more_cb() end
  o.free = function() end
  tab = o
  return o
end

local clock = 1000000
local function entry(n)
  return { key = "note:" .. n, id = n, kind = "note", at = string.format("2026-10-%02dT10:00:00+00:00", n),
           user_id = 1, book_id = 5, title = "Dune", authors = "Frank Herbert", text = "Note " .. n, excerpt = "Note " .. n }
end
-- a page as Journal.parse gives it; `count` is how many rows Hardcover sent (some may not be shown)
local function page(from, to, more, count)
  local entries = {}
  for n = from, to, -1 do entries[#entries + 1] = entry(n) end
  return { entries = entries, count = count or #entries, more = more }
end

local function fakeSettings()
  local data = {}
  return { readSetting = function(_, k) return data[k] end, saveSetting = function(_, k, v) data[k] = v end,
           flush = function() end }
end

local flushes, books
local function newManager()
  requests, infos, retries, confirms, stack, tab, answer, opened, flushes, books = {}, {}, 0, {}, {}, nil, nil, {}, 0, {}
  online = true
  Api.auth = nil
  local m = setmetatable({
    flush_goals = function() flushes = flushes + 1 end,
    settings = { compatibilityMode = function() return false end, readSetting = function() end,
                 updateSetting = function() end },
    journal_store = JournalStore:new { db = MemoryStore.new(), now = function() return clock end },
    journal_queue = JournalQueue:new { settings = fakeSettings() },
    review_queue = ReviewQueue:new { settings = fakeSettings() },
    showBookDetail = function(_, book_id) books[#books + 1] = book_id end,
  }, { __index = DialogManager })
  return m
end

local check = r.test

print("\n== the first time ==")

check("online with nothing saved: it says it is loading, then shows and keeps the answer", function()
  local m = newManager()
  m:showJournal()
  assert(tab.message and tab.message:find("Loading"), "should say it is loading: " .. tostring(tab.message))
  assert(#requests == 1 and requests[1].me_id == 1 and requests[1].offset == 0 and requests[1].limit == Journal.PAGE_SIZE)
  -- the answer arrives
  answer = function() return page(25, 6, true) end
  m:showJournal()
  assert(#tab.entries == 20 and tab.has_more == true and tab.message == nil)
  local saved = m.journal_store:get(1)
  assert(saved and #saved.entries == 20 and saved.more == true and saved.saved_at == clock, "the answer was not kept")
end)

check("offline with nothing saved: it says it needs a connection the first time, and asks nothing", function()
  local m = newManager()
  online = false
  m:showJournal()
  assert(#requests == 0, "asked while offline")
  assert(tab.message and tab.message:find("the first time"), tostring(tab.message))
  assert(#infos == 0)
end)

print("\n== the saved copy ==")

check("offline: the saved copy opens at once, with when it is from", function()
  local m = newManager()
  m.journal_store:put(1, page(25, 6, true).entries, true)
  online = false
  m:showJournal()
  assert(#requests == 0, "asked while offline")
  assert(tab.message == nil and #tab.entries == 20 and tab.entries[1].key == "note:25")
  assert(tab.has_more == false, "Load more needs a connection")
  assert(#infos == 1 and infos[1]:find("Offline: showing your journal as of", 1, true), tostring(infos[1]))
end)

check("offline: a saved copy with nothing in it says there is nothing, not that it needs a connection", function()
  local m = newManager()
  m.journal_store:put(1, {}, false)
  online = false
  m:showJournal()
  assert(tab.message and tab.message:find("Nothing in your journal"), tostring(tab.message))
end)

check("online: the saved copy is on screen while the newest page is asked for, then replaced", function()
  local m = newManager()
  m.journal_store:put(1, page(10, 1, false).entries, false)
  m:showJournal()
  assert(tab.message == nil and #tab.entries == 10 and tab.entries[1].key == "note:10", "the saved copy was not shown")
  assert(#infos == 0, "online needs no note")
  assert(#requests == 1)
  answer = function() return page(12, 3, false) end
  m:showJournal()
  assert(#tab.entries == 10 and tab.entries[1].key == "note:12")
  assert(m.journal_store:get(1).entries[1].key == "note:12", "the fresh page was not kept")
end)

check("online: a failed check leaves the saved copy without asking to retry", function()
  local m = newManager()
  m.journal_store:put(1, page(10, 1, false).entries, false)
  answer = function() return nil, "timeout" end
  m:showJournal()
  assert(retries == 0, "should not interrupt over a saved copy")
  assert(tab.message == nil and #tab.entries == 10)
  assert(m.journal_store:get(1).entries[1].key == "note:10", "the saved copy must stay")
end)

check("online with nothing saved: a failure asks to retry", function()
  local m = newManager()
  answer = function() return nil, "timeout" end
  m:showJournal()
  assert(retries == 1)
end)

print("\n== the next page ==")

check("Load more asks from where Hardcover's rows ended, keeps the longer list, and saves it under the account", function()
  local m = newManager()
  answer = function(opts)
    if opts.offset > 0 then return page(5, 1, false) end
    -- 21 rows sent, one of a kind the tab does not show
    return page(25, 6, true, 21)
  end
  m:showJournal()
  tab:loadMore()
  assert(requests[2].offset == 21, "the next page starts after every row sent: " .. tostring(requests[2].offset))
  assert(requests[2].me_id == 1, "the next page is yours too")
  assert(#tab.entries == 25 and tab.has_more == false)
  assert(#m.journal_store:get(1).entries == 25 and m.journal_store:get(1).more == false)
  assert(m.journal_store:get(2) == nil, "another account must not see this one's journal")
end)

check("an entry the next page repeats (one written meanwhile moved the rest down) is listed once", function()
  local m = newManager()
  answer = function(opts)
    if opts.offset > 0 then return page(6, 2, true) end
    return page(25, 6, true)
  end
  m:showJournal()
  tab:loadMore()
  assert(#tab.entries == 24, "listed " .. #tab.entries)
  assert(requests[2].offset == 20)
  tab:loadMore()
  assert(requests[3].offset == 25, "the offset moves on by the rows sent, repeated or not")
end)

check("a failed Load more says so, offers to try again, and leaves the list as it was", function()
  local m = newManager()
  answer = function(opts)
    if opts.offset > 0 then return nil, "timeout" end
    return page(25, 6, true)
  end
  m:showJournal()
  tab:loadMore()
  assert(retries == 1)
  assert(tab.loading == false and #tab.entries == 20 and tab.has_more == true)
end)

print("\n== waiting to send ==")

check("notes, quotes and reviews still on the device come first, saying they are waiting", function()
  local m = newManager()
  m.journal_queue:queue({ user_id = 1, book_id = 5, event = "note", text = "Older note", title = "Dune" })
  m.journal_queue:queue({ user_id = 1, book_id = 6, event = "quote", text = "Newer quote", title = "Kindred", page = 3 })
  m.journal_queue:queue({ user_id = 2, book_id = 6, event = "note", text = "Not yours", title = "Kindred" })
  m.review_queue:queue(900, "My review", false, "Dune")
  m.journal_store:put(1, page(10, 1, false).entries, false)
  online = false
  m:showJournal()
  assert(#tab.entries == 13, "shown " .. #tab.entries)
  assert(tab.entries[1].text == "Newer quote" and tab.entries[1].waiting)
  assert(tab.entries[2].text == "Older note" and tab.entries[3].kind == "review")
  assert(tab.entries[4].key == "note:10")
  assert(Journal.row(tab.entries[1]).detail == Journal.WAITING)
  assert(Journal.row(tab.entries[2]).detail == "Frank Herbert \194\183 " .. Journal.WAITING,
    "a waiting note on a book the journal lists has its authors")
end)

check("offline with only waiting entries: they show, with a note that the rest needs a connection", function()
  local m = newManager()
  m.journal_queue:queue({ user_id = 1, book_id = 5, event = "note", text = "Written offline", title = "Dune" })
  online = false
  m:showJournal()
  assert(tab.message == nil and #tab.entries == 1 and tab.entries[1].waiting)
  assert(#infos == 1 and infos[1]:find("waiting to send", 1, true), tostring(infos[1]))
end)

check("online: waiting entries stay above each fresh page, and are not saved as Hardcover's", function()
  local m = newManager()
  m.journal_queue:queue({ user_id = 1, book_id = 5, event = "note", text = "Not sent yet", title = "Dune" })
  answer = function() return page(10, 1, false) end
  m:showJournal()
  assert(#tab.entries == 11 and tab.entries[1].waiting and tab.entries[2].key == "note:10")
  local saved = m.journal_store:get(1)
  assert(#saved.entries == 10, "the waiting entry was saved as if Hardcover had it")
  for _, e in ipairs(saved.entries) do assert(not e.waiting) end
end)

print("\n== permission ==")

check("a sign-in without journal access says so online and asks nothing", function()
  local m = newManager()
  Api.auth = { hasScope = function(_, scope) return scope ~= "read:journal" end }
  m:showJournal()
  Api.auth = nil
  assert(#requests == 0)
  assert(tab.message and tab.message:find("permission to read your Hardcover journal", 1, true), tostring(tab.message))
end)

print("\n== opening, editing and deleting your entries ==")

-- the tab open offline on a saved copy: a note, a quote, two entries of one review, and a finish
local function savedTab()
  local m = newManager()
  m.journal_store:put(1, {
    { key = "note:4001", id = 4001, kind = "note", user_id = 1, book_id = 5, title = "Dune",
      text = "Old words", excerpt = "Old words", at = "2026-10-20T10:00:00+00:00" },
    { key = "quote:4002", id = 4002, kind = "quote", user_id = 1, book_id = 5, title = "Dune",
      text = "Fear is the mind-killer.", excerpt = "Fear is the mind-killer.", at = "2026-10-19T10:00:00+00:00" },
    { key = "reviewed:4003", id = 4003, kind = "review", user_book_id = 900, user_id = 1, book_id = 6, title = "Kindred",
      text = "Fine", excerpt = "Fine", at = "2026-10-18T10:00:00+00:00" },
    { key = "user_book_read_finished:4004", id = 4004, kind = "event", action = "Finished reading", user_id = 1,
      book_id = 6, title = "Kindred", at = "2026-10-17T10:00:00+00:00" },
    { key = "reviewed:4005", id = 4005, kind = "review", user_book_id = 900, user_id = 1, book_id = 6, title = "Kindred",
      text = "Fine", excerpt = "Fine", at = "2026-10-16T10:00:00+00:00" },
  }, false)
  online = false
  m:showJournal()
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
  assert(screen and screen.text == "Old words" and screen.title == "Journal")
  assert(screen.heading == "Note \194\183 Dune", tostring(screen.heading))
  button(screen, "Edit"); button(screen, "Delete")
  m:openJournalEntry({ key = "note:1", id = 1, kind = "note", user_id = 2, text = "Theirs" })
  assert(last("text").buttons == nil, "someone else's note must not offer Edit or Delete")
end)

check("any other entry opens the book, and so does a review since removed", function()
  local m = savedTab()
  local before = #opened
  tab.select_cb(find("user_book_read_finished:4004"))
  assert(books[1] == 6, "the book did not open")
  m:openJournalEntry({ key = "reviewed:9", kind = "review", user_book_id = 900, book_id = 6 })
  assert(books[2] == 6)
  assert(#opened == before, "no text screen for an entry with no text")
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
  assert(m.journal_store:get(1).entries[1].text == "Old words", "the saved copy keeps what Hardcover has until it takes the change")
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
  m:showJournal()
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
  assert(#tab.entries == 4)
end)

check("deleting a note not sent yet discards it", function()
  local m = savedTab()
  m.journal_queue:queue({ user_id = 1, book_id = 5, event = "note", text = "Oops", title = "Dune" })
  m:showJournal()
  tab.select_cb(tab.entries[1])
  button(last("text"), "Delete").callback()
  local ask = confirms[#confirms]
  assert(ask.title == "Discard this note?" and ask.ok_text == "Discard", ask.title)
  ask.ok_callback()
  assert(m.journal_queue:count() == 0)
  assert(tab.entries[1].key == "note:4001")
end)

check("deleting your review keeps its removal; the book's entries stay, saying only that you reviewed it", function()
  local m = savedTab()
  tab.select_cb(find("reviewed:4003"))
  button(last("text"), "Delete").callback()
  assert(confirms[#confirms].title == "Delete your review?")
  confirms[#confirms].ok_callback()
  local waiting = m.review_queue:get(900)
  assert(waiting and waiting.text == "", "the removal should wait in the review queue")
  for _, key in ipairs({ "reviewed:4003", "reviewed:4005" }) do
    local e = find(key)
    assert(e and e.text == nil and e.waiting, key .. " should stay, without the text")
    assert(Journal.row(e).what == "Reviewed")
  end
end)

check("reviews before the first sync stay distinct, can be edited and discarded by book", function()
  local m = newManager()
  online = false
  m.review_queue:queue(nil, "First draft", false, "Same title", 101, 1)
  m.review_queue:queue(nil, "Other book", false, "Same title", 202, 1)
  m.review_queue:queue(nil, "Another account's draft", false, "Same title", 101, 2)
  m:showJournal()
  assert(#tab.entries == 2 and tab.entries[1].key ~= tab.entries[2].key)
  assert(tab.entries[1].book_id == 101 and tab.entries[2].book_id == 202)
  tab.select_cb(tab.entries[1])
  button(last("text"), "Edit").callback()
  local input = last("input")
  assert(input.input == "First draft", "the pending review could not be opened for editing")
  input.typed = "Final draft"
  button(input, "Next").callback()
  last("picker").rows[2].callback()
  assert(m.review_queue:get(nil, 101, 1).text == "Final draft" and tab.entries[1].spoilers)
  tab.select_cb(tab.entries[1])
  button(last("text"), "Delete").callback()
  confirms[#confirms].ok_callback()
  assert(m.review_queue:get(nil, 101, 1) == nil and m.review_queue:get(nil, 202, 1).text == "Other book")
  assert(m.review_queue:get(nil, 101, 2).text == "Another account's draft")
  assert(#tab.entries == 1 and tab.entries[1].book_id == 202)
end)

check("editing a pending review does not inherit a deleted historical library record", function()
  for _, known_id in ipairs({ false, 907 }) do
    local m = newManager()
    online = false
    m.journal_store:put(1, {
      { key = "reviewed:4003", id = 4003, kind = "review", user_book_id = 700,
        user_id = 1, book_id = 101, title = "Dune", text = "Historical review" },
    }, false)
    m.review_queue:queue(known_id or nil, "Offline draft", false, "Dune", 101, 1)
    m:showJournal()
    assert(#tab.entries == 1 and tab.entries[1].text == "Offline draft")
    tab.select_cb(tab.entries[1])
    button(last("text"), "Edit").callback()
    local input = last("input")
    assert(input.input == "Offline draft")
    input.typed = "Edited offline draft"
    button(input, "Next").callback()
    last("picker").rows[2].callback()

    local lookups, writes = 0, 0
    local waiting = m.review_queue:flush({
      findUserBook = function(_, book_id, user_id)
        lookups = lookups + 1
        assert(book_id == 101 and user_id == 1)
        return { id = 907 }
      end,
      updateReview = function(_, id, text, spoilers)
        writes = writes + 1
        assert(id == 907, "edited draft targeted historical library record " .. tostring(id))
        assert(text == "Edited offline draft" and spoilers)
        return { id = id }
      end,
    }, { user_id = 1 })
    assert(waiting == 0 and writes == 1 and lookups == (known_id and 0 or 1))
    assert(m.journal_store:get(1).entries[1].user_book_id == 700, "overlay changed the saved history")
  end
end)

check("editing your review goes through the review form and shows on each entry of the book", function()
  local m = savedTab()
  tab.select_cb(find("reviewed:4005"))
  button(last("text"), "Edit").callback()
  local input = last("input")
  assert(input.input == "Fine", "the form should start with the review")
  input.typed = "Wonderful after all"
  button(input, "Next").callback()
  local picker = last("picker")
  picker.rows[2].callback() -- has spoilers
  local waiting = m.review_queue:get(900)
  assert(waiting and waiting.text == "Wonderful after all" and waiting.spoilers == true)
  for _, key in ipairs({ "reviewed:4003", "reviewed:4005" }) do
    local shown = find(key)
    assert(shown and shown.waiting and shown.text == "Wonderful after all" and shown.spoilers == true, key)
  end
end)

check("once Hardcover has a change, the saved copy shows it", function()
  local m = savedTab()
  m:journalChangeSent({ action = "update", event = "note", journal_id = 4001, text = "Sent words" })
  m:journalChangeSent({ action = "delete", event = "quote", journal_id = 4002 })
  m:journalChangeSent({ event = "note", book_id = 5, text = "a new one is fetched, not patched" })
  local entries = m.journal_store:get(1).entries
  assert(#entries == 4, "kept " .. #entries)
  assert(entries[1].key == "note:4001" and entries[1].text == "Sent words" and entries[1].excerpt == "Sent words")
  m:reviewChangeSent(900, "Changed review", true)
  entries = m.journal_store:get(1).entries
  assert(entries[2].text == "Changed review" and entries[2].spoilers == true and entries[4].text == "Changed review")
  m:reviewChangeSent(900, nil)
  entries = m.journal_store:get(1).entries
  assert(#entries == 4, "a removed review keeps its entries")
  assert(entries[2].key == "reviewed:4003" and entries[2].text == nil and entries[2].spoilers == nil and entries[4].text == nil)
  assert(m:reviewChangeSent(901, "not listed") == nil and #m.journal_store:get(1).entries == 4)
end)

r.finish()
