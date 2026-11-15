-- The sync progress bar is a plugin-screen thing. A flush can run while a book is open (after a
-- reconnect, on resume), and there the reading surface gets only the result snackbar: the page, the
-- book's panel, its end page and the pickers and dialogs opened from them are never covered by a
-- persistent bar. The gate walks the window stack to the first root screen: the shell means the
-- plugin, the reader or the file browser means not. These checks pin that.
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
      local bar = { opts = opts, closed = false, refreshed = 0 }
      bar.update = function() end
      bar.refresh = function() bar.refreshed = bar.refreshed + 1 end
      bar.close = function() bar.closed = true end
      shown[#shown + 1] = bar
      return bar
    end,
  }
end

-- widgets bottom-to-top; the last is on top. Exercises the window-stack walk.
local function set_stack(widgets)
  UIManager._window_stack = {}
  for i, w in ipairs(widgets) do UIManager._window_stack[i] = { widget = w } end
  UIManager.getTopmostVisibleWidget = function() return widgets[#widgets] end
end

local function make_app()
  for k in pairs(shown) do shown[k] = nil end
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
  set_stack({ { name = "hardcover_shell" } })
  eq(app:_beginSyncProgress(1), nil, "bar")
  eq(#shown, 0, "shown")
  eq(#syncing, 0, "syncing calls")
end)

check("the reader on top: no bar, but the syncing state is still set", function()
  local app, syncing = make_app()
  set_stack({ { name = "ReaderUI" } })
  eq(app:_beginSyncProgress(1), nil, "bar")
  eq(#shown, 0, "shown")
  eq(syncing[1], true, "syncing started")
end)

check("the book's panel over the reader: no bar", function()
  local app = make_app()
  set_stack({ { name = "ReaderUI" }, { name = "hardcover_reader_panel" } })
  eq(app:_beginSyncProgress(1), nil, "bar")
  eq(#shown, 0, "shown")
end)

check("a picker over the reader: no bar", function()
  local app = make_app()
  set_stack({ { name = "ReaderUI" }, { name = "hardcover_picker" } })
  eq(app:_beginSyncProgress(1), nil, "bar")
  eq(#shown, 0, "shown")
end)

check("the end page over the reader: no bar", function()
  local app = make_app()
  set_stack({ { name = "ReaderUI" }, { name = "hardcover_end_page" } })
  eq(app:_beginSyncProgress(1), nil, "bar")
  eq(#shown, 0, "shown")
end)

check("book details opened from the reader: no bar (no shell under it)", function()
  local app = make_app()
  set_stack({ { name = "ReaderUI" }, { name = "hardcover_book_detail" } })
  eq(app:_beginSyncProgress(1), nil, "bar")
  eq(#shown, 0, "shown")
end)

check("a book opened from the plugin puts the reader back on top: no bar", function()
  local app = make_app()
  set_stack({ { name = "hardcover_shell" }, { name = "ReaderUI" } })
  eq(app:_beginSyncProgress(1), nil, "bar")
  eq(#shown, 0, "shown")
end)

check("a KOReader menu over the reader: no bar", function()
  local app = make_app()
  set_stack({ { name = "ReaderUI" }, { name = "reader_menu" } })
  eq(app:_beginSyncProgress(1), nil, "bar")
  eq(#shown, 0, "shown")
end)

check("the file browser with no shell: no bar", function()
  local app = make_app()
  set_stack({ { name = "filemanager" } })
  eq(app:_beginSyncProgress(1), nil, "bar")
  eq(#shown, 0, "shown")
end)

check("the shell over the reader: the bar shows with the total and lifts over the nav", function()
  local app, syncing = make_app()
  set_stack({ { name = "ReaderUI" }, { name = "hardcover_shell" } })
  local bar = app:_beginSyncProgress(1)
  assert(bar ~= nil, "no bar on the shell")
  eq(#shown, 1, "shown")
  eq(shown[1].opts.total, 3, "total")
  eq(shown[1].opts.above_nav(), true, "lifts over the shell's nav")
  eq(syncing[1], true, "syncing started")
end)

check("the shell over the file browser: the bar shows", function()
  local app = make_app()
  set_stack({ { name = "filemanager" }, { name = "hardcover_shell" } })
  local bar = app:_beginSyncProgress(1)
  assert(bar ~= nil, "no bar on the shell")
  eq(shown[#shown].opts.above_nav(), true, "lifts over the shell's nav")
end)

check("book details over the shell: the bar shows but does not lift (the dialog covers the nav)", function()
  local app = make_app()
  set_stack({ { name = "hardcover_shell" }, { name = "hardcover_book_detail" } })
  app:_beginSyncProgress(1)
  eq(shown[#shown].opts.above_nav(), false, "above_nav")
end)

check("a snackbar over the reader does not start the bar", function()
  local app = make_app()
  set_stack({ { name = "ReaderUI" }, { name = "hardcover_overlay", toast = true } })
  eq(app:_beginSyncProgress(1), nil, "bar")
  eq(#shown, 0, "shown")
end)

check("a snackbar over the shell still shows the bar", function()
  local app = make_app()
  set_stack({ { name = "hardcover_shell" }, { name = "hardcover_overlay", toast = true } })
  local bar = app:_beginSyncProgress(1)
  assert(bar ~= nil, "no bar under a snackbar on a plugin screen")
  eq(shown[#shown].opts.above_nav(), true, "lifts over the shell's nav")
end)

check("the guard closes the bar once the plugin is closed mid-flush", function()
  local app = make_app()
  set_stack({ { name = "hardcover_shell" } })
  local bar = app:_beginSyncProgress(1)
  assert(bar and not bar.closed, "bar not shown")
  local guard = KB.sched.scheduled[#KB.sched.scheduled]
  assert(guard, "no guard scheduled")
  set_stack({ { name = "ReaderUI" } }) -- the user backed out to the reader
  guard.fn()
  eq(bar.closed, true, "bar closed")
end)

check("the guard keeps the bar while the user stays on a plugin screen", function()
  local app = make_app()
  set_stack({ { name = "hardcover_shell" } })
  local bar = app:_beginSyncProgress(1)
  local before = #KB.sched.scheduled
  local before_refresh = bar.refreshed
  KB.sched.scheduled[before].fn()
  eq(bar.closed, false, "bar still open")
  eq(bar.refreshed, before_refresh + 1, "guard refreshed the bar")
  eq(#KB.sched.scheduled, before + 1, "guard rescheduled")
end)

check("_endSyncProgress closes the bar and clears the syncing state", function()
  local app, syncing = make_app()
  set_stack({ { name = "hardcover_shell" } })
  local bar = app:_beginSyncProgress(1)
  app:_endSyncProgress(bar)
  eq(bar.closed, true, "closed")
  eq(syncing[1], true, "syncing started")
  eq(syncing[2], false, "syncing ended")
end)

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
