-- BUG: after the book was marked Finished, page writes are blocked, so the final page write
-- (close, delayed update, throttle's trailing update) was dropped: Hardcover ended Finished
-- with a stale progress_pages.
--
-- Expected: marking the book Finished sends the page the reader is on first.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
local App = KB.load_main()
local PageMapper = require("hardcover/lib/page_mapper")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

local FILE = "/b.epub"

print("\n== final page with Finished ==")

KB.check("the current page is sent before the Finished status", function()
  local sent = {}
  local ui = {
    document = { file = FILE, getPageCount = function() return 300 end },
    getCurrentPage = function() return 300 end,
  }
  local app = KB.new_app {
    state = { page = 250, book_status = { id = 500, status_id = HARDCOVER.STATUS.READING } },
    ui = ui,
    page_mapper = PageMapper:new { state = {}, ui = ui },
    settings = { pages = function() return nil end, readSetting = function() return false end },
    sync_queue = { get = function() end },
    cache = {
      syncPage = function(_, _, page) sent[#sent + 1] = "page " .. page end,
      updateBookStatus = function(_, _, status) sent[#sent + 1] = "status " .. status end,
    },
  }
  app.effectiveStatusId = function() return HARDCOVER.STATUS.READING end
  coroutine.wrap(function() app:markFinished(FILE, "end_auto") end)()
  KB.eq(table.concat(sent, ","), "page 300,status 3", "writes")
end)

KB.finish("the last page must reach Hardcover when a book is marked Finished")
