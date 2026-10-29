-- Notes and quotes written for a book: kept until Hardcover has them.
--
-- Run with:  lua spec/journal_queue_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local JournalQueue = require("hardcover/lib/journal_queue")

local results = { passed = 0, failed = 0 }
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then results.passed = results.passed + 1 print("  [ok  ] " .. name)
  else results.failed = results.failed + 1 print("  [FAIL] " .. name .. "\n         " .. tostring(err)) end
end
local function eq(a, b, label)
  if a ~= b then error((label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local function newQueue()
  local store = {}
  local settings = {
    store = store,
    readSetting = function(_, k) return store[k] end,
    saveSetting = function(_, k, v) store[k] = v return true end,
    flush = function() return true end,
  }
  return JournalQueue:new { settings = settings }, settings
end

local function note(extra)
  local entry = { user_id = 7, book_id = 55, edition_id = 600, event = "note", text = "a thought",
    privacy_setting_id = 3, title = "Dune" }
  for k, v in pairs(extra or {}) do entry[k] = v end
  return entry
end

-- answers each createJournalEntry from `answers` in turn: an entry, or nil and the reason
local function fakeApi(answers)
  local api = { sent = {}, calls = 0 }
  function api:createJournalEntry(object)
    self.calls = self.calls + 1
    local answer = answers and answers[self.calls] or { { id = 1000 + self.calls } }
    if answer[1] then self.sent[#self.sent + 1] = object end
    return answer[1], answer[2]
  end
  return api
end

local refused = { status = 200, errors = { { message = "nope" } } }

check("an entry is kept, in the order it was written", function()
  local q = newQueue()
  q:queue(note { text = "first" })
  q:queue(note { text = "second" })
  q:queue(note { text = "third", book_id = 56 })
  eq(q:count(), 3)
  local list = q:list()
  eq(list[1].text, "first"); eq(list[2].text, "second"); eq(list[3].text, "third")
end)

check("two notes on one book stay two notes", function()
  local q = newQueue()
  eq(q:queue(note()) ~= q:queue(note()), true)
  eq(q:count(), 2)
end)

check("something that is not an entry is refused", function()
  local q = newQueue()
  eq(q:queue(nil), nil)
  eq(q:queue({ event = "note", text = "no book" }), nil)
  eq(q:queue(note { event = "review" }), nil)
  eq(q:count(), 0)
end)

check("the request has the page, the tags and the privacy", function()
  local o = JournalQueue.object(note {
    event = "quote", text = "so it goes", page = 12, pages = 400, tags = { "war" }, hidden_tags = { "ending" },
  }, nil)
  eq(o.book_id, 55); eq(o.event, "quote"); eq(o.entry, "so it goes"); eq(o.edition_id, 600)
  eq(o.privacy_setting_id, 3)
  eq(o.metadata.position.type, "pages"); eq(o.metadata.position.value, 12); eq(o.metadata.position.possible, 400)
  eq(#o.tags, 2)
  eq(o.tags[1].tag, "war"); eq(o.tags[1].spoiler, false); eq(o.tags[1].category, "Tag")
  eq(o.tags[2].tag, "ending"); eq(o.tags[2].spoiler, true)
end)

check("no page means no position, and no tags are an empty list made by KOReader's json", function()
  local made = 0
  local json = { util = { InitArray = function(t) made = made + 1 return t end } }
  local o = JournalQueue.object(note(), json)
  eq(o.metadata, nil)
  eq(#o.tags, 0)
  eq(made, 1)
end)

check("the form's strings are cleaned: blanks and non-strings are dropped", function()
  local q = newQueue()
  q:queue(note { tags = { "a", "", 5, "b" } })
  eq(#q:list()[1].tags, 2)
end)

check("sending clears what went through, oldest first", function()
  local q = newQueue()
  local api = fakeApi()
  q:queue(note { text = "one" }); q:queue(note { text = "two" })
  local got = {}
  local r = q:flush(api, { user_id = 7, on_sent = function(op) got[#got + 1] = op.text end })
  eq(r.waiting, 0); eq(r.held, 0); eq(r.stopped, false)
  eq(api.sent[1].entry, "one"); eq(api.sent[2].entry, "two")
  eq(got[1], "one"); eq(got[2], "two")
  eq(q:isEmpty(), true)
end)

check("no answer keeps the entry and stops the flush", function()
  local q = newQueue()
  local api = fakeApi({ { nil, nil } })
  q:queue(note { text = "one" }); q:queue(note { text = "two" })
  local r = q:flush(api, { user_id = 7 })
  eq(api.calls, 1)
  eq(r.stopped, true); eq(r.waiting, 2); eq(r.held, 0)
  -- and the text is still there to send next time
  eq(q:list()[1].text, "one")
  local again = q:flush(fakeApi(), { user_id = 7 })
  eq(again.waiting, 0)
end)

check("a refusal is counted, the rest go on, and the third holds it", function()
  local q = newQueue()
  local answers = { { nil, refused }, { { id = 1 } }, { nil, refused }, { { id = 2 } }, { nil, refused }, { { id = 3 } } }
  local api = fakeApi(answers)
  q:queue(note { text = "bad" }); q:queue(note { text = "good1" })
  local r = q:flush(api, { user_id = 7 })
  eq(r.waiting, 1); eq(r.held, 0); eq(r.stopped, false)
  q:queue(note { text = "good2" })
  r = q:flush(api, { user_id = 7 })
  eq(q:list()[1].failures, 2)
  q:queue(note { text = "good3" })
  r = q:flush(api, { user_id = 7 })
  eq(r.waiting, 1); eq(r.held, 1)
  eq(q:list()[1].held, true)
  -- a held entry is not sent again until the user presses Sync
  local api2 = fakeApi()
  q:flush(api2, { user_id = 7 })
  eq(api2.calls, 0)
  q:retryHeld()
  eq(q:list()[1].held, nil)
  eq(q:flush(api2, { user_id = 7 }).waiting, 0)
end)

check("a missing scope holds the entry at once", function()
  local q = newQueue()
  local api = fakeApi({ { nil, { status = 200, errors = { { message = "insufficient scope" } } } } })
  q:queue(note())
  local r = q:flush(api, { user_id = 7 })
  eq(r.held, 1)
  eq(q:list()[1].reason, "scope")
end)

check("an entry written under another account is kept, not sent, and not waited on", function()
  local q = newQueue()
  local api = fakeApi()
  q:queue(note { user_id = 8, text = "somebody else's" })
  q:queue(note { user_id = 7, text = "mine" })
  local r = q:flush(api, { user_id = 7 })
  eq(api.calls, 1); eq(api.sent[1].entry, "mine")
  eq(r.waiting, 0); eq(r.stopped, false)
  eq(q:count(), 1)
  eq(q:list()[1].text, "somebody else's")
end)

check("without a signed-in user nothing is sent", function()
  local q = newQueue()
  local api = fakeApi()
  q:queue(note())
  local r = q:flush(api, {})
  eq(api.calls, 0); eq(r.stopped, true); eq(q:count(), 1)
end)

check("an entry made before anyone was known is sent for whoever is signed in", function()
  local q = newQueue()
  local api = fakeApi()
  q:queue(note { user_id = nil })
  eq(q:flush(api, { user_id = 7 }).waiting, 0)
  eq(api.calls, 1)
end)

check("cancelling one leaves the rest", function()
  local q = newQueue()
  local a = q:queue(note { text = "a" })
  q:queue(note { text = "b" })
  eq(q:cancel(a), true)
  eq(q:cancel(a), false)
  eq(q:count(), 1); eq(q:list()[1].text, "b")
end)

check("a flush while another is out waits for it (each entry is sent once)", function()
  local q = newQueue()
  q:queue(note())
  local inner
  local api = { calls = 0 }
  function api:createJournalEntry()
    self.calls = self.calls + 1
    inner = q:flush(self, { user_id = 7 })
    return { id = 1 }
  end
  q:flush(api, { user_id = 7 })
  eq(api.calls, 1)
  eq(inner.stopped, true)
end)

check("malformed contents do not break it", function()
  local q, settings = newQueue()
  settings.store.journal_ops = { x = 5, y = { book_id = 1 }, ["1-1"] = { id = "1-1", seq = 1, book_id = 3, event = "note", text = "ok" } }
  eq(q:count(), 1)
  eq(q:flush(fakeApi(), { user_id = 7 }).waiting, 0)
  settings.store.journal_ops = "garbage"
  eq(q:count(), 0)
end)

print("\n== changing an entry Hardcover has ==")

local function sent(extra)
  local entry = { user_id = 7, journal_id = 4001, book_id = 55, event = "note", text = "better", title = "Dune" }
  for k, v in pairs(extra or {}) do entry[k] = v end
  return entry
end

-- records every request of the three kinds; each answers { id } unless `fail` says otherwise
local function changeApi(fail)
  local api = { log = {} }
  local function answer(self, kind, ...)
    self.log[#self.log + 1] = { kind, ... }
    local why = fail and fail[#self.log]
    if why then return nil, why end
    return { id = 5000 + #self.log }
  end
  function api:createJournalEntry(object) return answer(self, "create", object.entry) end
  function api:updateJournalEntry(id, text) return answer(self, "update", id, text) end
  function api:deleteJournalEntry(id) return answer(self, "delete", id) end
  return api
end

check("an edit and a delete are kept with the entry's id, and listed with the rest", function()
  local q = newQueue()
  q:queue(note { text = "new one" })
  eq(q:change("update", sent()) ~= nil, true, "an edit is kept")
  eq(q:change("delete", sent { journal_id = 4002, event = "quote", text = nil }) ~= nil, true, "a delete is kept")
  eq(q:count(), 3)
  local list = q:list()
  eq(list[2].action, "update"); eq(list[2].journal_id, 4001); eq(list[2].text, "better")
  eq(list[3].action, "delete"); eq(list[3].journal_id, 4002); eq(list[3].text, nil)
  eq(q:changeFor(4001).id, list[2].id)
  eq(q:changeFor(9999), nil)
end)

check("one waiting change per entry: a newer edit replaces the older, a delete drops the edit", function()
  local q = newQueue()
  q:change("update", sent { text = "first try" })
  q:change("update", sent { text = "second try" })
  eq(q:count(), 1)
  eq(q:changeFor(4001).text, "second try")
  q:change("delete", sent())
  eq(q:count(), 1)
  eq(q:changeFor(4001).action, "delete")
end)

check("what is not a change is refused", function()
  local q = newQueue()
  eq(q:change("rename", sent()), nil, "an unknown action")
  eq(q:change("update", sent { journal_id = "x" }), nil, "no entry id")
  eq(q:change("update", sent { event = "review" }), nil, "not a note or quote")
  eq(q:change("update", sent { text = 5 }), nil, "no text")
  eq(q:count(), 0)
end)

check("an entry not sent yet is edited in place, and a refused one gets another chance", function()
  local q = newQueue()
  local id = q:queue(note { text = "typo" })
  q:ops()[id].held, q:ops()[id].failures = true, 3
  eq(q:editWaiting(id, "fixed"), true)
  eq(q:count(), 1)
  eq(q:list()[1].text, "fixed")
  eq(q:list()[1].held, nil)
  eq(q:editWaiting("nope", "x"), false)
  local change = q:change("update", sent())
  eq(q:editWaiting(change, "x"), false, "a change is replaced with change(), not edited")
end)

check("a flush sends each kind with its own request, oldest first", function()
  local q = newQueue()
  q:queue(note { text = "new one" })
  q:change("update", sent())
  q:change("delete", sent { journal_id = 4002 })
  local api = changeApi()
  local done = {}
  local result = q:flush(api, { user_id = 7, on_sent = function(op) done[#done + 1] = op.action or "create" end })
  eq(result.waiting, 0)
  eq(#api.log, 3)
  eq(api.log[1][1], "create"); eq(api.log[1][2], "new one")
  eq(api.log[2][1], "update"); eq(api.log[2][2], 4001); eq(api.log[2][3], "better")
  eq(api.log[3][1], "delete"); eq(api.log[3][2], 4002)
  eq(table.concat(done, ","), "create,update,delete")
end)

check("a change Hardcover does not answer stays and stops the flush; a refused one is held after three", function()
  local q = newQueue()
  q:change("update", sent())
  local result = q:flush(changeApi({ { completed = false } }), { user_id = 7 })
  eq(result.stopped, true); eq(q:count(), 1)
  for _ = 1, 3 do q:flush(changeApi({ refused }), { user_id = 7 }) end
  eq(q:list()[1].held, true)
  eq(q:flush(changeApi(), { user_id = 7 }).held, 1, "a held change waits for Sync")
end)

check("a change for another account is kept, not sent", function()
  local q = newQueue()
  q:change("delete", sent { user_id = 8 })
  local api = changeApi()
  eq(q:flush(api, { user_id = 7 }).waiting, 0)
  eq(#api.log, 0); eq(q:count(), 1)
end)

check("an entry edited while it was being sent sends the new text next, as a change", function()
  local q = newQueue()
  local id = q:queue(note { text = "first words" })
  local api = changeApi()
  local plain = api.createJournalEntry
  function api:createJournalEntry(object)
    q:editWaiting(id, "second words")
    return plain(self, object)
  end
  q:flush(api, { user_id = 7 })
  eq(q:count(), 1, "the edit is still to go")
  local op = q:list()[1]
  eq(op.action, "update"); eq(op.journal_id, 5001); eq(op.text, "second words")
  q:flush(changeApi(), { user_id = 7 })
  eq(q:count(), 0)
end)

check("an edit made while the older one is on its way is not lost when the older one is answered", function()
  local q = newQueue()
  q:change("update", sent { text = "old" })
  local api = changeApi()
  function api:updateJournalEntry(id, text)
    self.log[#self.log + 1] = { "update", id, text }
    if text == "old" then q:change("update", sent { text = "new" }) end
    return { id = id }
  end
  q:flush(api, { user_id = 7 })
  eq(q:count(), 1, "the newer edit is still waiting")
  eq(q:changeFor(4001).text, "new")
check("a note cancelled while an earlier one is being sent is not sent", function()
  local q = newQueue()
  q:queue(note { text = "first" })
  local second = q:queue(note { text = "second" })
  local api = fakeApi()
  local real = api.createJournalEntry
  function api:createJournalEntry(object)
    if self.calls == 0 then q:cancel(second) end
    return real(self, object)
  end
  q:flush(api, { user_id = 7 })
  eq(api.calls, 1, "only the first went out")
  eq(q:count(), 0)
end)

check("stored changes that are broken are dropped", function()
  local q, settings = newQueue()
  settings.store.journal_ops = {
    ["1-1"] = { id = "1-1", seq = 1, action = "update", event = "note", text = "x" },
    ["1-2"] = { id = "1-2", seq = 2, action = "explode", journal_id = 4, event = "note" },
    ["1-3"] = { id = "1-3", seq = 3, action = "delete", journal_id = 4, event = "note" },
  }
  eq(q:count(), 1)
  eq(q:list()[1].id, "1-3")
end)

print(string.format("\n%d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
