-- BUG: closing the book or suspending syncs the page from the last DEBOUNCED
-- event, not the page the reader is on.
--
-- HardcoverApp:pageUpdateEvent (main.lua) is debounced by 2 seconds and is the
-- only place `self.state.page` is written. onSuspend / onDocumentClose first
-- call cancelPendingUpdates() (which throws the pending debounced page away) and
-- then updatePageNow(), which maps `self.state.page` -- the page from the last
-- event that managed to fire, so up to 2 seconds of page turns (or, while the
-- reader keeps turning at under 2 s a page, the whole stretch since they last
-- paused) are not recorded. The right value is available: self.ui:getCurrentPage().
--
-- Expected: the page handed to Cache:syncPage is the one currently displayed.
local KB = dofile((arg[1] or ".") .. "/spec/known_bugs/lib.lua")
local App = KB.load_main()
local PageMapper = require("hardcover/lib/page_mapper")

local FILE = "/books/a.epub"

print("\n== final page at suspend / close ==")

local function newApp(synced)
  local ui = {
    document = { file = FILE, getPageCount = function() return 300 end },
    getCurrentPage = function() return 200 end, -- what is on screen now
  }
  return KB.new_app {
    state = { page = 120, book_status = { id = 500 } }, -- 120: last debounced event
    ui = ui,
    page_mapper = PageMapper:new { state = {}, ui = ui },
    page_update_pending = true, -- an earlier update left the flag set
    settings = {
      readBookSetting = function(_, _, key) return key == "book_id" and 7 or nil end,
      fileSyncEnabled = function() return true end,
      syncEnabled = function() return true end,
      pages = function() return nil end,
      readSetting = function() return false end,
    },
    sync_queue = { hasPending = function() return false end, get = function() end },
    cache = { syncPage = function(_, _, page) synced[#synced + 1] = page return { queued = true } end },
  }
end

KB.check("onSuspend records the page on screen (200), not the stale 120", function()
  local synced = {}
  newApp(synced):onSuspend()
  KB.eq(synced[1], 200, "page sent at suspend")
end)

KB.check("onDocumentClose records the page on screen (200), not the stale 120", function()
  local synced = {}
  newApp(synced):onDocumentClose()
  KB.eq(synced[1], 200, "page sent at close")
end)

KB.finish("suspend/close must sync the current page, not the last debounced one")
