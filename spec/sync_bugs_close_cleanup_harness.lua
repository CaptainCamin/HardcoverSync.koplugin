-- Closing a book must tidy up after itself.
--
-- The close handler used to
--   * unschedule `self.startCacheRead` (no such method: it is startReadCache), so
--     the delayed cache start queued by onReaderReady was never cancelled, and
--   * set `self.process_page_turns = false`, a field nothing reads: the flag
--     onPosUpdate checks lives in `self.state`, so page turns kept being
--     processed after close.
--
-- Run with:  lua spec/sync_bugs_close_cleanup_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local KB = dofile(PLUGIN .. "/spec/sync_regressions/lib.lua")
local App = KB.load_main()
local support = KB.support
local r = support.reporter()

local check = r.test

local function newApp(overrides)
  local app = KB.new_app {
    state = { process_page_turns = true, book_status = { id = 500 }, page = 5 },
    ui = {},
    settings = {
      syncEnabled = function() return false end,
      readSetting = function() return false end,
    },
    sync_queue = { hasPending = function() return false end, get = function() end },
  }
  for k, v in pairs(overrides or {}) do app[k] = v end
  return app
end

print("\n== CloseDocument cleanup ==")

check("cancels the delayed startReadCache scheduled by onReaderReady", function()
  KB.sched.unscheduled = {}
  newApp():onCloseDocument()
  local found = false
  for _, fn in ipairs(KB.sched.unscheduled) do
    if fn == App.startReadCache then found = true end
  end
  assert(found, "UIManager:unschedule was not given startReadCache")
end)

check("stops processing page turns when the early-out branch runs", function()
  local app = newApp { state = { process_page_turns = true, book_status = {}, page = 5 } }
  app:onCloseDocument()
  assert(app.state.process_page_turns == false, "state.process_page_turns is still " .. tostring(app.state.process_page_turns))
end)

check("stops processing page turns on the normal branch", function()
  local app = newApp {
    settings = { syncEnabled = function() return true end, readSetting = function() return false end },
  }
  app:onCloseDocument()
  assert(app.state.process_page_turns == false, "state.process_page_turns is still " .. tostring(app.state.process_page_turns))
end)

check("the end question waits for KOReader's menu and honors its finished choice", function()
  local UIManager = require("ui/uimanager")
  local dialogs = require("hardcover/lib/ui/status_dialogs")
  local confirm = dialogs.confirm
  local questions, marked = 0, 0
  dialogs.confirm = function() questions = questions + 1 end
  local summary = { status = "reading" }
  local app = newApp {
    state = { book_status = { id = 500, status_id = 2 }, end_asked = {} },
    ui = {
      document = { file = "/book.epub", getPageCount = function() return 100 end },
      getCurrentPage = function() return 100 end,
      doc_settings = { readSetting = function() return summary end },
    },
    settings = {
      readBookSetting = function() return 7 end,
      fileSyncEnabled = function() return true end,
      endPrompt = function() return true end,
    },
    sync_queue = { statusOf = function() end },
    markFinishedAndSay = function() marked = marked + 1 return true end,
  }
  UIManager._window_stack = { { widget = { name = "end_document" } } }
  app:checkEndMenu()
  assert(questions == 0 and marked == 0, "acted while KOReader's menu was open")
  UIManager._window_stack = {}
  summary.status = "complete"
  app:checkEndMenu()
  assert(marked == 1 and questions == 0, "did not honor KOReader's finished choice")
  summary.status = "reading"
  app:checkEndMenu()
  assert(questions == 1, "did not ask after dismissal without a finished choice")
  dialogs.confirm = confirm
end)

r.finish()
