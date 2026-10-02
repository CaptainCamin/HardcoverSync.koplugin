-- Ratings set offline: kept per book, shown at once, sent when online.
--
-- Run with:  lua spec/rating_queue_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local RatingQueue = require("hardcover/lib/rating_queue")

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
  return RatingQueue:new { settings = settings }, settings
end

local function fakeApi()
  local api = { sent = {}, fail = false }
  function api:updateRating(id, rating)
    if self.fail then return nil end
    self.sent[#self.sent + 1] = { id = id, rating = rating }
    return { id = id, rating = rating, status_id = 3 }
  end
  return api
end

check("a rating waits, and rating again leaves the newest", function()
  local q = newQueue()
  q:queue(7, 3)
  q:queue(7, 4.5)
  eq(q:count(), 1)
  eq(q:get(7), 4.5)
  eq(q:get(8), nil)
end)

check("a clear (0) is kept as a rating of 0", function()
  local q = newQueue()
  q:queue(7, 0)
  eq(q:get(7), 0)
end)

check("sending clears what went through", function()
  local q = newQueue()
  local api = fakeApi()
  q:queue(7, 4); q:queue(9, 2.5)
  local got = {}
  eq(q:flush(api, function(id) got[#got + 1] = id end), 0)
  eq(#api.sent, 2); eq(q:isEmpty(), true)
  eq(#got, 2)
end)

check("no answer keeps the rating for next time", function()
  local q = newQueue()
  local api = fakeApi()
  api.fail = true
  q:queue(7, 4)
  eq(q:flush(api), 1)
  eq(q:get(7), 4)
end)

check("malformed contents do not break it", function()
  local q, settings = newQueue()
  settings.store.rating_ops = { x = 5, ["7"] = { user_book_id = 7, rating = 3 } }
  eq(q:count(), 1)
  settings.store.rating_ops = "garbage"
  eq(q:count(), 0)
end)

print(string.format("\n%d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
