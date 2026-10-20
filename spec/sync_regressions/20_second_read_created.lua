-- BUG: progress made a second read, so the journal moved on and the book did not.
--
-- Hardcover makes a read itself when a book goes on Currently Reading. Cache:syncPage held no
-- read (the status it had came without one), so it called createRead. On the live API that
-- second read takes over the book's journal entries (the progress is shown there) while the
-- book's own read, which Currently Reading shows, stays on the old page.
--
-- Expected: with no read in hand, syncPage asks Hardcover and updates the unfinished read it
-- finds; it only creates a read when there is none, and queues when it cannot ask.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local Api = require("hardcover/lib/hardcover_api")
local User = require("hardcover/lib/user")
local Cache = require("hardcover/lib/cache")

User.getId = function() return 1 end

local function newCache(status)
  local settings = {
    getFilePath = function() return "/b/a.epub" end,
    readBookSetting = function(_, _, key) return ({ book_id = 7, edition_id = 3 })[key] end,
    saveBookSnapshot = function() end,
  }
  local q = KB.newQueue()
  return Cache:new { settings = settings, sync_queue = q, state = { book_status = status } }, q
end

local function bare() return { id = 507, book_id = 7, status_id = HARDCOVER.STATUS.READING, user_book_reads = {} } end

print("\n== a read Hardcover already has ==")

KB.check("the unfinished read on Hardcover is updated, not a second one created", function()
  local calls = {}
  Api.findUserBook = function()
    return { id = 507, book_id = 7, user_book_reads = { { id = 900, started_at = "2026-01-01", edition_id = 3 } } }
  end
  Api.updatePage = function(_, id, _, page) calls[#calls + 1] = "update " .. id .. " " .. page; return bare() end
  Api.createRead = function() calls[#calls + 1] = "create"; return bare() end
  newCache(bare()):syncPage("/b/a.epub", 50)
  KB.eq(table.concat(calls, ","), "update 900 50", "calls")
end)

KB.check("a book with no read on Hardcover gets one", function()
  local calls = {}
  Api.findUserBook = function() return { id = 507, book_id = 7, user_book_reads = {} } end
  Api.updatePage = function() calls[#calls + 1] = "update"; return bare() end
  Api.createRead = function() calls[#calls + 1] = "create"; return bare() end
  newCache(bare()):syncPage("/b/a.epub", 50)
  KB.eq(table.concat(calls, ","), "create", "calls")
end)

KB.check("a finished read is not reused", function()
  local calls = {}
  Api.findUserBook = function()
    return { id = 507, book_id = 7, user_book_reads = { { id = 900, finished_at = "2026-01-02" } } }
  end
  Api.updatePage = function() calls[#calls + 1] = "update"; return bare() end
  Api.createRead = function() calls[#calls + 1] = "create"; return bare() end
  newCache(bare()):syncPage("/b/a.epub", 50)
  KB.eq(table.concat(calls, ","), "create", "calls")
end)

KB.check("when Hardcover cannot be asked the page is queued, no read is created", function()
  local calls = {}
  Api.findUserBook = function() return {}, { error = "no_response" } end
  Api.updatePage = function() calls[#calls + 1] = "update"; return bare() end
  Api.createRead = function() calls[#calls + 1] = "create"; return bare() end
  local cache, q = newCache(bare())
  local result = cache:syncPage("/b/a.epub", 50)
  KB.eq(#calls, 0, "api writes")
  KB.eq(result.queued, true, "queued")
  KB.eq(q:get("/b/a.epub").mapped_page, 50, "queued page")
end)

KB.finish("progress must go to the read Hardcover already has")
