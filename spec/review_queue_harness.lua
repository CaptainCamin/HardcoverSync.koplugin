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

print(string.format("\n%d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
