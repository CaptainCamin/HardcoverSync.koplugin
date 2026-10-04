-- BUG: setting the page by hand while offline fails with "Page could not be saved".
--
-- HardcoverMenu:savePage called Api:updatePage straight away; with no connection that
-- returns nothing, so the reader got an error (and the page they had just set was lost)
-- although every other offline edit is kept on the device and sent later.
--
-- Expected: offline (or when Hardcover does not answer) the page is shown, kept in the
-- offline queue as the reader's own say (sent even if the cloud is further along), no
-- error is shown, and no request is made while offline.
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

print("\n== setting the page by hand, offline ==")

local function setup()
  local q = KB.newQueue()
  local state = { book_status = { id = 500, book_id = 7, status_id = HARDCOVER.STATUS.READING, edition_id = 3,
    user_book_reads = { { id = 900, progress_pages = 10, edition_id = 3, started_at = "2026-01-01" } } } }
  local settings = { readBookSetting = function(_, _, key) return ({ book_id = 7, edition_id = 3, title = "T" })[key] end }
  local errors = {}
  local menu = setmetatable({
    state = state,
    ui = { document = { file = FILE } },
    dialog_manager = { showError = function(_, e) errors[#errors + 1] = e end },
    sync_queue = q,
    cache = Cache:new { state = state, settings = settings, sync_queue = q },
  }, { __index = HardcoverMenu })
  return menu, q, state, errors
end

local updates = 0
local mi = { updateItems = function() updates = updates + 1 end }
local requests
Api.updatePage = function() requests = requests + 1 return nil end
Api.createRead = function() requests = requests + 1 return nil end

KB.check("offline: no error, no request, the page is shown and queued to be sent", function()
  KB.network.connected = false
  requests = 0
  local menu, q, state, errors = setup()
  menu:savePage(state.book_status.user_book_reads[1], 50, mi)
  KB.eq(#errors, 0, "errors shown")
  KB.eq(requests, 0, "requests made while offline")
  local entry = q:get(FILE)
  KB.eq(entry and entry.mapped_page, 50, "queued page")
  KB.eq(entry and entry.force_page, true, "queued as the reader's own say")
  KB.eq(state.book_status.user_book_reads[1].progress_pages, 50, "page shown")
  KB.eq(updates > 0, true, "menu refreshed")
end)

KB.check("online but Hardcover does not answer: kept the same way, no error", function()
  KB.network.connected = true
  requests = 0
  local menu, q, state, errors = setup()
  menu:savePage(state.book_status.user_book_reads[1], 50, mi)
  KB.eq(#errors, 0, "errors shown")
  KB.eq(requests, 1, "requests")
  KB.eq(q:get(FILE) and q:get(FILE).mapped_page, 50, "queued page")
end)

KB.check("a page typed in lower than the cloud's is sent, not turned into a conflict", function()
  KB.network.connected = false
  local menu, q, state = setup()
  menu:savePage(state.book_status.user_book_reads[1], 50, mi)
  KB.network.connected = true
  local api = KB.fakeApi({ [7] = { id = 500, book_id = 7, status_id = 2, user_book_reads = { { id = 900, progress_pages = 120, edition_id = 3 } } } })
  local ok = q:flush(api, { user_id = 1 })
  local sent
  for _, c in ipairs(api.calls) do if c.op == "updatePage" then sent = c end end
  KB.eq(sent ~= nil, true, "no page was sent: " .. tostring(ok))
  KB.eq(q:conflictCount(), 0, "conflicts")
end)

print("\n== the same for a rating set from the reader menu ==")

local RatingQueue = real_require("hardcover/lib/rating_queue")

KB.check("offline: the rating is kept, shown and queued, with no error", function()
  KB.network.connected = false
  local menu, _, state, errors = setup()
  local rq = RatingQueue:new { settings = KB.fakeSettings() }
  menu.rating_queue = rq
  local calls = 0
  Api.updateRating = function() calls = calls + 1 return nil end
  menu:saveRating(4.5, mi)
  KB.eq(#errors, 0, "errors shown")
  KB.eq(calls, 0, "requests made while offline")
  KB.eq(rq:get(500), 4.5, "queued rating")
  KB.eq(state.book_status.rating, 4.5, "rating shown")
  menu:saveRating(0, mi, true) -- a clear is kept too
  KB.eq(rq:get(500), 0, "queued clear")
  KB.eq(state.book_status.rating, nil, "rating cleared on screen")
end)

KB.check("online, Hardcover answers: sent straight away, nothing queued", function()
  KB.network.connected = true
  local menu, _, state = setup()
  local rq = RatingQueue:new { settings = KB.fakeSettings() }
  menu.rating_queue = rq
  Api.updateRating = function() return { id = 500, status_id = 2, rating = 3 } end
  menu:saveRating(3, mi)
  KB.eq(rq:count(), 0, "queued")
  KB.eq(state.book_status.rating, 3, "rating")
end)

KB.finish("a page or rating set by hand offline must be kept and sent, not refused")
