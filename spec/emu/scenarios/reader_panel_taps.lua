--[[--
Tapping through the reader panel: every button does what the menu item it stands
for does, and a tap above the sheet closes it. The reader and book state are stand-ins; the menu code is the real thing.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

return {
  name = "reader_panel_taps",

  run = function(emu)
    local calls = {}
    local settings = {
      bookLinked = function() return true end,
      getLinkedTitle = function() return "The Dispossessed" end,
      getLinkedBookId = function() return 328491 end,
      getLinkedEditionId = function() return nil end,
      getLinkedEditionFormat = function() return nil end,
      pages = function() return 387 end,
      syncEnabled = function() return true end,
      setSync = function() end,
      readSetting = function() return nil end,
    }
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
    local menu = HardcoverMenu:new({
      settings = settings,
      enabled = true,
      ui = {
        document = { file = "/books/x.epub", getPageCount = function() return 300 end },
        doc_props = { display_title = "x" },
        getCurrentPage = function() return 120 end,
      },
      state = { book_status = { id = 1, status_id = 2, rating = 4.5,
        user_book_reads = { { progress_pages = 142 } } } },
      cache = { cacheUserBook = function() calls.fetched_with_panel_up = emu:top() and emu:top().name == "hardcover_reader_panel" end },
      sync_queue = { pendingCount = function() return 0 end, hasPending = function() return false end,
      get = function() return nil end },
      auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
               statusText = function() return "Signed in" end },
      dialog_manager = {
        showBookDetail = function(_, id) calls.details = id end,
        showSettings = function() calls.settings = true end,
        showReviews = function(_, id) calls.reviews = id end,
        journalEntryForm = function() calls.note = true end,
        maybeConfirm = function(_, o) calls.confirm = o.text end,
      },
      hardcover = {},
      page_mapper = {
        getMappedPage = function(_, page, doc_pages, remote_pages)
          return math.floor(page / doc_pages * remote_pages)
        end,
        getUnmappedPage = function(_, page, doc_pages, remote_pages)
          return math.floor(page / remote_pages * doc_pages)
        end,
      },
    })
    -- Details and Reviews go through withWifiThen; wifi handling is not under test
    menu.withWifiThen = function(_, action) action(false) end

    local function tapText(text)
      local node = emu:expectText(text)
      emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
    end
    local function panel_is_top() return emu:top() and emu:top().name == "hardcover_reader_panel" end

    local panel = menu:showReaderPanel()
    emu:pump()
    assert(panel_is_top(), "the panel is not on top after opening")
    -- the book's record is fetched after the panel is up, not before it can appear
    assert(calls.fetched_with_panel_up == true, "the record was fetched before the panel was shown")

    -- the panel is the mid-book actions and Close; the mock has nothing else
    local nodes = emu:screenText()
    for _, gone in ipairs({ "Add a note", "Reviews", "Change edition", "More", "Rate this book" }) do
      assert(not nodes:find(gone, 1, true), gone .. " is not on the panel")
    end
    -- the edition and the link are changed from the book page (its Edition button), not the panel
    assert(not nodes:find("Edition", 1, true), "the panel still has an Edition button")
    emu:closeAll()
    panel = menu:showReaderPanel()
    emu:pump()
    assert(panel_is_top())

    tapText("Open book page")
    assert(calls.details == 328491, "Open book page did not open the book")

    -- the gear at the top right of the sheet opens the menu: linking, the edition, all settings
    emu:closeAll()
    panel = menu:showReaderPanel()
    emu:pump()
    emu:screenNodes()
    local Theme = require("hardcover/lib/ui/theme")
    local Screen = require("device").screen
    emu:tapExpecting(Screen:getWidth() - Theme.px(20) - math.floor(Theme.TOUCH_MIN / 2),
      panel.sheet_rect.y + Theme.px(30) + math.floor(Theme.TOUCH_MIN / 2))
    local menu_text = emu:screenText()
    for _, want in ipairs({ "Link a different book", "Change edition", "All Hardcover settings" }) do
      assert(menu_text:find(want, 1, true), want .. " is not in the gear menu")
    end
    emu:shot("reader_panel_gear_menu")
    tapText("All Hardcover settings")
    assert(calls.settings, "All Hardcover settings did not open the settings")
    emu:closeAll()
    panel = menu:showReaderPanel()
    emu:pump()

    tapText("Set page")
    emu:shot("reader_panel_set_page")
    emu:closeAll()
    -- closeAll also removed the panel; reopen for the dismissal check
    panel = menu:showReaderPanel()
    emu:pump()
    assert(panel_is_top())
    emu:screenNodes() -- paint first: tap ranges are only real once painted
    emu:tap(600, 100) -- the page above the sheet
    assert(not UIManager:isWidgetShown(panel), "a tap above the sheet did not close the panel")
  end,
}
