-- BUG: marking a book Finished online cleared only the queued status, so an older queued
-- page (80) stayed; the next flush saw the server Finished with no re-read flag, raised a
-- "reread" conflict and held the entry.
--
-- Expected: the older page is sent before Finished; a new read queued during that send stays.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local Api = require("hardcover/lib/hardcover_api")
local User = require("hardcover/lib/user")
local Cache = require("hardcover/lib/cache")
User.getId = function() return 1 end

local function newCache()
  local settings = {
    getFilePath = function() return "/b/a.epub" end,
    readBookSettings = function() return { book_id = 7, edition_id = 3 } end,
    readBookSetting = function(_, _, key) return ({ book_id = 7, edition_id = 3 })[key] end,
    saveBookSnapshot = function() end,
  }
  local q = KB.newQueue()
  local status = { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.READING, user_book_reads = {} }
  return Cache:new { settings = settings, sync_queue = q, state = { book_status = status } }, q
end

print("\n== Finished online with an older page queued ==")

KB.check("the older queued page is dropped", function()
  Api.updateUserBookStatus = function() error("finish bypassed pending progress") end
  local cache, q = newCache()
  q:enqueuePage("/b/a.epub", { mapped_page = 80, book_id = 7, edition_id = 3 })
  KB.eq(cache:updateBookStatus("/b/a.epub", HARDCOVER.STATUS.FINISHED).queued, true, "finish queued")
  local api = KB.fakeApi { [7] = { id = 507, status_id = HARDCOVER.STATUS.READING, user_book_reads = {} } }
  api.setFinishedDate = function(_, ub) return ub end
  KB.eq(q:flush(api, { user_id = 1 }), true, "flush")
  KB.eq(api.shelf[7].user_book_reads[1].progress_pages, 80, "progress survived the finish")
  KB.eq(api.shelf[7].status_id, HARDCOVER.STATUS.FINISHED, "final shelf")
  KB.eq(q:hasPending("/b/a.epub"), false, "sent page is not left behind")
end)

KB.check("a different pending change is kept", function()
  local cache, q = newCache()
  q:enqueuePage("/b/a.epub", { mapped_page = 80, book_id = 7, edition_id = 3 })
  cache:updateBookStatus("/b/a.epub", HARDCOVER.STATUS.FINISHED)
  local api = KB.fakeApi { [7] = { id = 507, status_id = HARDCOVER.STATUS.READING, user_book_reads = {} } }
  api.setFinishedDate = function(_, ub) return ub end
  local update = api.updateUserBookStatus
  api.updateUserBookStatus = function(self, id, status)
    q:startReread("/b/a.epub", { mapped_page = 5, book_id = 7, edition_id = 3 })
    return update(self, id, status)
  end
  q:flush(api, { user_id = 1 })
  KB.eq(q:get("/b/a.epub").mapped_page, 5, "newer page")
  KB.eq(q:statusOf("/b/a.epub"), HARDCOVER.STATUS.READING, "new read kept")
end)

KB.finish("a Finished status sent online must take the older queued page with it")
