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
  local update = api.updateRating
  function api:updateRating(id, rating)
    eq(self.resolved, true, "no write before resolution"); eq(id, library_id, "write library ID")
    if self.on_send then self.on_send() end
    return update(self, id, rating)
  end
  function api:updateUserBook() error("rating queue must not create a shelf record") end
  return api
end

check("catalog ratings persist, coalesce with a known ID, and cancel only that book", function()
  local q, settings = newQueue()
  q:queue(nil, 2, "Dune", 101, 42); q:queue(nil, 3, "Other", 202, 42)
  q = RatingQueue:new { settings = settings }
  eq(q:count(), 2); eq(q:get(nil, 101, 42), 2); eq(q:get(nil, 202, 42), 3)
  q:queue(907, 4.5, "Dune", 101, 42)
  q = RatingQueue:new { settings = settings }
  eq(q:count(), 2, "transition replaces, not duplicates")
  eq(q:get(907, 101, 42), 4.5); eq(q:get(nil, 101, 42), 4.5)
  local dune
  for _, op in ipairs(q:list(42)) do if op.book_id == 101 then dune = op end end
  assert(dune, "list exposes catalog ID")
  eq(dune.user_book_id, 907); eq(dune.title, "Dune"); eq(dune.rating, 4.5)
  eq(q:cancel(nil, 101, 42), true); eq(q:cancel(907, 101, 42), false)
  eq(q:count(), 1); eq(q:get(nil, 202, 42), 3)
  eq(q:cancel(nil, 202, 42), true); eq(q:isEmpty(), true)
end)

check("a deferred clear resolves first, sends 0, and reports the library ID", function()
  local q, settings = newQueue()
  q:queue(nil, 4, "Dune", 101, 42); q:queue(nil, 0, "Dune", 101, 42)
  q = RatingQueue:new { settings = settings }
  eq(q:get(nil, 101, 42), 0); eq(q:list(42)[1].book_id, 101)
  local api, callbacks = deferredApi(), 0
  eq(#api.sent, 0)
  eq(q:flush(api, function(id, book)
    callbacks = callbacks + 1; eq(id, 907); eq(book.id, 907)
  end, 42), 0)
  eq(api.lookups, 1); eq(#api.sent, 1); eq(api.sent[1].rating, 0)
  eq(callbacks, 1); eq(q:isEmpty(), true)
end)

check("missing records and unanswered lookups wait without rejection or writes", function()
  -- The real API returns nil for no record, but {} plus an error for no answer.
  for _, answer in ipairs({ {}, { found = {}, err = { error = "no_response", completed = false } } }) do
    local q = newQueue()
    q:queue(nil, 4, "Dune", 101, 42)
    local api, callbacks = deferredApi(), 0
    api.found, api.lookup_error = answer.found, answer.err
    for _ = 1, 4 do
      eq(q:flush(api, function() callbacks = callbacks + 1 end, 42), 1)
    end
    eq(api.lookups, 4); eq(#api.sent, 0); eq(callbacks, 0)
    eq(q:get(nil, 101, 42), 4); eq(q:heldCount(), 0)
    for _, op in pairs(q:ops()) do
      eq(op.failures or 0, 0, "not a rejection"); eq(op.reason, nil)
    end
  end
end)

check("lookup refusals use the existing hold and retry rules", function()
  for _, refusal in ipairs({
    { err = { status = 200, errors = { { message = "nope" } } }, tries = 3, reason = "refused" },
    { err = { status = 403, errors = { { message = "insufficient_scope" } } }, tries = 1, reason = "scope" },
  }) do
    local q = newQueue()
    q:queue(nil, 4, "Dune", 101, 42)
    local api = deferredApi()
    api.found, api.lookup_error = {}, refusal.err
    for _ = 1, refusal.tries do eq(q:flush(api, nil, 42), 1) end
    eq(q:heldCount(), 1); eq(q:list(42)[1].reason, refusal.reason)
    eq(q:flush(api, nil, 42), 1); eq(api.lookups, refusal.tries); eq(#api.sent, 0)
    q:retryHeld()
    api.found, api.lookup_error = { id = 907 }, nil
    eq(q:flush(api, nil, 42), 0); eq(api.lookups, refusal.tries + 1); eq(#api.sent, 1)
  end
end)

check("a newer catalog edit during lookup or send survives the old flush", function()
  for _, phase in ipairs({ "on_lookup", "on_send" }) do
    local q, settings = newQueue()
    q:queue(nil, 2, "Dune", 101, 42)
    local api = deferredApi()
    api[phase] = function() q:queue(907, 4.5, "Dune", 101, 42) end
    eq(q:flush(api, nil, 42), 1)
    eq(#api.sent, phase == "on_lookup" and 0 or 1, "replacement before send prevents stale mutation")
    q = RatingQueue:new { settings = settings }
    eq(q:count(), 1, phase); eq(q:get(907, 101, 42), 4.5, phase)
    api[phase] = nil
    eq(q:flush(api, nil, 42), 0)
    eq(api.sent[#api.sent].id, 907); eq(api.sent[#api.sent].rating, 4.5)
  end
end)

check("accounts independently edit, cancel, list and flush the same catalog rating", function()
  for _, known in ipairs({ false, true }) do
    local q, settings = newQueue()
    local a, b = known and 907 or nil, known and 1907 or nil
    q:queue(a, 2, "Dune", 101, 42)
    eq(q:get(a, 101, 84), nil); eq(q:cancel(a, 101, 84), false); eq(#q:list(84), 0)
    local api = deferredApi(84, 1907)
    q:flush(api) -- No signed-in account must not send owned changes either.
    eq(q:flush(api, nil, 84), 0, "A is not part of B's waiting count")
    eq(api.lookups, 0); eq(#api.sent, 0); eq(q:count(), 1)

    q:queue(b, 3, "Dune", 101, 84)
    q:queue(a, 4, "Dune", 101, 42); q:queue(b, 4.5, "Dune", 101, 84)
    eq(q:count(), 2); eq(q:get(a, 101, 42), 4); eq(q:get(b, 101, 84), 4.5)
    eq(#q:list(42), 1); eq(q:list(42)[1].rating, 4)
    eq(#q:list(84), 1); eq(q:list(84)[1].rating, 4.5)
    eq(q:cancel(b, 101, 84), true); eq(q:cancel(a, 101, 84), false)
    eq(q:get(a, 101, 42), 4); eq(q:count(), 1)
    q:queue(b, 3, "Dune", 101, 84)
    q = RatingQueue:new { settings = settings }

    -- Leave B waiting once, to prove both nonzero and zero results exclude A.
    api.resolved, api.fail, api.found = known, known, nil
    eq(q:flush(api, nil, 84), 1); eq(#api.sent, 0)
    eq(api.lookups, known and 0 or 1); eq(q:get(a, 101, 42), 4)
    api.fail, api.found = false, { id = 1907 }
    eq(q:flush(api, nil, 84), 0); eq(#api.sent, 1)
    eq(api.sent[1].id, 1907); eq(api.sent[1].rating, 3)
    eq(#q:list(84), 0); eq(#q:list(42), 1)
    q = RatingQueue:new { settings = settings }
    eq(q:get(a, 101, 42), 4, "A survived B's session and reinstantiation")
    local returning = deferredApi()
    returning.resolved = known
    eq(q:flush(returning, nil, 42), 0)
    eq(#returning.sent, 1); eq(returning.sent[1].id, 907); eq(returning.sent[1].rating, 4)
    eq(q:isEmpty(), true)
  end
end)

check("cancel during lookup prevents the old rating mutation and preserves another author", function()
  local q, settings = newQueue()
  q:queue(nil, 2, "Dune", 101, 42); q:queue(nil, 3, "Dune", 101, 84)
  local api, callbacks = deferredApi(), 0
  api.on_lookup = function() eq(q:cancel(nil, 101, 42), true) end
  eq(q:flush(api, function() callbacks = callbacks + 1 end, 42), 0)
  eq(api.lookups, 1); eq(#api.sent, 0); eq(callbacks, 0)
  q = RatingQueue:new { settings = settings }
  eq(q:get(nil, 101, 42), nil); eq(q:get(nil, 101, 84), 3); eq(q:count(), 1)
end)

check("ownerless catalog ratings persist but never bind to the next account", function()
  local q, settings = newQueue()
  q:queue(nil, 4, "Dune", 101) -- Deliberately no author, unlike new deferred edits.
  local api = deferredApi()
  q:flush(api); q:flush(api, nil, 42); q:flush(api, nil, 84)
  eq(api.lookups, 0); eq(#api.sent, 0)
  q = RatingQueue:new { settings = settings }
  eq(q:count(), 1); eq(q:get(nil, 101), 4)
  eq(q:list()[1].user_book_id, nil); eq(q:heldCount(), 0)
end)

check("old persisted library-only ratings still send without a lookup", function()
  local _, settings = newQueue()
  settings.store.rating_ops = { ["907"] = { user_book_id = 907, rating = 3 } }
  local q, api = RatingQueue:new { settings = settings }, fakeApi()
  eq(q:get(907), 3); eq(q:flush(api), 0)
  eq(#api.sent, 1); eq(api.sent[1].id, 907); eq(api.sent[1].rating, 3)
end)

print(string.format("\n%d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
