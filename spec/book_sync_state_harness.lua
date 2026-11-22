-- What the book details page says waits for it: one decision, a rating or review in the queue,
-- a read edit in flight, and the note's two lines. Pure data over fake queues.
--
-- Run with:  luajit spec/book_sync_state_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local check = r.test

support.preload_koreader_stubs()
package.preload["ffi/util"] = function()
  return { template = function(text, ...)
    local values = { ... }
    return (text:gsub("%%(%d+)", function(n) return tostring(values[tonumber(n)] or "") end))
  end }
end

local BookSyncState = require("hardcover/lib/book_sync_state")

local function syncQueue(decision, actions)
  return {
    decisionForBook = function() return decision end,
    readActions = function() return actions or {} end,
  }
end

local function itemQueue(value, row, decision)
  row = row or {}
  row.book_id, row.user_book_id = row.book_id or 7, row.user_book_id or 55
  return {
    get = function() return value end,
    list = function() return { row } end,
    decisionForBook = function() return decision end,
  }
end

local function state(opts)
  return BookSyncState.forBook(opts or {}, 7, 55, 1)
end

print("\n== nothing waiting ==")

check("a book with no queue says nothing", function()
  local s = state()
  assert(s.decision == nil and s.rating_state == nil and s.review_state == nil and s.read_state == nil)
  assert(#s.note_lines == 0)
end)

print("\n== the decision ==")

check("a read question names the field and has one supporting line", function()
  local decision = { title = "The Dispossessed", kind = "read_changed",
    conflict = { kind = "read_changed", fields = { { field = "finished_at" } } } }
  local s = state { sync_queue = syncQueue(decision), read_actions = {
    { seq = 3, read_id = 10, conflict = { kind = "read_changed" } },
  } }
  assert(s.decision == decision)
  assert(s.note_lines[1]:find("The Dispossessed", 1, true), s.note_lines[1])
  assert(s.note_lines[1]:find("finish date changed on Hardcover", 1, true), s.note_lines[1])
  assert(s.note_lines[2] == "The read changed on another device since you started.", s.note_lines[2])
  -- the details reading row states it too: it comes before the count and edition
  assert(s.read_state == "Needs your decision", s.read_state)
end)

check("a removal question has its own note", function()
  local s = state { sync_queue = syncQueue({ title = "A Book", conflict = { kind = "remove" } }) }
  assert(s.note_lines[1]:find("A Book: remove anyway?", 1, true), s.note_lines[1])
  assert(s.note_lines[2] == "Changed on Hardcover since you asked.", s.note_lines[2])
end)

print("\n== a rating or review waiting ==")

check("a queued rating says waiting, and a held one says why", function()
  local waiting = state { rating_queue = itemQueue(4, {}) }
  assert(waiting.rating_state == "Waiting to send", waiting.rating_state)
  local blocked = state { rating_queue = itemQueue(4, { blocked = true }) }
  assert(blocked.rating_state == "Waiting for an earlier change", blocked.rating_state)
  local refused = state { rating_queue = itemQueue(4, { held = true }) }
  assert(refused.rating_state == "Hardcover refused it", refused.rating_state)
  local scope = state { rating_queue = itemQueue(4, { held = true, reason = "scope" }) }
  assert(scope.rating_state == "Sign in again to send it", scope.rating_state)
  local none = state { rating_queue = itemQueue(nil) }
  assert(none.rating_state == nil)
  local parked = state { rating_queue = itemQueue(4, { parked = true }) }
  assert(parked.rating_state == "Needs your decision", parked.rating_state)
end)

check("a queued review uses the same words", function()
  assert(state { review_queue = itemQueue({ text = "x" }, {}) }.review_state == "Waiting to send")
  assert(state { review_queue = itemQueue({ text = "x" }, { blocked = true }) }.review_state
    == "Waiting for an earlier change")
  assert(state { review_queue = itemQueue(nil) }.review_state == nil)
  assert(state { review_queue = itemQueue({ text = "x" }, { parked = true }) }.review_state
    == "Needs your decision")
end)

check("a rating or review question is the book's decision when the reading queue has none", function()
  local rating = { title = "A Book", kind = "rating",
    entry = { title = "A Book", conflict = { kind = "rating", online = 5, proposed = 4 } } }
  local s = state { rating_queue = itemQueue(4, { parked = true }, rating) }
  assert(s.decision == rating)
  assert(s.note_lines[1] == "A Book: rating changed on Hardcover", s.note_lines[1])
  assert(s.note_lines[2] == "Both ratings are kept until you answer.", s.note_lines[2])

  local review = { title = "A Book", kind = "review",
    entry = { title = "A Book", conflict = { kind = "review", online = { text = "x", spoilers = false },
      proposed = { text = "y", spoilers = false }, base = { text = "x", spoilers = false } } } }
  local r = state { review_queue = itemQueue({ text = "y" }, { parked = true }, review) }
  assert(r.decision == review)
  assert(r.note_lines[1] == "A Book: review changed on Hardcover", r.note_lines[1])

  local unseen = { title = "A Book", kind = "review",
    entry = { title = "A Book", conflict = { kind = "review", online = { text = "x", spoilers = false },
      proposed = { text = "y", spoilers = false } } } }
  local u = state { review_queue = itemQueue({ text = "y" }, { parked = true }, unseen) }
  assert(u.note_lines[1] == "A Book: unseen review on Hardcover", u.note_lines[1])
end)

print("\n== read edits ==")

check("a question wins over a request in flight and a held older read", function()
  local s = state { read_actions = {
    { seq = 1, read_id = 10, conflict = {} },
    { seq = 2, read_id = 11, checking = true },
    { seq = 3, read_id = 12, wait = true },
    { seq = 4, read_id = 13 },
  } }
  assert(s.read_state == "Needs your decision", s.read_state)
end)

check("checking, waiting for a newer read, and waiting to send", function()
  assert(state { read_actions = { { seq = 1, read_id = 10, checking = true } } }.read_state
    == "Checking what synced")
  assert(state { read_actions = { { seq = 1, read_id = 10, wait = true } } }.read_state
    == "Waiting for the current read to finish")
  assert(state { read_actions = { { seq = 1, read_id = 10 } } }.read_state == "Waiting to send")
end)

check("read_actions overrides what the queue would return", function()
  local s = state { sync_queue = syncQueue(nil, { { seq = 1, read_id = 10, checking = true } }),
    read_actions = {} }
  assert(s.read_state == nil, s.read_state)
end)

r.finish()
