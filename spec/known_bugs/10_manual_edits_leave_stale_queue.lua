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
local KB = dofile((arg[1] or ".") .. "/spec/known_bugs/lib.lua")
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
local HardcoverMenu = real_require("hardcover/lib/ui/hardcover_menu")
local HARDCOVER = real_require("hardcover/lib/constants/hardcover")

local FILE = "/books/a.epub"

print("\n== manual edits vs the offline queue ==")

local function newMenu(queue)
  return setmetatable({
    state = { book_status = { id = 500, book_id = 7, status_id = HARDCOVER.STATUS.READING, edition_id = 3,
      user_book_reads = { { id = 900, progress_pages = 10, edition_id = 3 } } } },
    ui = { document = { file = FILE } },
    dialog_manager = { showError = function() end },
    sync_queue = queue,
  }, { __index = HardcoverMenu })
end

local mi = { updateItems = function() end }

KB.check("removing the book also drops its queued changes", function()
  local q = KB.newQueue()
  q:enqueuePage(FILE, { mapped_page = 120, book_id = 7, edition_id = 3 })
  Api.removeRead = function() return { id = 500 } end
  newMenu(q):removeCurrentRead(mi)
  KB.eq(q:hasPending(FILE), false, "queued entry after removing the book")
end)

KB.check("setting the page by hand supersedes an older queued page", function()
  local q = KB.newQueue()
  q:enqueuePage(FILE, { mapped_page = 120, book_id = 7, edition_id = 3 })
  Api.updatePage = function() return { id = 500, status_id = 2, user_book_reads = { { id = 900, progress_pages = 50 } } } end
  newMenu(q):savePage({ id = 900, edition_id = 3, started_at = "2026-01-01" }, 50, mi)
  KB.eq(q:hasPending(FILE), false, "queued 120 after the user set the page to 50")
end)

KB.finish("manual remove / set-page must clear the superseded queue entry")
