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
local Trapper = require("ui/trapper")

local asked, asked_options
StatusDialogs.confirm = function(o) asked = (asked or 0) + 1; asked_options = o end

local function runWithCoroutineTrapper(fn)
  local original_wrap = Trapper.wrap
  Trapper.wrap = function(_, task)
    local co = coroutine.create(task)
    local ok, err = coroutine.resume(co)
    assert(ok, err)
  end
  local ok, err = pcall(fn)
  Trapper.wrap = original_wrap
  assert(ok, err)
end

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
    sync_queue = { get = function() end, statusOf = function() end },
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
  local actions = {}
  app.cache.updateBookStatus = function(_, file, status)
    actions[#actions + 1] = { "status", file, status, coroutine.running() ~= nil }
  end
  app.cache.syncPage = function(_, file, page)
    actions[#actions + 1] = { "page", file, page }
  end
  read(app, 5)
  app.ui.getCurrentPage = function() return 15 end
  app.ui.document.getPageCount = function() return 300 end
  app.page_mapper.getMappedPage = function() return 15 end
  runWithCoroutineTrapper(asked_options.ok_callback)
  assert(o.sync == true, "tracking is still off")
  assert(actions[1] and actions[1][1] == "status" and actions[1][3] == HARDCOVER.STATUS.READING,
    "the accepted prompt did not set Currently Reading")
  assert(actions[1][4], "the shelf update ran outside Trapper's coroutine")
  assert(actions[2] and actions[2][1] == "page", "the current page was not sent after the status")
end)

check("saying yes sets Currently Reading when the saved shelf status is unknown", function()
  local app = newApp { process = true, sync = true, shelf_known = true, status = nil }
  local actions = {}
  app.cache.updateBookStatus = function(_, file, status)
    actions[#actions + 1] = { "status", file, status, coroutine.running() ~= nil }
  end
  app.cache.syncPage = function(_, file, page)
    actions[#actions + 1] = { "page", file, page }
  end
  read(app, 5)
  app.ui.document.getPageCount = function() return 300 end
  app.page_mapper.getMappedPage = function(_, page) return page end
  runWithCoroutineTrapper(asked_options.ok_callback)
  assert(actions[1] and actions[1][1] == "status" and actions[1][3] == HARDCOVER.STATUS.READING,
    "the accepted prompt did not set Currently Reading")
  assert(actions[1][4], "the shelf update ran outside Trapper's coroutine")
  assert(actions[2] and actions[2][1] == "page", "the current page was not sent after the status")
end)

check("a delayed pre-start page cannot overwrite the page sent by Start reading", function()
  local app = newApp { process = true, sync = true, shelf_known = true, status = HARDCOVER.STATUS.TO_READ }
  local sent, pending = {}, nil
  app.syncFileUpdates = function() return true end
  app.pageWriteDecision = function() return "allow" end
  app.ui.getCurrentPage = function() return 13 end
  app.page_mapper.getMappedPage = function(_, page) return page end
  app.cache.syncPage = function(_, _, page)
    sent[#sent + 1] = page
    if page == 13 then coroutine.yield() end
  end
  app.cache.updateBookStatus = function() coroutine.yield() end
  local original_wrap = Trapper.wrap
  Trapper.wrap = function(_, fn)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    assert(ok, err)
    if coroutine.status(co) ~= "dead" then pending = co end
  end
  app:_handlePageUpdate("/book.epub", 7, false)
  local old = KB.sched.scheduled[#KB.sched.scheduled].fn
  app:startReading("/book.epub")
  assert(pending, "status call did not yield")
  app:_handlePageUpdate("/book.epub", 9, false)
  local during = KB.sched.scheduled[#KB.sched.scheduled].fn
  local ok, err = coroutine.resume(pending)
  assert(ok, err)
  old(); during()
  app:_handlePageUpdate("/book.epub", 21, false)
  KB.sched.scheduled[#KB.sched.scheduled].fn()
  ok, err = coroutine.resume(pending)
  assert(ok, err)
  KB.sched.scheduled[#KB.sched.scheduled].fn()
  Trapper.wrap = original_wrap
  assert(table.concat(sent, ",") == "13,21", "sent " .. table.concat(sent, ","))
end)

for _, during_move in ipairs({ false, true }) do
check("an edition move remaps a page timer firing " .. (during_move and "during" or "after") .. " the move", function()
  local app = newApp { process = true, sync = true, shelf_known = true, status = HARDCOVER.STATUS.READING }
  local linked = { book_id = 7, edition_id = 10, pages = 300 }
  local sent = {}
  app.syncFileUpdates = function() return true end
  app.ui.getCurrentPage = function() return 123 end
  app.settings.pages = function() return linked.pages end
  app.settings.readBookSetting = function(_, _, k) return linked[k] end
  app.settings.updateBookSetting = function(_, _, values)
    for k, v in pairs(values) do linked[k] = v end
  end
  app.page_mapper = require("hardcover/lib/page_mapper"):new { state = {}, ui = { } }
  app.page_mapper.usePageMap = function() return false end
  app.state.book_status = { id = 500, book_id = 7, status_id = 2, edition_id = 10,
    user_book_reads = { { id = 800, edition_id = 10, progress_pages = 120, started_at = "2026-01-01" } } }
  app.sync_queue.hasPending = function() return false end
  app.cache.sync_queue = app.sync_queue
  app.cache.saveSnapshot = function() end
  app.cache.cacheUserBook = function() end
  app.cache.syncPage = function(_, _, page) sent[#sent + 1] = { page = page, edition = linked.edition_id } end
  app:_handlePageUpdate("/book.epub", 119, false)
  local old = KB.sched.scheduled[#KB.sched.scheduled].fn
  local api = require("hardcover/lib/hardcover_api")
  local update_page, update_book = api.updatePage, api.updateUserBook
  api.updatePage = function()
    if during_move then
      old()
      app:_handlePageUpdate("/book.epub", 123, true)
      app:updatePageNowForced("/book.epub")
    end
    assert(#sent == 0, "progress escaped while the edition request yielded")
    return { id = 500, user_book_reads = { { id = 800, edition_id = 20, progress_pages = 160 } } }
  end
  api.updateUserBook = function() return { id = 500, status_id = 2, edition_id = 20 } end
  local h = require("hardcover/lib/hardcover"):new {
    ui = app.ui, settings = app.settings, state = app.state, cache = app.cache,
    on_edition_change = function(active, filename) app:onEditionChange(active, filename) end,
  }
  local ok, err = pcall(function()
    assert(h:linkBook { book_id = 7, edition_id = 20, pages = 400, title = "A book" })
    old() -- an old-unit timer firing after the move must also be harmless
    assert(#sent == 1 and sent[1].page == 164 and sent[1].edition == 20, "wrong page or edition after move")
  end)
  api.updatePage, api.updateUserBook = update_page, update_book
  assert(ok, err)
end)
end

check("the jump offer uses the unfinished read with progress, not a newer empty read", function()
  local app = newApp { process = true, sync = true, shelf_known = true, status = HARDCOVER.STATUS.READING }
  app.state.book_status.user_book_reads = { { id = 1, progress_pages = 250 }, { id = 2 } }
  app.ui.getCurrentPage = function() return 10 end
  app.page_mapper.getMappedPage = function(_, page) return page end
  app.jumpTarget = function(_, page) return page end
  app.sync_queue.hasPending = function() return false end
  app.settings.readBookSetting = function() return nil end
  local network = require("ui/network/manager")
  local before = network.isConnected
  network.isConnected = function() return true end
  app:offerJumpToCloudPage()
  network.isConnected = before
  assert(asked_options and asked_options.title:find("250", 1, true), "wrong jump prompt")
end)

r.finish()
