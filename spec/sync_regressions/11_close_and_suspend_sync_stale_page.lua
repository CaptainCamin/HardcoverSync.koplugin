-- BUG: closing the book or suspending syncs the page from the last DEBOUNCED
-- event, not the page the reader is on.
--
-- HardcoverApp:pageUpdateEvent (main.lua) is debounced by 2 seconds and is the
-- only place `self.state.page` is written. onSuspend / onCloseDocument first
-- call cancelPendingUpdates() (which throws the pending debounced page away) and
-- then updatePageNow(), which maps `self.state.page` -- the page from the last
-- event that managed to fire, so up to 2 seconds of page turns (or, while the
-- reader keeps turning at under 2 s a page, the whole stretch since they last
-- paused) are not recorded. The right value is available: self.ui:getCurrentPage().
--
-- Expected: the page handed to Cache:syncPage is the one currently displayed.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
local App = KB.load_main()
local PageMapper = require("hardcover/lib/page_mapper")

local FILE = "/books/a.epub"

print("\n== final page at suspend / close ==")

local function newApp(synced)
  local ui = {
    document = { file = FILE, getPageCount = function() return 300 end },
    current_page = 200,
    getCurrentPage = function(self) return self.current_page end,
  }
  return KB.new_app {
    state = { page = 120, book_status = { id = 500, status_id = 2 } }, -- 120: last debounced event; a book being read
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
    sync_queue = { hasPending = function() return false end, get = function() end, statusOf = function() end },
    cache = { syncPage = function(_, _, page) synced[#synced + 1] = page return { queued = true } end },
  }
end

KB.check("onSuspend records the page on screen (200), not the stale 120", function()
  local synced = {}
  newApp(synced):onSuspend()
  KB.eq(synced[1], 200, "page sent at suspend")
end)

KB.check("CloseDocument records the page on screen (200), not the stale 120", function()
  local synced = {}
  newApp(synced):onCloseDocument()
  KB.eq(synced[1], 200, "page sent at close")
end)

KB.check("a first turn closed before debounce is saved", function()
  local synced = {}
  local app = newApp(synced)
  app.page_update_pending = false
  app._debouncedPageUpdate = function() end
  app:onPageUpdate(200)
  app:onCloseDocument()
  KB.eq(synced[1], 200, "first pending turn")
end)

KB.check("a backward glance is not saved on close or suspend", function()
  for _, event in ipairs({ "onCloseDocument", "onSuspend" }) do
    local synced = {}
    local app = newApp(synced)
    app.state.page, app.ui.current_page = 59, 1
    app._debouncedPageUpdate = function() end
    app:onPageUpdate(1)
    app[event](app)
    KB.eq(#synced, 0, event .. " after a glance")
  end
end)

KB.check("five pages read forward after a backward jump can be saved", function()
  local synced = {}
  local app = newApp(synced)
  app.state.page = 59
  app._debouncedPageUpdate = function() end
  app:onPageUpdate(1)
  for page = 2, 6 do app:onPageUpdate(page) end
  app.ui.current_page = 6
  app:onCloseDocument()
  KB.eq(synced[1], 6, "page after rereading")
end)

KB.finish("suspend/close must sync the current page, not the last debounced one")
