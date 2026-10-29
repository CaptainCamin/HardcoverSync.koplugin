-- Reviews written offline: kept per book, shown at once, sent when online. Also the Slate text
-- Hardcover takes a review as.
--
-- Run with:  lua spec/review_queue_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local ReviewQueue = require("hardcover/lib/review_queue")
local ReviewText = require("hardcover/lib/review_text")

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
  return ReviewQueue:new { settings = settings }, settings
end

-- answers each updateReview in turn: a user book, or nil and the reason
local function fakeApi(answers)
  local api = { sent = {}, calls = 0 }
  function api:updateReview(id, text, spoilers)
    self.calls = self.calls + 1
    if self.fail then return nil end
    local answer = answers and answers[self.calls] or { { id = id, has_review = text ~= "" } }
    if answer[1] then self.sent[#self.sent + 1] = { id = id, text = text, spoilers = spoilers } end
    return answer[1], answer[2]
  end
  return api
end
local refused = { status = 200, errors = { { message = "nope" } } }

print("\n== the text ==")

check("a review is one paragraph for each line", function()
  local doc = ReviewText.slate("first line\nsecond line\n\nafter a gap").document
  eq(doc.object, "document")
  eq(#doc.children, 4)
  eq(doc.children[1].type, "paragraph")
  eq(doc.children[1].children[1].text, "first line")
  eq(doc.children[3].children[1].text, "")
  eq(doc.children[4].children[1].text, "after a gap")
  eq(doc.children[2].children[1].object, "text")
end)

check("no text is one empty paragraph, which is how a review is cleared", function()
  for _, text in ipairs({ "", "  \n ", nil }) do
    local doc = ReviewText.slate(text).document
    eq(#doc.children, 1)
    eq(doc.children[1].children[1].text, "")
  end
end)

check("line ends of any platform, and the edges, are cleaned", function()
  eq(ReviewText.clean("  one\r\ntwo\rthree \n\n"), "one\ntwo\nthree")
  eq(ReviewText.clean(nil), "")
end)

check("the lists inside the document are made by KOReader's json, so they go out as []", function()
  local made = 0
  local json = { util = { InitArray = function(t) made = made + 1 return t end } }
  ReviewText.slate("a\nb", json)
  -- the children, and the children and marks of each of the two paragraphs
  eq(made, 1 + 2 * 2)
end)

print("\n== the queue ==")

check("a review waits, and writing again leaves the newest", function()
  local q = newQueue()
  q:queue(7, "first", false, "Dune")
  q:queue(7, "second", true, "Dune")
  eq(q:count(), 1)
  eq(q:get(7).text, "second"); eq(q:get(7).spoilers, true)
  eq(q:get(8), nil)
end)

check("empty text is kept as a clear", function()
  local q = newQueue()
  q:queue(7, "", false)
  eq(q:get(7).text, "", "text"); eq(q:count(), 1)
end)

check("sending clears what went through, with the spoiler flag", function()
  local q = newQueue()
  local api = fakeApi()
  q:queue(7, "good", true); q:queue(9, "fine", false)
  local got = {}
  eq(q:flush(api, { on_sent = function(id) got[#got + 1] = id end }), 0)
  eq(#api.sent, 2); eq(api.sent[1].text, "good"); eq(api.sent[1].spoilers, true); eq(api.sent[2].spoilers, false)
  eq(#got, 2); eq(q:isEmpty(), true)
end)

check("no answer keeps the review and stops the flush", function()
  local q = newQueue()
  local api = fakeApi({ { nil, nil } })
  q:queue(7, "a", false); q:queue(9, "b", false)
  eq(q:flush(api), 2)
  eq(api.calls, 1)
  eq(q:get(7).text, "a")
end)

check("a refusal is counted, the rest go on, and the third holds it", function()
  local q = newQueue()
  local api = fakeApi({ { nil, refused }, { { id = 9 } }, { nil, refused }, { nil, refused } })
  q:queue(7, "bad", false); q:queue(9, "good", false)
  eq(q:flush(api), 1)
  eq(q:list()[1].failures, nil, "list does not leak counters")
  q:flush(api); q:flush(api)
  eq(q:list()[1].held, true)
  local api2 = fakeApi()
  eq(q:flush(api2), 1); eq(api2.calls, 0)
  q:retryHeld()
  eq(q:flush(api2), 0)
end)

check("a review written while its send was out stays", function()
  local q = newQueue()
  q:queue(7, "old", false)
  local api = { calls = 0 }
  function api:updateReview()
    self.calls = self.calls + 1
    q:queue(7, "newer", false)
    return { id = 7 }
  end
  q:flush(api)
  eq(q:get(7).text, "newer")
end)

check("cancel removes just that one; junk does not break it", function()
  local q, settings = newQueue()
  q:queue(7, "a", false); q:queue(9, "b", false)
  eq(q:cancel(7), true); eq(q:cancel(7), false)
  eq(q:count(), 1)
  settings.store.review_ops = { x = 5, ["7"] = { user_book_id = 7, text = "ok" }, ["8"] = { user_book_id = 8 } }
  eq(q:count(), 1)
  settings.store.review_ops = "garbage"
  eq(q:count(), 0)
end)

-- Catalog 101 and library record 907 deliberately differ: never write to 101.
local function deferredApi(user_id, library_id)
  user_id, library_id = user_id or 42, library_id or 907
  local api = fakeApi()
  api.lookups, api.found = 0, { id = library_id }
  function api:findUserBook(book_id, author_id)
    eq(book_id, 101, "lookup catalog ID"); eq(author_id, user_id, "lookup user")
    self.lookups = self.lookups + 1
    if self.on_lookup then self.on_lookup() end
    self.resolved = type(self.found) == "table" and self.found.id ~= nil
    return self.found, self.lookup_error
  end
  local update = api.updateReview
  function api:updateReview(id, text, spoilers, json)
    eq(self.resolved, true, "no write before resolution"); eq(id, library_id, "write library ID")
    eq(json, self.json, "json forwarded unchanged")
    if self.on_send then self.on_send() end
    return update(self, id, text, spoilers)
  end
  function api:updateUserBook() error("review queue must not create a shelf record") end
  return api
end

check("catalog reviews persist, coalesce with a known ID, and cancel only that book", function()
  local q, settings = newQueue()
  q:queue(nil, "first", false, "Dune", 101, 42); q:queue(nil, "other", false, "Other", 202, 42)
  q = ReviewQueue:new { settings = settings }
  eq(q:count(), 2); eq(q:get(nil, 101, 42).text, "first"); eq(q:get(nil, 202, 42).text, "other")
  q:queue(907, "newest", true, "Dune", 101, 42)
  q = ReviewQueue:new { settings = settings }
  eq(q:count(), 2, "transition replaces, not duplicates")
  eq(q:get(907, 101, 42).text, "newest"); eq(q:get(nil, 101, 42).spoilers, true)
  local dune
  for _, op in ipairs(q:list(42)) do if op.book_id == 101 then dune = op end end
  assert(dune, "list exposes catalog ID")
  eq(dune.user_book_id, 907); eq(dune.title, "Dune"); eq(dune.text, "newest"); eq(dune.spoilers, true)
  eq(q:cancel(nil, 101, 42), true); eq(q:cancel(907, 101, 42), false)
  eq(q:count(), 1); eq(q:get(nil, 202, 42).text, "other")
  eq(q:cancel(nil, 202, 42), true); eq(q:isEmpty(), true)
end)

check("deferred reviews and clears resolve first, preserving spoilers and flush options", function()
  for _, edit in ipairs({ { text = "the ending", spoilers = true }, { text = "", spoilers = false } }) do
    local q, settings = newQueue()
    q:queue(nil, "old", false, "Dune", 101, 42)
    q:queue(nil, edit.text, edit.spoilers, "Dune", 101, 42)
    q = ReviewQueue:new { settings = settings }
    eq(q:get(nil, 101, 42).text, edit.text); eq(q:list(42)[1].book_id, 101)
    local api, callbacks = deferredApi(), 0
    api.json = { util = {} }
    eq(#api.sent, 0)
    eq(q:flush(api, { user_id = 42, json = api.json, on_sent = function(id, book)
      callbacks = callbacks + 1; eq(id, 907); eq(book.id, 907)
    end }), 0)
    eq(api.lookups, 1); eq(#api.sent, 1)
    eq(api.sent[1].text, edit.text); eq(api.sent[1].spoilers, edit.spoilers)
    eq(callbacks, 1); eq(q:isEmpty(), true)
  end
end)

check("missing records and unanswered lookups wait without rejection or writes", function()
  -- The real API returns nil for no record, but {} plus an error for no answer.
  for _, answer in ipairs({ {}, { found = {}, err = { error = "no_response", completed = false } } }) do
    local q = newQueue()
    q:queue(nil, "waiting", true, "Dune", 101, 42)
    local api, callbacks = deferredApi(), 0
    api.found, api.lookup_error = answer.found, answer.err
    for _ = 1, 4 do
      eq(q:flush(api, { user_id = 42, on_sent = function() callbacks = callbacks + 1 end }), 1)
    end
    eq(api.lookups, 4); eq(#api.sent, 0); eq(callbacks, 0)
    eq(q:get(nil, 101, 42).text, "waiting"); eq(q:get(nil, 101, 42).spoilers, true); eq(q:heldCount(), 0)
    for _, op in pairs(q:ops()) do
      eq(op.failures or 0, 0, "not a rejection"); eq(op.reason, nil)
    end
  end
end)

check("lookup refusals use the existing hold and retry rules", function()
  for _, refusal in ipairs({
    { err = refused, tries = 3, reason = "refused" },
    { err = { status = 403, errors = { { message = "insufficient_scope" } } }, tries = 1, reason = "scope" },
  }) do
    local q = newQueue()
    q:queue(nil, "waiting", false, "Dune", 101, 42)
    local api = deferredApi()
    api.found, api.lookup_error = {}, refusal.err
    for _ = 1, refusal.tries do eq(q:flush(api, { user_id = 42 }), 1) end
    eq(q:heldCount(), 1); eq(q:list(42)[1].reason, refusal.reason)
    eq(q:flush(api, { user_id = 42 }), 1); eq(api.lookups, refusal.tries); eq(#api.sent, 0)
    q:retryHeld()
    api.found, api.lookup_error = { id = 907 }, nil
    eq(q:flush(api, { user_id = 42 }), 0); eq(api.lookups, refusal.tries + 1); eq(#api.sent, 1)
  end
end)

check("a newer catalog edit during lookup or send survives the old flush", function()
  for _, phase in ipairs({ "on_lookup", "on_send" }) do
    local q, settings = newQueue()
    q:queue(nil, "old", false, "Dune", 101, 42)
    local api = deferredApi()
    api[phase] = function() q:queue(907, "newer", true, "Dune", 101, 42) end
    eq(q:flush(api, { user_id = 42 }), 1)
    eq(#api.sent, phase == "on_lookup" and 0 or 1, "replacement before send prevents stale mutation")
    q = ReviewQueue:new { settings = settings }
    eq(q:count(), 1, phase); eq(q:get(907, 101, 42).text, "newer", phase)
    eq(q:get(907, 101, 42).spoilers, true, phase)
    api[phase] = nil
    eq(q:flush(api, { user_id = 42 }), 0)
    eq(api.sent[#api.sent].id, 907); eq(api.sent[#api.sent].text, "newer")
    eq(api.sent[#api.sent].spoilers, true)
  end
end)

check("accounts independently edit, cancel, list and flush the same catalog review", function()
  for _, known in ipairs({ false, true }) do
    local q, settings = newQueue()
    local a, b = known and 907 or nil, known and 1907 or nil
    q:queue(a, "A first", false, "Dune", 101, 42)
    eq(q:get(a, 101, 84), nil); eq(q:cancel(a, 101, 84), false); eq(#q:list(84), 0)
    local api = deferredApi(84, 1907)
    q:flush(api) -- No signed-in account must not send owned changes either.
    eq(q:flush(api, { user_id = 84 }), 0, "A is not part of B's waiting count")
    eq(api.lookups, 0); eq(#api.sent, 0); eq(q:count(), 1)

    q:queue(b, "B first", false, "Dune", 101, 84)
    q:queue(a, "A edit", true, "Dune", 101, 42); q:queue(b, "B edit", false, "Dune", 101, 84)
    eq(q:count(), 2); eq(q:get(a, 101, 42).text, "A edit"); eq(q:get(b, 101, 84).text, "B edit")
    eq(#q:list(42), 1); eq(q:list(42)[1].text, "A edit"); eq(q:list(42)[1].spoilers, true)
    eq(#q:list(84), 1); eq(q:list(84)[1].text, "B edit"); eq(q:list(84)[1].spoilers, false)
    eq(q:cancel(b, 101, 84), true); eq(q:cancel(a, 101, 84), false)
    eq(q:get(a, 101, 42).text, "A edit"); eq(q:count(), 1)
    q:queue(b, "B final", false, "Dune", 101, 84)
    q = ReviewQueue:new { settings = settings }

    -- Leave B waiting once, to prove both nonzero and zero results exclude A.
    api.resolved, api.fail, api.found = known, known, nil
    eq(q:flush(api, { user_id = 84 }), 1); eq(#api.sent, 0)
    eq(api.lookups, known and 0 or 1); eq(q:get(a, 101, 42).text, "A edit")
    api.fail, api.found = false, { id = 1907 }
    eq(q:flush(api, { user_id = 84 }), 0); eq(#api.sent, 1)
    eq(api.sent[1].id, 1907); eq(api.sent[1].text, "B final"); eq(api.sent[1].spoilers, false)
    eq(#q:list(84), 0); eq(#q:list(42), 1)
    q = ReviewQueue:new { settings = settings }
    eq(q:get(a, 101, 42).text, "A edit", "A survived B's session and reinstantiation")
    local returning = deferredApi()
    returning.resolved = known
    eq(q:flush(returning, { user_id = 42 }), 0)
    eq(#returning.sent, 1); eq(returning.sent[1].id, 907); eq(returning.sent[1].text, "A edit")
    eq(returning.sent[1].spoilers, true); eq(q:isEmpty(), true)
  end
end)

check("cancel during lookup prevents the old review mutation and preserves another author", function()
  local q, settings = newQueue()
  q:queue(nil, "A", true, "Dune", 101, 42); q:queue(nil, "B", false, "Dune", 101, 84)
  local api, callbacks = deferredApi(), 0
  api.on_lookup = function() eq(q:cancel(nil, 101, 42), true) end
  eq(q:flush(api, { user_id = 42, on_sent = function() callbacks = callbacks + 1 end }), 0)
  eq(api.lookups, 1); eq(#api.sent, 0); eq(callbacks, 0)
  q = ReviewQueue:new { settings = settings }
  eq(q:get(nil, 101, 42), nil); eq(q:get(nil, 101, 84).text, "B"); eq(q:count(), 1)
end)

check("ownerless catalog reviews persist but never bind to the next account", function()
  local q, settings = newQueue()
  q:queue(nil, "unknown author's text", true, "Dune", 101) -- Deliberately no author.
  local api = deferredApi()
  q:flush(api); q:flush(api, { user_id = 42 }); q:flush(api, { user_id = 84 })
  eq(api.lookups, 0); eq(#api.sent, 0)
  q = ReviewQueue:new { settings = settings }
  eq(q:count(), 1); eq(q:get(nil, 101).text, "unknown author's text"); eq(q:get(nil, 101).spoilers, true)
  eq(q:list()[1].user_book_id, nil); eq(q:heldCount(), 0)
end)

check("old persisted library-only reviews still send without a lookup", function()
  local _, settings = newQueue()
  settings.store.review_ops = { ["907"] = { user_book_id = 907, text = "saved", spoilers = true } }
  local q, api = ReviewQueue:new { settings = settings }, fakeApi()
  eq(q:get(907).text, "saved"); eq(q:flush(api), 0)
  eq(#api.sent, 1); eq(api.sent[1].id, 907); eq(api.sent[1].text, "saved")
  eq(api.sent[1].spoilers, true)
end)

print(string.format("\n%d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
