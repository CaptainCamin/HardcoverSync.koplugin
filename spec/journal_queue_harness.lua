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

print(string.format("\n%d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
