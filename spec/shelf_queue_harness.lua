-- Shelf changes made offline: one per book, the newest wins, opposite changes cancel, a
-- change is sent once the connection is back, and what Hardcover refuses is held.
--
-- Run with:  lua spec/shelf_queue_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local ShelfQueue = require("hardcover/lib/shelf_queue")
local BookActions = require("hardcover/lib/book_actions")

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
  return ShelfQueue:new { settings = settings }
end

-- A recording API. `answers[n]` is what the n-th request gets: nil and an error, or a result.
local function fakeApi()
  local api = { calls = {}, script = {} }
  local function reply(name, ...)
    api.calls[#api.calls + 1] = { name = name, args = { ... } }
    local step = table.remove(api.script, 1)
    if step == nil then return { id = 900 + #api.calls } end
    if step == false then return nil, nil end
    if type(step) == "table" and step.fail ~= nil then return nil, step.fail end
    return step
  end
  function api:updateUserBook(...) return reply("updateUserBook", ...) end
  function api:removeUserBook(...) return reply("removeUserBook", ...) end
  return api
end

print("\n== queueing ==")

check("a change waits, and a second one for the same book leaves the newest", function()
  local q = newQueue()
  q:queueStatus(1, 100, 1, { title = "Obelisk", edition_id = 7, from_status_id = nil })
  q:queueStatus(1, 100, 3, {})
  eq(q:count(), 1)
  local op = q:get(100)
  eq(op.status_id, 3)
  eq(op.edition_id, 7, "the edition of a book new to the library is kept")
  eq(op.title, "Obelisk")
end)

check("the shelf the book started on survives later changes", function()
  local q = newQueue()
  q:queueStatus(1, 100, 3, { user_book_id = 55, from_status_id = 1 })
  q:queueStatus(1, 100, 2, { user_book_id = 55, from_status_id = 3 })
  eq(q:get(100).from_status_id, 1)
end)

check("removing a book that only went on a shelf offline leaves nothing to send", function()
  local q = newQueue()
  q:queueStatus(1, 100, 1, {})
  eq(q:queueRemove(1, 100, nil, "Obelisk"), "dropped")
  eq(q:count(), 0)
end)

check("removing a book with nothing waiting and no record sends nothing either", function()
  local q = newQueue()
  eq(q:queueRemove(1, 100, nil), "dropped")
  eq(q:count(), 0)
end)

check("removing a book in the library waits as a remove, by its record", function()
  local q = newQueue()
  eq(q:queueRemove(1, 100, 55, "Obelisk", 2), "queued")
  local op = q:get(100)
  eq(op.kind, "remove"); eq(op.user_book_id, 55); eq(op.from_status_id, 2)
end)

check("a new shelf after a waiting remove becomes a status change on the same record", function()
  local q = newQueue()
  q:queueRemove(1, 100, 55, "Obelisk", 2)
  q:queueStatus(1, 100, 3, { edition_id = 7 }) -- the details screen sees a book new to the library
  local op = q:get(100)
  eq(op.kind, "status"); eq(op.status_id, 3)
  eq(op.user_book_id, 55, "the record, so its history is not deleted")
  eq(op.edition_id, nil, "the edition is not switched")
  eq(op.from_status_id, 2)
end)

check("a status change over a waiting status change on a shelved book keeps its record", function()
  local q = newQueue()
  q:queueStatus(1, 100, 3, { user_book_id = 55 })
  q:queueStatus(1, 100, 2, {})
  eq(q:get(100).user_book_id, 55)
end)

check("cancel removes one book's change", function()
  local q = newQueue()
  q:queueStatus(1, 100, 1, {}); q:queueStatus(1, 101, 1, {})
  eq(q:cancel(100), true); eq(q:cancel(100), false)
  eq(q:count(), 1)
end)

check("junk in the file is not counted and does not break the list", function()
  local q = newQueue()
  q:ops()["x"] = "junk"
  q:ops()["5"] = { book_id = 5, kind = "status" } -- no status
  q:queueStatus(1, 100, 1, {})
  eq(q:count(), 1); eq(#q:list(), 1)
end)

print("\n== the details screen ==")

check("a waiting status shows in place of the one on record", function()
  local d = BookActions.withPendingShelf({ status_id = 1, user_book_id = 55, user_rating = 4 },
    { kind = "status", status_id = 3, user_book_id = 55 })
  eq(d.status_id, 3); eq(d.user_book_id, 55); eq(d.user_rating, 4)
end)

check("a waiting removal shows the book as not in the library", function()
  local d = BookActions.withPendingShelf({ status_id = 1, user_book_id = 55, user_rating = 4 }, { kind = "remove" })
  eq(d.status_id, nil); eq(d.user_book_id, nil); eq(d.user_rating, nil)
end)

check("nothing waiting leaves the details alone", function()
  local d = { status_id = 1, user_book_id = 55 }
  eq(BookActions.withPendingShelf(d, nil), d); eq(d.status_id, 1)
  eq(BookActions.withPendingShelf(nil, { kind = "remove" }), nil)
end)

check("a queued shelf permits rating by book ID; one with no shelf asks for one", function()
  eq(BookActions.ratingGate({ book = { book_id = 101 }, status_id = 1 }, true), "ok")
  eq(BookActions.ratingGate({ book = {} }, true), "needs_shelf")
  eq(BookActions.ratingGate({ book = { book_id = 101 } }, true), "needs_shelf")
  eq(BookActions.ratingGate({ book = { book_id = 101 }, status_id = 1 }, false), "needs_shelf")
  eq(BookActions.ratingGate({ book = {}, status_id = 1, user_book_id = 5 }, true), "ok")
end)

print("\n== sending ==")

check("each change is sent once, with the right arguments, and the queue empties", function()
  local q, api = newQueue(), fakeApi()
  q:queueStatus(1, 100, 1, { edition_id = 7 })
  q:queueRemove(1, 101, 66, "Other")
  local sent = {}
  local res = q:flush(api, { user_id = 1, on_sent = function(op, r) sent[#sent + 1] = { op = op, r = r } end })
  eq(res.sent, 2); eq(res.waiting, 0); eq(res.stopped, false)
  eq(#api.calls, 2)
  eq(api.calls[1].name, "updateUserBook")
  eq(api.calls[1].args[1], 100); eq(api.calls[1].args[2], 1); eq(api.calls[1].args[4], 7)
  eq(api.calls[2].name, "removeUserBook"); eq(api.calls[2].args[1], 66)
  eq(#sent, 2); eq(sent[1].r.id, 901)
  eq(q:count(), 0)
  q:flush(api, { user_id = 1 })
  eq(#api.calls, 2, "sent again")
end)

check("no answer keeps everything and stops, so the rest are not sent out of order", function()
  local q, api = newQueue(), fakeApi()
  q:queueStatus(1, 100, 1, {}); q:queueStatus(1, 101, 1, {})
  api.script = { false }
  local res = q:flush(api, { user_id = 1 })
  eq(res.stopped, true); eq(res.sent, 0); eq(res.waiting, 2)
  eq(#api.calls, 1)
  eq(q:get(100).failures, nil, "a dead connection is not the change's fault")
end)

check("a refusal is counted and the others still go; the third in a row holds it", function()
  local q, api = newQueue(), fakeApi()
  q:queueStatus(1, 100, 1, {}); q:queueStatus(1, 101, 1, {})
  for _ = 1, 3 do
    api.script = { { fail = "Book not found" } }
    local res = q:flush(api, { user_id = 1 })
    eq(res.sent, 1, "the other change was blocked")
    q:queueStatus(1, 101, 1, {}) -- the other is made again so there is something to send each time
  end
  local op = q:get(100)
  eq(op.failures, 3); eq(op.held, true); eq(op.reason, "refused")
  eq(q:heldCount(), 1)
  local before = #api.calls
  q:flush(api, { user_id = 1 })
  for i = before + 1, #api.calls do assert(api.calls[i].args[1] ~= 100, "a held change was sent") end
end)

check("a missing scope holds at once; retryHeld lets it try again", function()
  local q, api = newQueue(), fakeApi()
  q:queueStatus(1, 100, 1, {})
  api.script = { { fail = { status = 403, errors = { { message = "insufficient_scope" } } } } }
  q:flush(api, { user_id = 1 })
  eq(q:get(100).held, true); eq(q:get(100).reason, "scope")
  q:retryHeld()
  eq(q:get(100).held, nil)
  local res = q:flush(api, { user_id = 1 })
  eq(res.sent, 1)
end)

check("a server error is tried again without counting", function()
  local q, api = newQueue(), fakeApi()
  q:queueStatus(1, 100, 1, {})
  api.script = { { fail = { status = 503 } } }
  local res = q:flush(api, { user_id = 1 })
  eq(res.stopped, true); eq(q:get(100).failures, nil)
end)

check("another user's changes are never sent, and are dropped", function()
  local q, api = newQueue(), fakeApi()
  q:queueStatus(2, 100, 1, {}); q:queueStatus(1, 101, 1, {})
  local res = q:flush(api, { user_id = 1 })
  eq(res.sent, 1); eq(#api.calls, 1); eq(api.calls[1].args[1], 101)
  eq(q:count(), 0)
end)

check("with nobody signed in nothing is sent or dropped", function()
  local q, api = newQueue(), fakeApi()
  q:queueStatus(1, 100, 1, {})
  local res = q:flush(api, {})
  eq(res.stopped, true); eq(#api.calls, 0); eq(q:count(), 1)
end)

check("a change made while its request was out is what stays", function()
  local q, api = newQueue(), fakeApi()
  q:queueStatus(1, 100, 1, {})
  function api:updateUserBook(...)
    q:queueStatus(1, 100, 3, {}) -- the reader changed their mind meanwhile
    return { id = 5 }
  end
  q:flush(api, { user_id = 1 })
  eq(q:get(100).status_id, 3)
end)

check("a raising request is a failed try, not a crash, and releases the lock", function()
  local q, api = newQueue(), fakeApi()
  q:queueStatus(1, 100, 1, {})
  function api:updateUserBook() error("boom") end
  local res = q:flush(api, { user_id = 1 })
  eq(res.stopped, true); eq(q:count(), 1)
  eq(q.flushing, false)
end)

check("another account's waiting change is not seen, and not inherited", function()
  local q = newQueue()
  q:queueStatus(1, 100, 3, { user_book_id = 555, title = "A's book" })
  eq(q:get(100, 1) ~= nil, true, "the owner sees it")
  eq(q:get(100, 2), nil, "another account does not")
  local op = q:queueStatus(2, 100, 2, {})
  eq(op.user_book_id, nil, "B does not inherit A's library record")
  eq(op.title, nil)
  q:queueStatus(1, 101, 3, { user_book_id = 556 })
  eq(q:queueRemove(2, 101, nil, "x"), "dropped", "B's remove has no record of its own")
end)

check("a book moved to Reading and then to Read is sent as Reading first", function()
  local q, api = newQueue(), fakeApi()
  q:queueStatus(1, 100, 2, { user_book_id = 55, from_status_id = 4 })
  q:queueStatus(1, 100, 3, {})
  q:flush(api, { user_id = 1 })
  local seen = {}
  for _, c in ipairs(api.calls) do if c.name == "updateUserBook" then seen[#seen + 1] = c.args[2] end end
  eq(table.concat(seen, ","), "2,3", "statuses sent")
end)

check("a book removed while its shelf change is being sent is still removed", function()
  local q, api = newQueue(), fakeApi()
  q:queueStatus(1, 100, 1, {})
  local real = api.updateUserBook
  api.updateUserBook = function(self, ...)
    eq(q:queueRemove(1, 100, nil, "Obelisk"), "queued", "not dropped, the book is being added")
    return real(self, ...)
  end
  q:flush(api, { user_id = 1 })
  eq(q:count(), 1, "the remove is waiting")
  api.findUserBook = function() return { id = 77 } end
  q:flush(api, { user_id = 1 })
  eq(api.calls[#api.calls].name, "removeUserBook")
  eq(api.calls[#api.calls].args[1], 77, "the record it found")
  eq(q:count(), 0)
end)

check("a remove that finds the book already gone sends nothing", function()
  local q, api = newQueue(), fakeApi()
  q:queueStatus(1, 100, 1, {})
  local real = api.updateUserBook
  api.updateUserBook = function(self, ...)
    q:queueRemove(1, 100, nil, "Obelisk")
    return nil, { completed = false }
  end
  q:flush(api, { user_id = 1 })
  api.findUserBook = function() return nil end
  q:flush(api, { user_id = 1 })
  eq(q:count(), 0)
  eq(api.calls[#api.calls] == nil or api.calls[#api.calls].name ~= "removeUserBook", true)
end)

check("a book that was only queued is still dropped when nothing is on its way", function()
  local q = newQueue()
  q:queueStatus(1, 100, 1, {})
  eq(q:queueRemove(1, 100, nil, "Obelisk"), "dropped")
end)

print(string.format("\n  %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
