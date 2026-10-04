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
      cache = { cacheUserBook = function() end },
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

    -- the tick
    tapText("Update Hardcover as I read")
    assert(calls.sync == false, "the tick did not turn tracking off")
    assert(panel_is_top())

    -- Status: a list of the statuses opens over the panel; Back returns to it
    tapText("Status")
    emu:expectText("Want To Read")
    emu:expectText("Currently Reading")
    emu:expectText("Remove")
    local nodes = emu:screenText()
    assert(not nodes:find("Add a note", 1, true), "the status list should not repeat the panel's other buttons")
    emu:shot("reader_panel_status")
    emu:press("Back")
    assert(panel_is_top(), "Back from the status list did not return to the panel")

    -- Status > Want To Read asks for confirmation (maybeConfirm is the menu's own path)
    tapText("Status")
    tapText("Want To Read")
    assert(calls.confirm and calls.confirm:find("Want To Read"), "choosing a status did not ask to confirm")
    emu:press("Back")
    assert(panel_is_top(), "Back after choosing a status did not return to the panel")

    -- the rest
    tapText("Add a note")
    assert(calls.note, "Add a note did not open the note form")

    tapText("Details")
    assert(calls.details == 328491, "Details did not open the book")
    tapText("Reviews")
    assert(calls.reviews == 328491, "Reviews did not open the book's reviews")

    -- More: the reader's full tracking menu (unlink, remove, sync...) as a list over the panel
    tapText("More")
    emu:expectText("Linked book")
    emu:shot("reader_panel_more")
    emu:press("Back")
    assert(panel_is_top(), "Back from More did not return to the panel")

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
