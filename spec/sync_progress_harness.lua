-- The sync progress bar is a plugin-screen thing. A flush can run while a book is open (after a
-- reconnect, on resume), and there the reading surface gets only the result snackbar: the page and
-- the book's panel are never covered by a persistent bar. These checks pin that gate.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
local App = KB.load_main()
local UIManager = require("ui/uimanager")

local passed, failed = 0, 0
local function check(label, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  [ok  ] " .. label)
  else
    failed = failed + 1
    print("  [FAIL] " .. label .. "\n         " .. tostring(err))
  end
end
local function eq(a, b, label)
  if a ~= b then error((label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- A stand-in for the bar, so the "allowed" path never loads the theme. Each show is recorded.
local shown = {}
package.preload["hardcover/lib/ui/components/sync_progress"] = function()
  return {
    show = function(opts)
      local bar = { opts = opts, closed = false }
      bar.update = function() end
      bar.close = function() bar.closed = true end
      shown[#shown + 1] = bar
      return bar
    end,
  }
end

local function set_top(widget)
  UIManager.getTopmostVisibleWidget = function() return widget end
end

local function make_app()
  local syncing = {}
  local app = KB.new_app {
    ui = {}, -- the reader / file browser stand-in
    dialog_manager = { syncingChanged = function(_, v) syncing[#syncing + 1] = v end },
    sync_queue = { flushableCount = function() return 3 end },
  }
  return app, syncing
end

print("\n== the bar never covers the reading surface ==")

check("nothing queued: no bar, no syncing state", function()
  local app, syncing = make_app()
  app.sync_queue.flushableCount = function() return 0 end
  set_top({ name = "hardcover_shell" })
  eq(app:_beginSyncProgress(1), nil, "bar")
  eq(#shown, 0, "shown")
  eq(#syncing, 0, "syncing calls")
end)

check("the reader on top: no bar, but the syncing state is still set", function()
  local app, syncing = make_app()
  set_top(app.ui)
  eq(app:_beginSyncProgress(1), nil, "bar")
  eq(#shown, 0, "shown")
  eq(syncing[1], true, "syncing started")
end)

check("the book's panel on top counts as reading: no bar", function()
  local app, syncing = make_app()
  set_top({ name = "hardcover_reader_panel" })
  eq(app:_beginSyncProgress(1), nil, "bar")
  eq(#shown, 0, "shown")
  eq(syncing[1], true, "syncing started")
end)

check("a plugin screen on top: the bar shows with the total", function()
  local app, syncing = make_app()
  set_top({ name = "hardcover_shell" })
  local bar = app:_beginSyncProgress(1)
  assert(bar ~= nil, "no bar on a plugin screen")
  eq(#shown, 1, "shown")
  eq(shown[1].opts.total, 3, "total")
  eq(syncing[1], true, "syncing started")
end)

check("_endSyncProgress closes the bar and clears the syncing state", function()
  local app, syncing = make_app()
  set_top({ name = "hardcover_shell" })
  local bar = app:_beginSyncProgress(1)
  app:_endSyncProgress(bar)
  eq(bar.closed, true, "closed")
  eq(syncing[1], true, "syncing started")
  eq(syncing[2], false, "syncing ended")
end)

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
