-- List changes made offline: one per book and list, opposite changes cancel, a change is
-- sent once the connection is back (a remove that does not know its row looks it up), and
-- what Hardcover refuses is held.
--
-- Run with:  lua spec/list_queue_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local ListQueue = require("hardcover/lib/list_queue")

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
    readSetting = function(_, k) return store[k] end,
    saveSetting = function(_, k, v) store[k] = v return true end,
    flush = function() return true end,
  }
  return ListQueue:new { settings = settings }
end

-- `script[n]`: what the n-th request gets (see the shelf queue's harness); `book_lists` is
-- what getBookLists answers.
local function fakeApi()
  local api = { calls = {}, script = {}, book_lists = {} }
  local function reply(name, ...)
    api.calls[#api.calls + 1] = { name = name, args = { ... } }
    local step = table.remove(api.script, 1)
    if step == nil then return { id = 800 + #api.calls } end
    if step == false then return nil, nil end
    if type(step) == "table" and step.fail ~= nil then return nil, step.fail end
    return step
  end
  function api:addToList(...) return reply("addToList", ...) end
  function api:removeFromList(...) return reply("removeFromList", ...) end
  function api:getBookLists(...)
    api.calls[#api.calls + 1] = { name = "getBookLists", args = { ... } }
    if api.book_lists == false then return nil, { completed = false } end
    return api.book_lists
  end
  return api
end

print("\n== queueing ==")

check("an add waits, once per book and list", function()
  local q = newQueue()
  eq(q:queueAdd(1, 100, 5, 12, { title = "Obelisk", list_name = "Favourites" }), "queued")
  eq(q:queueAdd(1, 100, 5, 12, {}), "queued")
  eq(q:queueAdd(1, 100, 6, 3, {}), "queued")
  eq(q:count(), 2)
  local op = q:get(5, 100)
  eq(op.kind, "add"); eq(op.position, 12)
end)

check("an add then a remove of the same book on the same list leaves nothing", function()
  local q = newQueue()
  q:queueAdd(1, 100, 5, 12, {})
  eq(q:queueRemove(1, 100, 5, nil, {}), "cancelled")
  eq(q:count(), 0)
end)

check("a remove then an add of the same book (it never left) leaves nothing", function()
  local q = newQueue()
  eq(q:queueRemove(1, 100, 5, 77, {}), "queued")
  eq(q:queueAdd(1, 100, 5, 12, {}), "cancelled")
  eq(q:count(), 0)
end)

check("a remove by its row waits, and so does one that does not know the row", function()
  local q = newQueue()
  q:queueRemove(1, 100, 5, 77, {})
  q:queueRemove(1, 100, 6, nil, {})
  eq(q:get(5, 100).list_book_id, 77); eq(q:get(6, 100).list_book_id, nil)
  eq(#q:list(), 2)
end)

check("cancel removes one change only", function()
  local q = newQueue()
  q:queueAdd(1, 100, 5, 0, {}); q:queueAdd(1, 100, 6, 0, {})
  eq(q:cancel(5, 100), true); eq(q:cancel(5, 100), false)
  eq(q:count(), 1)
end)

print("\n== sending ==")

check("an add and a remove are sent once each, the queue empties, the new row id is reported", function()
  local q, api = newQueue(), fakeApi()
  q:queueAdd(1, 100, 5, 12, {}); q:queueRemove(1, 101, 6, 77, {})
  local sent = {}
  local res = q:flush(api, { user_id = 1, on_sent = function(op, r) sent[#sent + 1] = { op = op, r = r } end })
  eq(res.sent, 2); eq(res.waiting, 0)
  eq(api.calls[1].name, "addToList"); eq(api.calls[1].args[1], 100); eq(api.calls[1].args[2], 5); eq(api.calls[1].args[3], 12)
  eq(api.calls[2].name, "removeFromList"); eq(api.calls[2].args[1], 77)
  eq(sent[1].r.id, 801)
  q:flush(api, { user_id = 1 })
  eq(#api.calls, 2, "sent again")
end)

check("a remove that does not know its row looks it up and removes that row", function()
  local q, api = newQueue(), fakeApi()
  api.book_lists = { { id = 6, on = true, list_book_id = 91 } }
  q:queueRemove(1, 100, 6, nil, {})
  local res = q:flush(api, { user_id = 1 })
  eq(res.sent, 1)
  eq(api.calls[1].name, "getBookLists"); eq(api.calls[2].name, "removeFromList"); eq(api.calls[2].args[1], 91)
end)

check("a remove for a book that is already off the list is done, with nothing removed", function()
  local q, api = newQueue(), fakeApi()
  api.book_lists = { { id = 6, on = false } }
  q:queueRemove(1, 100, 6, nil, {})
  local res = q:flush(api, { user_id = 1 })
  eq(res.sent, 1); eq(#api.calls, 1); eq(q:count(), 0)
end)

check("a failed look-up is retried without counting; no row id in the answer is a refusal", function()
  local q, api = newQueue(), fakeApi()
  q:queueRemove(1, 100, 6, nil, {})
  api.book_lists = false
  local res = q:flush(api, { user_id = 1 })
  eq(res.stopped, true); eq(q:get(6, 100).failures, nil)
  api.book_lists = { { id = 6, on = true } }
  q:flush(api, { user_id = 1 })
  eq(q:get(6, 100).failures, 1)
end)

check("no answer keeps everything and stops", function()
  local q, api = newQueue(), fakeApi()
  q:queueAdd(1, 100, 5, 0, {}); q:queueAdd(1, 100, 6, 0, {})
  api.script = { false }
  local res = q:flush(api, { user_id = 1 })
  eq(res.stopped, true); eq(res.sent, 0); eq(res.waiting, 2); eq(#api.calls, 1)
end)

check("a refusal is counted, the others go on, the third holds it; a scope error holds at once", function()
  local q, api = newQueue(), fakeApi()
  q:queueAdd(1, 100, 5, 0, {})
  for i = 1, 3 do
    api.script = { { fail = "List not found" } }
    q:flush(api, { user_id = 1 })
    eq(q:get(5, 100).failures, i)
  end
  eq(q:get(5, 100).held, true); eq(q:get(5, 100).reason, "refused")
  eq(q:heldCount(), 1)

  q:queueAdd(1, 100, 6, 0, {})
  api.script = { { fail = { status = 403 } } }
  q:flush(api, { user_id = 1 })
  eq(q:get(6, 100).reason, "scope")
  q:retryHeld()
  eq(q:get(6, 100).held, nil)
end)

check("another user's changes are never sent, and are dropped", function()
  local q, api = newQueue(), fakeApi()
  q:queueAdd(2, 100, 5, 0, {}); q:queueAdd(1, 101, 5, 0, {})
  local res = q:flush(api, { user_id = 1 })
  eq(res.sent, 1); eq(api.calls[1].args[1], 101); eq(q:count(), 0)
end)

check("with nobody signed in nothing is sent or dropped", function()
  local q, api = newQueue(), fakeApi()
  q:queueAdd(1, 100, 5, 0, {})
  local res = q:flush(api, {})
  eq(res.stopped, true); eq(#api.calls, 0); eq(q:count(), 1)
end)

check("a raising request is a failed try and releases the lock", function()
  local q, api = newQueue(), fakeApi()
  q:queueAdd(1, 100, 5, 0, {})
  function api:addToList() error("boom") end
  local res = q:flush(api, { user_id = 1 })
  eq(res.stopped, true); eq(q:count(), 1); eq(q.flushing, false)
end)

print(string.format("\n  %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
