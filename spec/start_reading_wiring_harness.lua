-- The "Start reading this book?" reminder, as main.lua wires it to page turns.
--
-- StartReading (the counter) is covered in start_reading_harness.lua. This covers the part
-- that is easy to break without touching the counter: whether a page turn reaches it at all.
--
-- Run with:  lua spec/start_reading_wiring_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local KB = dofile(PLUGIN .. "/spec/sync_regressions/lib.lua")
local App = KB.load_main()
local r = KB.support.reporter()
local check = r.test

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")

local asked, asked_options
StatusDialogs.confirm = function(o) asked = (asked or 0) + 1; asked_options = o end

-- a book that is linked, on the given shelf, with tracking on or off
local function newApp(o)
  asked = nil
  return KB.new_app {
    state = { process_page_turns = o.process, book_status = { id = o.shelf_known and 500 or nil, status_id = o.status }, page = 10 },
    ui = { document = { file = "/book.epub", getPageCount = function() return 300 end } },
    settings = {
      syncEnabled = function() return o.sync end,
      bookLinked = function() return true end,
      startReadingPages = function() return 5 end,
      trackByTime = function() return false end,
      trackByProgress = function() return false end,
      pages = function() return 300 end,
      autolinkEnabled = function() return false end,
      setSync = function(_, v) o.sync = v end,
    },
    cache = {
      hydrateBookStatus = function() o.hydrated = true; return true end,
      updateBookStatus = function() end,
      syncPage = function() end,
    },
    sync_queue = { get = function() end },
    page_mapper = { cachePageMap = function() end },
    sync_calls = {},
  }
end

local function read(app, n)
  for _ = 1, n do app:onPosUpdate(nil, app.state.page + 1) end
end

print("\n== asking to start reading while a book is read ==")

check("a Want to Read book with tracking on is asked after 5 pages", function()
  local app = newApp { process = true, sync = true, shelf_known = true, status = HARDCOVER.STATUS.TO_READ }
  read(app, 5)
  assert(asked == 1, "asked " .. tostring(asked))
end)

check("a Want to Read book with tracking off is asked after 5 pages", function()
  local app = newApp { process = true, sync = false, shelf_known = true, status = HARDCOVER.STATUS.TO_READ }
  read(app, 5)
  assert(asked == 1, "asked " .. tostring(asked))
end)

check("a book with tracking off is counted from the moment it is opened", function()
  local o = { sync = false, shelf_known = true, status = HARDCOVER.STATUS.TO_READ }
  local app = newApp(o)
  app.ui.getCurrentPage = function() return 10 end
  app.registerHighlight = function() end
  app.state.process_page_turns = nil
  app:onReaderReady()
  assert(app.state.process_page_turns == true, "page turns are not processed")
  assert(o.hydrated, "the saved shelf was not loaded")
end)

check("a Finished book with tracking off is never asked", function()
  local app = newApp { process = true, sync = false, shelf_known = true, status = HARDCOVER.STATUS.FINISHED }
  read(app, 8)
  assert(asked == nil)
end)

check("nothing is sent for a book with tracking off while it is only counted", function()
  local app = newApp { process = true, sync = false, shelf_known = true, status = HARDCOVER.STATUS.TO_READ }
  app._throttledHandlePageUpdate = function() error("sent a page") end
  app._handlePageUpdate = function() error("sent a page") end
  read(app, 6)
end)

check("saying yes turns tracking on, so the next pages are sent", function()
  local o = { process = true, sync = false, shelf_known = true, status = HARDCOVER.STATUS.TO_READ }
  local app = newApp(o)
  read(app, 5)
  app.ui.getCurrentPage = function() return 15 end
  app.ui.document.getPageCount = function() return 300 end
  app.page_mapper.getMappedPage = function() return 15 end
  asked_options.ok_callback()
  assert(o.sync == true, "tracking is still off")
end)

r.finish()
