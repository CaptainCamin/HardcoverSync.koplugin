-- Read Again: Hardcover creates the new read on the status transition, and the queue writes it.
--
-- Run with:  luajit spec/read_again_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local KB = dofile(PLUGIN .. "/spec/sync_regressions/lib.lua")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

local passed, failed = 0, 0

local function check(label, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  [ok  ] " .. label)
  else
    failed = failed + 1
    print("  [FAIL] " .. label .. "\n         " .. tostring(err))
  end
end

local function eq(a, b, label)
  if a ~= b then
    error((label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
  end
end

local PATH = "/books/a.epub"

local function finishedBook()
  return {
    [7] = {
      id = 500, book_id = 7, status_id = HARDCOVER.STATUS.FINISHED,
      user_book_reads = { { id = 900, progress_pages = 387, edition_id = 3 } },
    },
  }
end

local function payload(page)
  return { mapped_page = page, book_id = 7, edition_id = 3, user_book_id = 500 }
end

local function apiWithStatusRead(books)
  local api = KB.fakeApi(books)
  local update = api.updateUserBookStatus
  function api:updateUserBookStatus(id, status)
    local book = update(self, id, status)
    if book and status == HARDCOVER.STATUS.READING then
      book.user_book_reads[#book.user_book_reads + 1] = { id = 901, edition_id = 3 }
    end
    return book
  end
  return api
end

print("\n== starting a finished book again ==")

check("the re-read queues only the page: no status ahead of it", function()
  local q = KB.newQueue()
  local entry = q:startReread(PATH, payload(12))
  eq(entry.status_id, nil, "status queued")
  eq(entry.mapped_page, 12, "page")
  eq(entry.reread, true, "re-read flag")
end)

check("a re-read is sent as a new read, and the finished read is never written", function()
  local q = KB.newQueue()
  q:startReread(PATH, payload(12))
  local api = apiWithStatusRead(finishedBook())
  q:flush(api, { user_id = 1 })
  eq(api:count("updatePage"), 1, "updatePage calls")
  eq(api:count("createRead"), 0, "createRead calls")
  local reads = api.shelf[7].user_book_reads
  eq(#reads, 2, "reads after the re-read")
  eq(reads[1].progress_pages, 387, "the finished read's progress")
  eq(reads[2].progress_pages, 12, "the new read's progress")
  eq(api.shelf[7].status_id, HARDCOVER.STATUS.READING, "book status after the re-read")
  eq(q:hasPending(PATH), false, "still queued after a successful send")
end)

check("a refused page after the status change retries the same new read", function()
  local q = KB.newQueue()
  q:startReread(PATH, payload(5))
  local api = apiWithStatusRead(finishedBook())
  local real, refused = api.updatePage, false
  api.updatePage = function(self, ...)
    if not refused then refused = true; return nil end
    return real(self, ...)
  end
  q:flush(api, { user_id = 1 })
  q:flush(api, { user_id = 1 })
  eq(api:count("createRead"), 0, "createRead calls")
  eq(api:count("updateUserBookStatus"), 1, "status calls")
  eq(#api.shelf[7].user_book_reads, 2, "reads on the server")
  eq(api.shelf[7].status_id, HARDCOVER.STATUS.READING, "book status")
  eq(q:hasPending(PATH), false, "still queued")
end)

check("a re-read that the server refuses stays queued, flagged to try again", function()
  local q = KB.newQueue()
  q:startReread(PATH, payload(12))
  local api = apiWithStatusRead(finishedBook())
  api.updateUserBookStatus = function() return nil end
  q:flush(api, { user_id = 1 })
  eq(q:hasPending(PATH), true, "dropped instead of kept for another try")
  eq(q:get(PATH).reread, true, "re-read flag lost")
  eq(api:count("updatePage"), 0, "updatePage calls (the finished read was written)")
end)

check("starting over at page zero selects the new read over unfinished DNF progress", function()
  local books = finishedBook()
  books[7].status_id = HARDCOVER.STATUS.DNF
  local q = KB.newQueue()
  q:startReread(PATH, payload(0))
  local api = apiWithStatusRead(books)
  q:flush(api, { user_id = 1 })
  local reads = books[7].user_book_reads
  eq(reads[1].progress_pages, 387, "old DNF page")
  eq(reads[2].progress_pages, 0, "new page")
  eq(require("hardcover/lib/book"):currentRead(reads).id, 901, "current read")
end)

check("a page update goes to the unfinished read with progress, not a newer empty read", function()
  local books = finishedBook()
  books[7].status_id = HARDCOVER.STATUS.READING
  books[7].user_book_reads = { { id = 900, progress_pages = 250 }, { id = 901 } }
  local q = KB.newQueue()
  q:enqueuePage(PATH, payload(270))
  local api = KB.fakeApi(books)
  q:flush(api, { user_id = 1 })
  eq(books[7].user_book_reads[1].progress_pages, 270, "progressed read")
  eq(books[7].user_book_reads[2].progress_pages, nil, "empty read")
  eq(q:hasPending(PATH), false, "still queued")
end)

print("")
print(string.format("  %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
