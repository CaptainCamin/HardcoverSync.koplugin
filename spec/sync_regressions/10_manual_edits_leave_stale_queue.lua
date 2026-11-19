-- BUG: removing a book or setting the page by hand does not touch the offline queue.
--
-- HardcoverMenu:removeCurrentRead (hardcover/lib/ui/hardcover_menu.lua) deletes
-- the user_book on Hardcover and clears state, but a queued entry for the file
-- stays. The next flush finds no user_book, so SyncQueue:_flushEntry calls
-- updateUserBook(book_id, READING): the book the user just removed comes back
-- on their shelf as Currently Reading.
--
-- HardcoverMenu:savePage (manual "set page", e.g. correcting 120 back to 50)
-- calls Api:updatePage directly. A queued 120 from an earlier offline session
-- stays, and the next flush sets the server back to 120 (Cache:updateBookStatus
-- clears status_id of the entry on success and Cache:syncPage clears
-- mapped_page, but the menu paths clear nothing).
--
-- Expected: both paths drop the queued entry they supersede.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()

-- the menu pulls in a large widget tree; unknown KOReader modules become inert
local function make()
  return setmetatable({}, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local Api = real_require("hardcover/lib/hardcover_api")
local Cache = real_require("hardcover/lib/cache")
local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
local HardcoverApp = real_require("main")
local HardcoverMenu = real_require("hardcover/lib/ui/hardcover_menu")
local HARDCOVER = real_require("hardcover/lib/constants/hardcover")
local User = real_require("hardcover/lib/user")
local StatusDialogs = real_require("hardcover/lib/ui/status_dialogs")
User.getId = function() return 1 end
StatusDialogs.loading = function() return { close = function() end } end
StatusDialogs.close = function() end
StatusDialogs.info = function() end

local FILE = "/books/a.epub"

print("\n== manual edits vs the offline queue ==")

local function newMenu(queue)
  local menu = setmetatable({
    state = { book_status = { id = 500, book_id = 7, status_id = HARDCOVER.STATUS.READING, edition_id = 3,
      user_book_reads = { { id = 900, progress_pages = 10, edition_id = 3 } } } },
    ui = { document = { file = FILE } },
    dialog_manager = { showError = function() end },
    sync_queue = queue,
  }, { __index = HardcoverMenu })
  local manager = DialogManager:new {
    sync_queue = queue, state = menu.state, ui = menu.ui,
    settings = { getFilePath = function() return FILE end },
  }
  manager.moveShownCounts = function() end
  manager.shelves = function() return nil end
  manager.forgetShelves = function() end
  menu.dialog_manager = manager
  menu.settings = {
    getLinkedBookId = function() return 7 end,
    getLinkedTitle = function() return "Book 7" end,
  }
  menu.cache = Cache:new { sync_queue = queue, state = menu.state, settings = {
    readBookSettings = function() return { book_id = 7, edition_id = 3 } end,
    readBookSetting = function(_, _, key) return ({ book_id = 7, edition_id = 3 })[key] end,
    saveBookSnapshot = function() end,
  } }
  return menu
end

local mi = { updateItems = function() end }

KB.check("removing the book also drops its queued changes", function()
  local q = KB.newQueue()
  q:enqueuePage(FILE, { mapped_page = 120, book_id = 7, edition_id = 3 })
  Api.removeUserBook = function(_, id) return { id = id } end
  Api.removeUserBookAsync = function(_, id, cb) cb(Api:removeUserBook(id)) end
  newMenu(q):removeCurrentRead(mi)
  KB.eq(q:hasPending(FILE), false, "queued entry after removing the book")
end)

KB.check("closing a removed book does not write Read over the removal", function()
  local q = KB.newQueue()
  q:queueRemove(1, 7, 500, "Book 7", HARDCOVER.STATUS.READING, nil)
  local app = {
    settings = { getLinkedBookId = function() return 7 end },
    sync_queue = q,
    effectiveStatusId = function() error("auto-finish looked past the queued removal") end,
  }
  KB.eq(HardcoverApp.markFinished(app, FILE, "end_chosen"), false, "auto-finish was not blocked")
  KB.eq(q:shelfOp(7).kind, "remove", "auto-finish replaced the queued removal")

  -- Choosing Mark as Read in the end-of-book prompt is explicit: it may put the
  -- book back and gets the normal written-status acknowledgement.
  -- the delete had no answer, so its removal is marked as possibly landed
  q:get(7).maybe_remote = true
  q:persist()
  local explicit = {
    settings = app.settings, sync_queue = q,
    effectiveStatusId = function() return nil end,
    finishBook = function()
      q:enqueueStatus(FILE, { user_id = 1, book_id = 7, status_id = HARDCOVER.STATUS.FINISHED,
        edition_id = 3, from_status_id = HARDCOVER.STATUS.READING })
    end,
  }
  KB.eq(HardcoverApp.markFinished(explicit, FILE, "end_chosen", { explicit = true }), true,
    "an explicit Mark as Read was silently ignored")
  KB.eq(q:shelfOp(7).kind, "status", "the explicit choice did not replace the removal")
  KB.eq(tostring(q:get(7).edition_id), "3", "restoring the book lost its edition")

  -- An abandon still owns the shelf: the cache would refuse the status, so the
  -- confirmation must not claim that Mark as Read succeeded.
  local waiting = KB.newQueue()
  waiting:queueRemove(1, 7, 500, "Book 7", HARDCOVER.STATUS.READING, nil)
  waiting:get(7).abandon_barrier = true
  waiting:persist()
  local notice
  StatusDialogs.info = function(text) notice = text end
  local barrier_app = { settings = app.settings, sync_queue = waiting,
    effectiveStatusId = function() error("cache would refuse an abandon-blocked write") end }
  KB.eq(HardcoverApp.markFinished(barrier_app, FILE, "end_chosen", { explicit = true }), false,
    "an abandon-blocked read claimed success")
  if not (notice and notice:find("Pending changes", 1, true)) then
    error("no visible reason why Mark as Read was refused: " .. tostring(notice))
  end
end)

KB.check("the Did not finish prompt sends an explicit Mark as Read", function()
  local captured, called
  local real_confirm = StatusDialogs.confirm
  StatusDialogs.confirm = function(opts) captured = opts end
  local app = {
    state = {},
    markFinishedAndSay = function(self, file, event, opts)
      called = { file = file, event = event, opts = opts }
      return true
    end,
  }
  HardcoverApp.askDidNotFinish(app, FILE)
  StatusDialogs.confirm = real_confirm
  assert(captured and captured.ok_text == "Mark as Read", "the prompt did not open")
  captured.ok_callback()
  KB.eq(called.file, FILE, "the wrong book was marked")
  KB.eq(called.event, "end_chosen", "the wrong finish event was used")
  KB.eq(tostring(called.opts and called.opts.explicit), "true",
    "a waiting removal could override the reader's explicit choice")
end)

KB.check("a queued shelf choice overrides the completed-removal marker", function()
  local q = KB.newQueue()
  q:enqueueStatus(FILE, { user_id = 1, book_id = 7, status_id = HARDCOVER.STATUS.READING,
    from_status_id = HARDCOVER.STATUS.FINISHED })
  local app = {
    settings = {
      readBookSetting = function(_, file, key)
        return file == FILE and key == "book_id" and 7 or nil
      end,
      readRemovedMarker = function() return true end,
    },
    sync_queue = q,
    effectiveStatusId = function() return nil end,
    finishBook = function() end,
  }
  KB.eq(HardcoverApp.markFinished(app, FILE, "end_auto"), true,
    "the removal marker blocked a book the reader put back")
end)

KB.check("the book-status screen marks a fresh Finished choice as explicit", function()
  local called
  local app = {
    ui = { document = { file = FILE } },
    markIfMarkedFinished = function(_, file, opts) called = { file = file, opts = opts } end,
  }
  HardcoverApp.onHardcoverStatusScreenClosed(app)
  KB.eq(called.opts, nil, "a passive close was treated as a new choice")
  HardcoverApp.onHardcoverStatusScreenFinished(app)
  KB.eq(tostring(called.opts and called.opts.explicit), "true",
    "a fresh Finished choice was treated as stale")
end)

KB.check("a completed removal blocks automatic finish on an offline reopen", function()
  local q = KB.newQueue()
  local app = {
    settings = { getLinkedBookId = function() return 7 end,
      readRemovedMarker = function(_, file) return file == FILE end },
    sync_queue = q,
    effectiveStatusId = function() error("an automatic finish used the stale book") end,
  }
  KB.eq(HardcoverApp.markFinished(app, FILE, "end_chosen"), false,
    "KOReader's Finished flag recreated the removed book")
  local explicit = {
    settings = app.settings, sync_queue = q,
    effectiveStatusId = function() return nil end,
    finishBook = function() end,
  }
  KB.eq(HardcoverApp.markFinished(explicit, FILE, "end_chosen", { explicit = true }), true,
    "an explicit shelf choice was blocked by the removal marker")
end)

KB.check("the removal guard follows the linked book, not the open document", function()
  local q = KB.newQueue()
  q:queueRemove(1, 7, 500, "Book 7", HARDCOVER.STATUS.READING, nil)
  local app = {
    settings = { getLinkedBookId = function() return 7 end },
    sync_queue = q,
    ui = { document = { file = "/books/another.epub" } },
    cache = { updateBookStatus = function() error("wrote to the wrong book") end },
  }
  HardcoverApp.finishBook(app, FILE)
  KB.eq(q:shelfOp(7).kind, "remove", "a different open file changed the removal's fate")
end)

KB.check("a removal made during the page write survives the finish", function()
  local q = KB.newQueue()
  local app = {
    settings = { getLinkedBookId = function() return 7 end },
    sync_queue = q,
    ui = { document = { file = FILE } },
    pageWriteDecision = function() return "allow" end,
    -- the page write yields, and the reader removes the book in that window
    updatePageNowForced = function()
      q:queueRemove(1, 7, 500, "Book 7", HARDCOVER.STATUS.READING, nil)
    end,
    cache = { updateBookStatus = function() error("finish overwrote the new removal") end },
  }
  HardcoverApp.finishBook(app, FILE)
  KB.eq(q:shelfOp(7).kind, "remove", "the finish replaced the removal made during its page write")
end)

KB.check("setting the page by hand supersedes an older queued page", function()
  local q = KB.newQueue()
  q:enqueuePage(FILE, { mapped_page = 120, book_id = 7, edition_id = 3 })
  Api.updatePage = function() error("manual page bypassed pending actions") end
  local menu = newMenu(q)
  menu:savePage({ id = 900, edition_id = 3, started_at = "2026-01-01" }, 50, mi)
  KB.eq(q:get(FILE).mapped_page, 50, "manual correction replaced the queued 120")
  menu.cache:syncPage(FILE, 51)
  local api = KB.fakeApi { [7] = { id = 500, status_id = 2,
    user_book_reads = { { id = 900, progress_pages = 120 } } } }
  q:flush(api, { user_id = 1 })
  KB.eq(api.shelf[7].user_book_reads[1].progress_pages, 51, "reading on keeps the manual correction")
  KB.eq(q:hasPending(FILE), false, "correction drained")
end)

KB.finish("manual remove / set-page must clear the superseded queue entry")
