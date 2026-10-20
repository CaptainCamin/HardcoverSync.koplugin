-- BUG: a book marked Currently Reading while offline would not take a page set by hand,
-- although the page was being tracked automatically.
--
-- "Update page" (reader menu, and "Update progress" on the reader panel) was enabled only
-- when the book's saved state said Reading AND its edition's page count was known. A book
-- set to Reading offline has its status only in the sync queue until the first reconnect
-- (the saved state can lack it, e.g. before it is hydrated), and a book whose edition has
-- no page count never had one; the automatic tracking needs neither (it sends the page
-- as it is). Online, with no Hardcover record of the book yet, the page was also sent
-- with no user book id instead of being kept.
--
-- Expected: the page can be set when the book is being read according to the state or the
-- queue, with or without a page count; with no record of the book on Hardcover yet it is
-- kept in the queue (sent after the status, which creates the record), not sent blind.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()

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
local HardcoverMenu = real_require("hardcover/lib/ui/hardcover_menu")
local HARDCOVER = real_require("hardcover/lib/constants/hardcover")

local FILE = "/books/a.epub"

local function setup(opts)
  local q = KB.newQueue()
  local book = { book_id = 7, edition_id = 3, title = "T", pages = opts.pages }
  local settings = {
    readBookSetting = function(_, _, key) return book[key] end,
    pages = function() return book.pages end,
  }
  local state = { book_status = opts.state or {} }
  local errors = {}
  local menu = setmetatable({
    state = state, enabled = true, settings = settings,
    ui = { document = { file = FILE } },
    dialog_manager = { showError = function(_, e) errors[#errors + 1] = e end },
    sync_queue = q,
  }, { __index = HardcoverMenu })
  menu.cache = Cache:new { state = state, settings = settings, sync_queue = q }
  return menu, q, state, errors
end

local function updatePage(menu)
  for _, item in ipairs(menu:getStatusSubMenuItems()) do
    if item.text_func and item.text_func():find("Update page", 1, true) then return item end
  end
end

print("\n== setting the page by hand on a book set to Reading offline ==")

KB.check("status only in the queue (state not hydrated): the page can be set", function()
  KB.network.connected = false
  local menu, q = setup { pages = 300 }
  q:enqueueStatus(FILE, { book_id = 7, edition_id = 3, status_id = HARDCOVER.STATUS.READING })
  KB.eq(updatePage(menu).enabled_func() and true or false, true, "Update page enabled")
end)

KB.check("edition with no page count: the page can still be set", function()
  KB.network.connected = false
  local menu = setup { state = { book_id = 7, status_id = HARDCOVER.STATUS.READING } }
  KB.eq(updatePage(menu).enabled_func() and true or false, true, "Update page enabled")
end)

KB.check("a book that is not being read still cannot take a page", function()
  local menu = setup { pages = 300, state = { book_id = 7, status_id = HARDCOVER.STATUS.TO_READ } }
  KB.eq(updatePage(menu).enabled_func() and true or false, false, "Update page enabled")
end)

KB.check("online with no record of the book yet: the page is kept, not sent without a user book", function()
  KB.network.connected = true
  local sent = 0
  Api.createRead = function() sent = sent + 1 return nil end
  Api.updatePage = function() sent = sent + 1 return nil end
  local menu, q, _, errors = setup { pages = 300, state = { book_id = 7, edition_id = 3, status_id = HARDCOVER.STATUS.READING } }
  q:enqueueStatus(FILE, { book_id = 7, edition_id = 3, status_id = HARDCOVER.STATUS.READING })
  menu:savePage(nil, 50, { updateItems = function() end })
  KB.eq(sent, 0, "requests sent")
  KB.eq(#errors, 0, "errors shown")
  KB.eq(q:get(FILE).mapped_page, 50, "queued page")
end)

KB.check("a page set by hand below the cloud's stays shown after the book is opened again", function()
  local q = KB.newQueue()
  local entry = q:enqueuePage(FILE, { book_id = 7, mapped_page = 50 })
  entry.force_page = true
  local shown = q:applyPending(FILE, { id = 500, user_book_reads = { { id = 900, progress_pages = 120 } } })
  KB.eq(shown.user_book_reads[1].progress_pages, 50, "page shown")
  entry.force_page = nil
  shown = q:applyPending(FILE, { id = 500, user_book_reads = { { id = 900, progress_pages = 120 } } })
  KB.eq(shown.user_book_reads[1].progress_pages, 120, "a tracked page never takes the cloud backwards")
end)

KB.finish("a book set to Reading offline takes a page set by hand")
