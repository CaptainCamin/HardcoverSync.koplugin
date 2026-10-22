-- The list of everything waiting to be sent, and cancelling each change on its own.
--
-- Run with:  lua spec/pending_changes_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

package.preload["gettext"] = function() return setmetatable({}, { __call = function(_, s) return s end }) end
package.preload["ffi/util"] = function()
  return { template = function(t, ...)
    local args = { ... }
    return (tostring(t):gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
  end }
end

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SyncQueue = require("hardcover/lib/sync_queue")
local GoalQueue = require("hardcover/lib/goal_queue")
local RatingQueue = require("hardcover/lib/rating_queue")
local JournalQueue = require("hardcover/lib/journal_queue")
local ReviewQueue = require("hardcover/lib/review_queue")
local PendingChanges = require("hardcover/lib/pending_changes")

local function fakeSettings()
  local store = {}
  return { readSetting = function(_, k) return store[k] end, saveSetting = function(_, k, v) store[k] = v end, flush = function() end }
end

local function queues()
  local sync = SyncQueue:new { settings = fakeSettings() }
  local goals = GoalQueue:new { settings = fakeSettings() }
  local ratings = RatingQueue:new { settings = fakeSettings() }
  return { sync_queue = sync, goal_queue = goals, rating_queue = ratings }
end

local function texts(rows)
  local out = {}
  for _, row in ipairs(rows) do out[#out + 1] = row.text end
  return table.concat(out, " | ")
end

print("\n== the list ==")

check("nothing waiting is an empty list", function()
  assert(#PendingChanges.list(queues()) == 0)
  assert(#PendingChanges.list({}) == 0 and #PendingChanges.list(nil) == 0)
end)

check("a page, a status, a rating and a goal change each get their own line", function()
  local q = queues()
  q.sync_queue:enqueuePage("/b/dune.epub", { mapped_page = 120, book_id = 7, title = "Dune" })
  q.sync_queue:enqueueStatus("/b/dune.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 7, title = "Dune" })
  q.rating_queue:queue(55, 4.5, "Dune")
  q.goal_queue:queueSave({ name = "2027", metric = "book", target = 20, start_date = "2027-01-01", end_date = "2027-12-31" }, nil)
  local rows = PendingChanges.list(q)
  assert(#rows == 4, #rows .. ": " .. texts(rows))
  local all = texts(rows)
  for _, want in ipairs({ "Dune: page 120", "Dune: mark as Read", "Dune: rating 4.5", "New goal \"2027\"" }) do
    assert(all:find(want, 1, true), want .. " missing from: " .. all)
  end
end)

check("a book with no title is named by its file; a rating with none by its id", function()
  local q = queues()
  q.sync_queue:enqueuePage("/books/Some Book.epub", { mapped_page = 3, book_id = 1 })
  q.rating_queue:queue(9, 3)
  local all = texts(PendingChanges.list(q))
  assert(all:find("Some Book: page 3", 1, true), all)
  assert(all:find("Book 9: rating 3", 1, true), all)
end)

check("a change that is stuck says why", function()
  local q = queues()
  q.sync_queue:enqueuePage("/b/a.epub", { mapped_page = 50, book_id = 1, title = "A" })
  q.sync_queue:get("/b/a.epub").conflict = { kind = "page", local_page = 50, cloud_page = 200 }
  q.sync_queue:enqueuePage("/b/b.epub", { mapped_page = 5, book_id = 2, title = "B" })
  q.sync_queue:get("/b/b.epub").failures = 3
  local rows = PendingChanges.list(q)
  assert(PendingChanges.line(rows[1]):find("waiting for your answer", 1, true), PendingChanges.line(rows[1]))
  assert(PendingChanges.line(rows[2]):find("Hardcover refused it", 1, true), PendingChanges.line(rows[2]))
end)

print("\n== cancelling one ==")

check("cancelling a page leaves the book's status waiting, and the other way round", function()
  local q = queues()
  q.sync_queue:enqueuePage("/b/dune.epub", { mapped_page = 120, book_id = 7, title = "Dune" })
  q.sync_queue:enqueueStatus("/b/dune.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 7, title = "Dune" })
  local rows = PendingChanges.list(q)
  local page_row
  for _, row in ipairs(rows) do if row.kind == "page" then page_row = row end end
  assert(page_row.cancel() == true)
  local entry = q.sync_queue:get("/b/dune.epub")
  assert(entry.mapped_page == nil and entry.status_id == HARDCOVER.STATUS.FINISHED, "the status was lost with the page")
  assert(#PendingChanges.list(q) == 1)
  assert(PendingChanges.list(q)[1].cancel() == true)
  assert(q.sync_queue:get("/b/dune.epub") == nil, "an empty entry stayed in the queue")
  assert(not q.sync_queue:hasPending())
end)

check("cancelling a page also drops the question it was waiting on", function()
  local q = queues()
  q.sync_queue:enqueuePage("/b/a.epub", { mapped_page = 50, book_id = 1, title = "A" })
  q.sync_queue:get("/b/a.epub").conflict = { kind = "page", local_page = 50, cloud_page = 200 }
  assert(q.sync_queue:conflictCount() == 1)
  PendingChanges.list(q)[1].cancel()
  assert(q.sync_queue:conflictCount() == 0, "still asking about a page that was cancelled")
end)

check("cancelling the status leaves a question about the page, and the answer given, alone", function()
  local q = queues()
  q.sync_queue:enqueuePage("/b/a.epub", { mapped_page = 50, book_id = 1, title = "A" })
  q.sync_queue:enqueueStatus("/b/a.epub", { status_id = HARDCOVER.STATUS.FINISHED, book_id = 1, title = "A" })
  local entry = q.sync_queue:get("/b/a.epub")
  entry.conflict = { kind = "page", local_page = 50, cloud_page = 200 }
  entry.reread = true
  for _, row in ipairs(PendingChanges.list(q)) do if row.kind == "status" then row.cancel() end end
  entry = q.sync_queue:get("/b/a.epub")
  assert(entry.mapped_page == 50 and entry.conflict and entry.conflict.kind == "page" and entry.reread == true,
    "the page's question was dropped with the status")
  assert(q.sync_queue:conflictCount() == 1)
end)

check("cancelling a rating or a goal change leaves the rest", function()
  local q = queues()
  q.rating_queue:queue(55, 4.5, "Dune")
  q.rating_queue:queue(56, 3, "Kindred")
  q.goal_queue:queueSave({ name = "G1", metric = "book", target = 5, start_date = "2027-01-01", end_date = "2027-12-31" }, nil)
  q.goal_queue:queueSave({ name = "G2", metric = "book", target = 6, start_date = "2027-01-01", end_date = "2027-12-31" }, nil)
  local rows = PendingChanges.list(q)
  assert(#rows == 4)
  for _, row in ipairs(rows) do
    if row.title == "Dune" or row.title == "G1" then assert(row.cancel() == true) end
  end
  local left = texts(PendingChanges.list(q))
  assert(not left:find("Dune", 1, true) and not left:find("G1", 1, true), left)
  assert(left:find("Kindred", 1, true) and left:find("G2", 1, true), left)
end)

check("cancelling something already gone is false, not an error", function()
  local q = queues()
  assert(q.sync_queue:cancelPage("/nope") == false and q.sync_queue:cancelStatus("/nope") == false)
  assert(q.goal_queue:cancel("local:9") == false and q.rating_queue:cancel(1) == false)
end)

print("\n== putting the shelves back ==")

check("a status change carries the shelf the book came from, so cancelling can undo it", function()
  local q = queues()
  q.sync_queue:enqueueStatus("/b/dune.epub", { status_id = HARDCOVER.STATUS.READING, book_id = 7, title = "Dune",
    from_status_id = HARDCOVER.STATUS.FINISHED })
  local row = PendingChanges.list(q)[1]
  assert(row.shelf_op and row.shelf_op.from_status_id == HARDCOVER.STATUS.FINISHED and row.shelf_op.known)
  assert(row.shelf_op.status_id == HARDCOVER.STATUS.READING and row.shelf_op.book_id == 7)
end)

check("a book that was on no shelf is remembered as such", function()
  local q = queues()
  q.sync_queue:enqueueStatus("/b/new.epub", { status_id = HARDCOVER.STATUS.READING, book_id = 8, title = "New" })
  local op = PendingChanges.list(q)[1].shelf_op
  assert(op.known and op.from_status_id == nil)
end)

check("a second change keeps the shelf the first one started from", function()
  local q = queues()
  q.sync_queue:enqueueStatus("/b/a.epub", { status_id = HARDCOVER.STATUS.TO_READ, book_id = 7, from_status_id = HARDCOVER.STATUS.FINISHED })
  q.sync_queue:enqueueStatus("/b/a.epub", { status_id = HARDCOVER.STATUS.READING, book_id = 7, from_status_id = HARDCOVER.STATUS.TO_READ })
  assert(PendingChanges.list(q)[1].shelf_op.from_status_id == HARDCOVER.STATUS.FINISHED)
end)

check("a re-read's page line carries the shelf op, and cancelling it forgets the origin", function()
  local q = queues()
  q.sync_queue:startReread("/b/dune.epub", { mapped_page = 3, book_id = 7, title = "Dune",
    from_status_id = HARDCOVER.STATUS.FINISHED })
  local rows = PendingChanges.list(q)
  assert(#rows == 1 and rows[1].kind == "page" and rows[1].shelf_op.from_status_id == HARDCOVER.STATUS.FINISHED)
  rows[1].cancel()
  assert(not q.sync_queue:hasPending("/b/dune.epub"))
  q.sync_queue:enqueueStatus("/b/dune.epub", { status_id = HARDCOVER.STATUS.TO_READ, book_id = 7 })
  assert(PendingChanges.list(q)[1].shelf_op.from_status_id == nil, "an old origin leaked into a new change")
end)

check("a plain page change has no shelf op", function()
  local q = queues()
  q.sync_queue:enqueuePage("/b/dune.epub", { mapped_page = 12, book_id = 7 })
  assert(PendingChanges.list(q)[1].shelf_op == nil)
end)

check("a waiting note or quote gets a line with its first words, and cancelling removes just it", function()
  local q = queues()
  q.journal_queue = JournalQueue:new { settings = fakeSettings() }
  local first = q.journal_queue:queue({ user_id = 1, book_id = 7, event = "note", text = "what a  delightfully\nweird book", title = "Beautyland" })
  q.journal_queue:queue({ user_id = 1, book_id = 8, event = "quote", text = "", title = "Dune" })
  local rows = PendingChanges.list(q)
  assert(#rows == 2 and rows[1].kind == "journal", texts(rows))
  assert(rows[1].text == 'Beautyland: note "what a delightfully weird book"', rows[1].text)
  assert(rows[2].text == "Dune: quote", rows[2].text)
  assert(rows[1].cancel() == true)
  assert(q.journal_queue:count() == 1 and q.journal_queue:list()[1].text == "")
  assert(first)
end)

check("a long note is cut for its line, and a refused one says so", function()
  local q = queues()
  q.journal_queue = JournalQueue:new { settings = fakeSettings() }
  q.journal_queue:queue({ user_id = 1, book_id = 7, event = "note", text = string.rep("word ", 30), title = "Dune" })
  q.journal_queue:list()[1].held, q.journal_queue:list()[1].reason = true, "refused"
  local row = PendingChanges.list(q)[1]
  assert(#row.text < 80, row.text)
  assert(PendingChanges.line(row):find("Hardcover refused it", 1, true), PendingChanges.line(row))
end)

check("an edit and a delete of an entry Hardcover has each get a line that can be cancelled", function()
  local q = queues()
  q.journal_queue = JournalQueue:new { settings = fakeSettings() }
  q.journal_queue:change("update", { user_id = 1, journal_id = 40, book_id = 7, event = "note", text = "better  words", title = "Dune" })
  q.journal_queue:change("delete", { user_id = 1, journal_id = 41, book_id = 7, event = "quote", title = "Dune" })
  local rows = PendingChanges.list(q)
  assert(#rows == 2, texts(rows))
  assert(rows[1].text == 'Dune: change a note to "better words"', rows[1].text)
  assert(rows[2].text == "Dune: delete a quote", rows[2].text)
  assert(rows[2].cancel() == true and q.journal_queue:count() == 1)
end)

check("a waiting review, and one waiting to be removed, each get a line that can be cancelled", function()
  local q = queues()
  q.review_queue = ReviewQueue:new { settings = fakeSettings() }
  q.review_queue:queue(5, "loved it", false, "Dune")
  q.review_queue:queue(6, "", false)
  local rows = PendingChanges.list(q)
  assert(#rows == 2 and rows[1].kind == "review", texts(rows))
  assert(rows[1].text == "Dune: review", rows[1].text)
  assert(rows[2].text == "Book 6: remove the review", rows[2].text)
  assert(rows[1].cancel() == true and q.review_queue:count() == 1)
end)

r.finish()
