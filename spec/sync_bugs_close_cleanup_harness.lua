-- Closing a book must tidy up after itself.
--
-- onDocumentClose used to
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

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

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

print("\n== onDocumentClose cleanup ==")

check("cancels the delayed startReadCache scheduled by onReaderReady", function()
  KB.sched.unscheduled = {}
  newApp():onDocumentClose()
  local found = false
  for _, fn in ipairs(KB.sched.unscheduled) do
    if fn == App.startReadCache then found = true end
  end
  assert(found, "UIManager:unschedule was not given startReadCache")
end)

check("stops processing page turns when the early-out branch runs", function()
  local app = newApp { state = { process_page_turns = true, book_status = {}, page = 5 } }
  app:onDocumentClose()
  assert(app.state.process_page_turns == false, "state.process_page_turns is still " .. tostring(app.state.process_page_turns))
end)

check("stops processing page turns on the normal branch", function()
  local app = newApp {
    settings = { syncEnabled = function() return true end, readSetting = function() return false end },
  }
  app:onDocumentClose()
  assert(app.state.process_page_turns == false, "state.process_page_turns is still " .. tostring(app.state.process_page_turns))
end)

r.finish()
