--[[--
Tapping through the reader panel: every button does what the menu item it stands
for does, the tick toggles tracking and redraws, and a tap above the sheet closes
it. The reader and book state are stand-ins; the menu code is the real thing.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

return {
  name = "reader_panel_taps",

  run = function(emu)
    local calls = {}
    local sync = true
    local settings = {
      bookLinked = function() return true end,
      getLinkedTitle = function() return "The Dispossessed" end,
      getLinkedBookId = function() return 328491 end,
      getLinkedEditionId = function() return nil end,
      getLinkedEditionFormat = function() return nil end,
      pages = function() return 387 end,
      syncEnabled = function() return sync end,
      setSync = function(_, v) sync = v; calls.sync = v end,
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
      sync_queue = { pendingCount = function() return 0 end, hasPending = function() return false end },
      auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
               statusText = function() return "Signed in" end },
      dialog_manager = {
        showBookDetail = function(_, id) calls.details = id end,
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

    -- the tick
    tapText("Update Hardcover as I read")
    assert(calls.sync == false, "the tick did not turn tracking off")
    assert(panel_is_top())

    -- the panel is the three mid-book actions, More and Cancel; the mock has nothing else
    local nodes = emu:screenText()
    for _, gone in ipairs({ "Add a note", "Reviews", "Change edition", "More" }) do
      assert(not nodes:find(gone, 1, true), gone .. " is not on the panel in the mock")
    end
    emu:expectText("Rate this book")
    tapText("Open book page")
    assert(calls.details == 328491, "Open book page did not open the book")


    tapText("Update progress")
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
