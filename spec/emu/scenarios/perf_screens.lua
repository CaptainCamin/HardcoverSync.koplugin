--[[--
Refresh and decode counts for the other screens: what one user action costs the
panel. See probe.lua for what is counted, perf.lua for the event-loop model.

Each block prints one line (refreshes as the framebuffer receives them, how many
covered the whole panel, summed area in screens, widget repaints, cover
decodes) and asserts a budget, so a change that makes a screen refresh more than
it needs to fails here.
]]

local fixtures = require("fixtures")
local perf = require("perf")
local UIManager = require("ui/uimanager")

local function seed_all()
  for _, b in ipairs(fixtures.shelf_books) do
    local image = b.cached_image
    if image and image.url then fixtures.seed_cover(image.url, b.book_id % 3 + 1) end
  end
  for _, id in ipairs({ 101, 102, 103, 106, 109 }) do fixtures.seed_cover(fixtures.cover_url(id), id % 3 + 1) end
  for _, series in pairs(fixtures.series_books) do
    for _, b in ipairs(series.books) do fixtures.seed_cover(fixtures.cover_url(b.book_id), b.book_id % 3 + 1) end
  end
end

return {
  name = "perf_screens",

  run = function(emu)
    local probe = emu.probe
    local SETTING = require("hardcover/lib/constants/settings")
    local HARDCOVER = require("hardcover/lib/constants/hardcover")
    seed_all()

    local manager, settings = perf.new_manager(emu, fixtures, "perf_screens")
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    settings:updateSetting(SETTING.SHELF_SORT, nil)
    fixtures.install({ settings = settings })
    perf.slow_network({ "getLists", "getShelf", "getBookDetail", "getSeriesBooks", "getReviews", "getListBooks" })

    local results = {}

    ------------------------------------------------------------- lists index
    probe:reset()
    manager:showLists()
    perf.run_loop()
    results.lists = probe:report("lists: open (5 lists, covers)")
    print("        small: " .. perf.small_regions(results.lists))
    emu:closeAll()
    perf.run_loop()

    ------------------------------------------------------------------ shelf
    probe:reset()
    manager:showShelf(HARDCOVER.STATUS.TO_READ, "Want to Read")
    perf.run_loop()
    results.shelf = probe:report("shelf: open (5 rows of covers)")
    print("        small: " .. perf.small_regions(results.shelf))
    local menu = manager.shelf_dialog.menu
    probe:reset()
    menu:onNextPage()
    perf.run_loop()
    results.shelf_page = probe:report("shelf: one page turn")
    print("        small: " .. perf.small_regions(results.shelf_page))
    emu:closeAll()
    perf.run_loop()

    ------------------------------------------------------------ book details
    probe:reset()
    manager:showBookDetail(103)
    perf.run_loop()
    results.detail = probe:report("book details: open (series, covers)")
    print("        small: " .. perf.small_regions(results.detail))
    emu:closeAll()
    perf.run_loop()

    ----------------------------------------------------------------- reviews
    local function nopages() return true end
    probe:reset()
    manager:showReviews(103)
    perf.run_loop()
    results.reviews = probe:report("reviews: open")
    local dialog = emu:top()
    probe:reset()
    if dialog and dialog.onNextPage then dialog:onNextPage(); perf.run_loop() end
    results.reviews_page = probe:report("reviews: next page")
    emu:closeAll()
    perf.run_loop()

    ----------------------------------------------------------------- sign-in
    local SignInDialog = require("hardcover/lib/ui/signin_dialog")
    local signin = SignInDialog:new {
      auth = {},
      device = { verification_uri = "https://hardcover.app/link", user_code = "ABCD-1234", expires_in = 900 },
    }
    UIManager:show(signin)
    perf.run_loop()
    probe:reset()
    signin.started_at = os.time() - 100 -- 11% in: the bar steps from 0 to 10%
    signin:updateWait()
    perf.run_loop()
    results.signin = probe:report("sign-in: the bar steps once")
    print("        small: " .. perf.small_regions(results.signin))
    emu:closeAll()
    perf.run_loop()

    --------------------------------------------------------------- the panel
    local panel_calls = {}
    local sync = true
    local ReaderPanel = require("hardcover/lib/ui/reader_panel")
    local panel = ReaderPanel.show {
      model = function()
        return {
          title = "The Dispossessed", pills = { { text = "Reading", filled = true } }, line = "Page 120 of 341",
          track = { checked = sync, toggle = function() sync = not sync end },
          actions = {
            { text = "Status", run = function() end }, { text = "Set page", run = function() end },
            { text = "Rating", run = function() end }, { text = "Add a note", run = function() end },
            { text = "Details", run = function() end, wide = true },
          },
        }
      end,
      on_close = function() end,
    }
    probe:reset()
    perf.run_loop()
    results.panel_open = probe:report("reader panel: open")
    print("        small: " .. perf.small_regions(results.panel_open))
    probe:reset()
    panel:render() -- what the tick does after toggling
    perf.run_loop()
    results.panel_toggle = probe:report("reader panel: tick toggled")
    print("        small: " .. perf.small_regions(results.panel_toggle))
    probe:reset()
    panel:onClose()
    perf.run_loop()
    results.panel_close = probe:report("reader panel: close")
    print("        small: " .. perf.small_regions(results.panel_close))

    ----------------------------------------------------------------- settings
    local ticks = {}
    local items = {}
    for i = 1, 16 do
      ticks[i] = false
      items[i] = {
        text = "Option number " .. i,
        checked_func = function() return ticks[i] end,
        callback = function(menu) ticks[i] = not ticks[i]; if menu then menu:updateItems() end end,
      }
    end
    local SettingsDialog = require("hardcover/lib/ui/settings_dialog")
    local screen = SettingsDialog.show { items = items, title = "Settings" }
    perf.run_loop()
    assert(screen.scroll, "the settings did not scroll: the check needs a page taller than the screen")
    screen.scroll:setScrolledOffset({ x = 0, y = 400 })
    UIManager:setDirty(screen, "ui")
    perf.run_loop()
    local before_offset = screen.scroll:getScrolledOffset().y
    -- tick the 8th option, in view at this offset, with a real tap
    local target
    for _, node in ipairs(emu:screenNodes()) do
      if node.text == "Option number 8" then target = node end
    end
    assert(target, "option 8 is not on screen at the scrolled position")
    probe:reset()
    emu:tapExpecting(target.x + 5, target.y + 5)
    perf.run_loop()
    results.settings_tick = probe:report("settings: one option ticked")
    print("        small: " .. perf.small_regions(results.settings_tick))
    assert(ticks[8] == true, "the tap did not tick the option")
    assert(screen.scroll:getScrolledOffset().y == before_offset, string.format(
      "ticking an option moved the page from %d to %d", before_offset, screen.scroll:getScrolledOffset().y))
    emu:closeAll()
    perf.run_loop()

    ------------------------------------------------------------------ budget
    -- what each user action may cost the panel. A screen's first draw is one
    -- full refresh; whatever arrives later redraws only its own box or region.
    local function within(name, snap, max_full, max_area, max_decodes)
      assert(snap.full <= max_full, string.format("%s refreshed the whole panel %d times (budget %d)", name, snap.full, max_full))
      assert(snap.area_screens <= max_area, string.format("%s refreshed %.2f screens of area (budget %.2f)", name, snap.area_screens, max_area))
      if max_decodes then
        assert(snap.decodes <= max_decodes, string.format("%s decoded %d covers (budget %d)", name, snap.decodes, max_decodes))
      end
    end
    -- the lists: the page, then the rows; nine covers are drawn from three pictures
    within("lists", results.lists, 2, 2.3, 3)
    -- a shelf page turn: the page, then each cover's own frame
    within("shelf open", results.shelf, 2, 2.4)
    within("shelf page turn", results.shelf_page, 1, 1.3)
    -- details: the loading screen, the book, the series; covers are boxes
    within("book details", results.detail, 2, 2.4)
    -- the sign-in bar stepping: the bar and its line, nothing else
    within("sign-in bar", results.signin, 0, 0.1)
    -- the panel is a sheet over the page: never the whole panel
    within("reader panel open", results.panel_open, 0, 0.6)
    within("reader panel tick", results.panel_toggle, 0, 0.6)
    within("reader panel close", results.panel_close, 0, 0.6)
    -- ticking an option redraws that row, not the page
    within("settings tick", results.settings_tick, 0, 0.1)
  end,
}
