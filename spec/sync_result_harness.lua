-- The sync pass's result: a parked question is not a failed sync, and the reader is
-- told what was sent, what needs a decision and what will retry.
--
-- Run with:  lua spec/sync_result_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local KB = dofile(PLUGIN .. "/spec/sync_regressions/lib.lua")
local App = KB.load_main()
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SyncConflicts = require("hardcover/lib/sync_conflicts")
local User = require("hardcover/lib/user")
local Api = require("hardcover/lib/hardcover_api")
User.settings = { readSetting = function() return 1 end, updateSetting = function() end }

local r = KB.support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local function fakeServer(opts)
  opts = opts or {}
  Api.findUserBook = function(_, book_id)
    if opts.offline then return {}, { completed = false } end
    if tonumber(book_id) == 1 then
      return { id = 10, status_id = HARDCOVER.STATUS.READING,
        user_book_reads = { { id = 100, edition_id = 3, progress_pages = 200 } } }
    end
    return { id = 20, status_id = HARDCOVER.STATUS.READING,
      user_book_reads = { { id = 200, edition_id = 3, progress_pages = 0 } } }
  end
  Api.updatePage = function(_, read_id, edition_id, page)
    if opts.page_fails then return nil end
    return { id = read_id == 100 and 10 or 20, status_id = HARDCOVER.STATUS.READING,
      user_book_reads = { { id = read_id, edition_id = edition_id, progress_pages = page } } }
  end
end

local function newApp(queue)
  return KB.new_app {
    state = { book_status = {} },
    ui = {},
    settings = { saveBookSnapshot = function() end },
    sync_queue = queue,
    wifi = { withWifi = function(_, fn) fn() end },
    dialog_manager = { queueChanged = function() end, shelfSent = function() end,
      ratingSent = function() end },
  }
end

local function run(app)
  local result
  app:flushSyncQueue(false, function(res) result = res end)
  return result
end

print("\n== a sync pass with a question and other ready work ==")

check("a page question parks its book and lets another book's page go", function()
  local q, settings = KB.newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 100, book_id = 1, edition_id = 3 })
  q:enqueuePage("/books/b.epub", { mapped_page = 5, book_id = 2, edition_id = 3 })
  fakeServer()
  local result = run(newApp(q))
  assert(result, "no result")
  assert(result.decisions == 1, "decisions: " .. tostring(result.decisions))
  assert(result.sent == true, "nothing reported as sent")
  assert(result.ok == true and result.failed == false, "a question read as a failure")
  assert(q:get("/books/a.epub").conflict.kind == "page", "the question was dropped")
  assert(q:get("/books/b.epub") == nil, "the other book did not go")
  local text, level = SyncConflicts.outcomeText(result)
  assert(level == "info" and text:find("Ready changes sent", 1, true)
    and text:find("1 change needs your decision", 1, true), text)
end)

check("a pass with only a question says so without claiming a failure", function()
  local q = KB.newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 100, book_id = 1, edition_id = 3 })
  fakeServer()
  local result = run(newApp(q))
  assert(result.decisions == 1 and result.failed == false and result.ok == true)
  assert(result.sent == false, "nothing was sent")
  local text, level = SyncConflicts.outcomeText(result)
  assert(level == "info" and text:find("Other changes are saved", 1, true), text)
end)

check("a connection failure is still a failure", function()
  local q = KB.newQueue()
  q:enqueuePage("/books/b.epub", { mapped_page = 5, book_id = 2, edition_id = 3 })
  fakeServer({ offline = true })
  local result = run(newApp(q))
  assert(result.ok == false and result.failed == true, "offline read as success")
  local text, level = SyncConflicts.outcomeText(result)
  assert(level == "error" and text:find("retry", 1, true), text)
end)

check("a question plus a failed send reports both", function()
  local q = KB.newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 100, book_id = 1, edition_id = 3 })
  q:enqueuePage("/books/b.epub", { mapped_page = 5, book_id = 2, edition_id = 3 })
  fakeServer({ page_fails = true })
  local result = run(newApp(q))
  assert(result.decisions == 1 and result.failed == true and result.ok == false)
  local text, level = SyncConflicts.outcomeText(result)
  assert(level == "error" and text:find("needs your decision", 1, true)
    and text:find("retry", 1, true), text)
end)

check("a rating waits behind an unsettled reading without failing the pass", function()
  local q = KB.newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 100, book_id = 1, edition_id = 3 })
  q:get("/books/a.epub").conflict = { kind = "reread", local_page = 100,
    cloud_status = HARDCOVER.STATUS.FINISHED, seq = 1 }
  local RatingQueue = require("hardcover/lib/rating_queue")
  local ratings = RatingQueue:new { settings = KB.fakeSettings() }
  ratings:queue(10, 4.5, "Dune", 1, 1, { rating = nil, known = true })
  local sent_rating = false
  Api.updateRating = function() sent_rating = true return { id = 10, rating = 4.5 } end
  fakeServer()
  local app = newApp(q)
  app.rating_queue = ratings
  local result = run(app)
  assert(result.decisions == 1 and result.failed == false and result.ok == true,
    "the question or the pass result is wrong")
  assert(result.waiting >= 1, "the blocked rating is not reported as waiting")
  assert(ratings:blockedCount(1) == 1, "the rating was not marked blocked")
  assert(sent_rating == false, "the rating went before the reading was settled")
end)

check("ratings that are both held and blocked do not turn a parked pass into a failure", function()
  local q = KB.newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 100, book_id = 1, edition_id = 3 })
  q:enqueuePage("/books/b.epub", { mapped_page = 50, book_id = 2, edition_id = 3 })
  for _, file in ipairs({ "/books/a.epub", "/books/b.epub" }) do
    q:get(file).conflict = { kind = "reread", local_page = 100,
      cloud_status = HARDCOVER.STATUS.FINISHED, seq = 1 }
  end
  local RatingQueue = require("hardcover/lib/rating_queue")
  local ratings = RatingQueue:new { settings = KB.fakeSettings() }
  ratings:queue(10, 4.5, "Dune", 1, 1, { rating = nil, known = true })
  ratings:queue(20, 3, "Emma", 2, 1, { rating = nil, known = true })
  for _, op in pairs(ratings:ops()) do
    op.blocked = true
    if op.book_id == 1 then op.held = true end
  end
  fakeServer()
  local app = newApp(q)
  app.rating_queue = ratings
  local result = run(app)
  assert(result.decisions == 2 and result.failed == false and result.ok == true,
    "the parked ratings read as a failed request")
  assert(result.waiting == 2, "waiting: " .. tostring(result.waiting))
  assert(result.sent == false, "nothing was sent")
end)

check("a rating that went through beside a question is reported as sent", function()
  local q = KB.newQueue()
  q:enqueuePage("/books/a.epub", { mapped_page = 100, book_id = 1, edition_id = 3 })
  fakeServer()
  local RatingQueue = require("hardcover/lib/rating_queue")
  local ratings = RatingQueue:new { settings = KB.fakeSettings() }
  ratings:queue(20, 4.5, "Emma", 2, 1, { rating = nil, known = true })
  Api.updateRating = function() return { id = 20, rating = 4.5 } end
  local app = newApp(q)
  app.rating_queue = ratings
  local result = run(app)
  assert(result.decisions == 1 and result.failed == false and result.ok == true)
  assert(result.sent == true, "the rating went through but was not reported")
  assert(ratings:isEmpty(), "the rating was not cleared")
end)

check("a removal with nothing left to delete is not reported as sent", function()
  local q = KB.newQueue()
  q:queueRemove(1, 7, 70, "Dune", HARDCOVER.STATUS.READING, {
    status_known = true, status_id = HARDCOVER.STATUS.READING,
    rating_known = true, reads_known = true, review_known = true,
  })
  fakeServer()
  Api.findUserBookForRemoval = function() return nil end
  Api.removeUserBook = function() error("nothing should be deleted") end
  local result = run(newApp(q))
  assert(result.ok == true and result.failed == false)
  assert(result.sent == false, "a no-op removal was reported as a send")
  assert(q:get(7) == nil, "the finished removal is still queued")
end)

r.finish()
