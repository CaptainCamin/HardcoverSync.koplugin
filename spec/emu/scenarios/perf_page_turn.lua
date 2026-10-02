--[[--
What a page turn costs while reading: the plugin's own handlers (PageUpdate,
PosUpdate), driven many times against the real plugin object.

A page turn must cost essentially nothing: no screen refresh, no widget, no disk
write, no request. The only scheduled work is the debounce timer (one task,
replaced on every turn) and, at most once per tracking interval, the single
progress update. Counts are what matter here; the CPU figure is desktop CPU.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

return {
  name = "perf_page_turn",

  run = function(emu)
    local file = "/books/perf-book.epub"
    local ui = emu:stub_ui { file = file, pages = 600, page = 1 }
    local settings = fixtures.real_settings(emu, ui)
    fixtures.install({ settings = settings })
    settings:updateBookSetting(file, { sync = true, book_id = 7, edition_id = 9, pages = 300 })

    local HardcoverApp = require("main")
    local app = HardcoverApp:new { ui = ui }
    app.state.book_status = { id = 5, status_id = 2, user_book_reads = { { id = 3, progress_pages = 1, edition_id = 9 } } }
    app.state.process_page_turns = true
    app.state.page = 1

    -- count everything a turn could do that the user (or the flash) would pay for
    local counts = { setDirty = 0, show = 0, close = 0, scheduleIn = 0, unschedule = 0, nextTick = 0, flush = 0 }
    local function wrap(obj, name, key)
      local orig = obj[name]
      obj[name] = function(...) counts[key] = counts[key] + 1; return orig(...) end
      return function() obj[name] = orig end
    end
    local LuaSettings = require("luasettings")
    local restore = {
      wrap(UIManager, "setDirty", "setDirty"), wrap(UIManager, "show", "show"), wrap(UIManager, "close", "close"),
      wrap(UIManager, "scheduleIn", "scheduleIn"), wrap(UIManager, "unschedule", "unschedule"),
      wrap(UIManager, "nextTick", "nextTick"), wrap(LuaSettings, "flush", "flush"),
    }
    local function snapshot() local c = {}; for k, v in pairs(counts) do c[k] = v end; return c end
    local function delta(a, b) local d = {}; for k in pairs(a) do d[k] = b[k] - a[k] end; return d end
    local function show(d)
      return string.format("setDirty=%d show=%d scheduleIn=%d unschedule=%d nextTick=%d flush=%d",
        d.setDirty, d.show, d.scheduleIn, d.unschedule, d.nextTick, d.flush)
    end

    local probe = emu.probe
    probe:reset()

    -- the first turn after opening the book may start the (rate limited) update
    local c0 = snapshot()
    app:onPosUpdate(nil, 2)
    local first = delta(c0, snapshot())
    print("  first turn:            " .. show(first))

    -- then a long read: 1000 turns, a page every few seconds is a bound far below this
    local N = 1000
    c0 = snapshot()
    local cpu0, mem0 = os.clock(), collectgarbage("count")
    for page = 3, N + 2 do app:onPosUpdate(nil, page) end
    local cpu = os.clock() - cpu0
    collectgarbage()
    local d = delta(c0, snapshot())
    local pos = d
    print(string.format("  %d PosUpdate turns:   %s", N, show(d)))
    print(string.format("  per turn: %.1f microseconds of desktop CPU, heap growth after GC %.1f KB", cpu / N * 1e6,
      collectgarbage("count") - mem0))

    c0 = snapshot()
    for page = N + 3, 2 * N + 2 do app:onPageUpdate(page) end
    d = delta(c0, snapshot())
    print(string.format("  %d PageUpdate turns:  %s", N, show(d)))
    local paged = d

    -- let the debounce and any update fire: what the whole read caused
    emu:pump()
    UIManager:_repaint() -- a queued refresh reaches the framebuffer here
    local snap = probe:snapshot()
    print(string.format("  refreshes caused by all of it: %d; API calls: %d", snap.refreshes, #fixtures.calls))

    for _, undo in ipairs(restore) do undo() end

    -- the budget: a page turn draws nothing, writes nothing, asks for nothing
    assert(snap.refreshes == 0, "page turns caused " .. snap.refreshes .. " screen refreshes")
    for name, turns in pairs({ PosUpdate = pos, PageUpdate = paged }) do
      assert(turns.setDirty == 0 and turns.show == 0 and turns.close == 0,
        name .. " page turns touched the screen: " .. show(turns))
      assert(turns.flush == 0, name .. " page turns wrote to disk: " .. show(turns))
      assert(turns.scheduleIn <= N, name .. " page turns scheduled more than one timer each: " .. show(turns))
    end
  end,
}
