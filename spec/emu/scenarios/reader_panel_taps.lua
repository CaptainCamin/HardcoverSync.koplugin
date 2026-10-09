--[[--
Tapping through the reader panel: every button does what the menu item it stands
for does, the tick toggles tracking and redraws, and a tap above the sheet closes
it. The reader and book state are stand-ins; the menu code is the real thing.

It is also what a screen or popup opened from the panel looks like around the panel: a
screen is drawn whole with nothing of the sheet through it, and when it closes the
page is hatched again; a popup hatches the sheet behind it (and only the sheet: the
page is hatched already), and closing it takes that hatching away.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

-- the page's left margin is blank, so only the hatching can put ink there
local function margin_ink(emu) return emu:ink(2, 200, 60, 60) end

-- the names of the top n widgets, topmost last
local function layers(n)
  local names = {}
  for i = n, 1, -1 do
    local w = UIManager:getNthTopWidget(i)
    names[#names + 1] = w and w.name or "?"
  end
  return table.concat(names, " > ")
end

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
      -- the exact label first: "Page" is also the start of "Page 142 of 387"
      local node
      for _, n in ipairs(emu:screenNodes()) do
        if n.text == text then node = n; break end
      end
      node = node or emu:expectText(text)
      emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
    end
    local function panel_is_top() return emu:top() and emu:top().name == "hardcover_reader_panel" end

    emu:stub_page()
    local panel = menu:showReaderPanel()
    emu:pump()
    assert(panel_is_top(), "the panel is not on top after opening")
    emu:screenNodes()
    local hatched, darkest = margin_ink(emu)
    assert(hatched > 0, "the page above the sheet is not hatched")
    assert(darkest >= 0xB0, string.format("the page is hatched twice (darkest grey %02x)", darkest))
    -- the book's record is fetched after the panel is up, not before it can appear
    assert(calls.fetched_with_panel_up == true, "the record was fetched before the panel was shown")

    -- the tick
    tapText("Tracking on")
    assert(calls.sync == false, "the tick did not turn tracking off")
    assert(panel_is_top())

    -- Status: a list of the statuses opens over the panel; Back returns to it
    tapText("Currently Reading")
    emu:expectText("Want To Read")
    emu:expectText("Currently Reading")
    emu:expectText("Remove")
    local nodes = emu:screenText()
    assert(not nodes:find("Add a note", 1, true), "the status list should not repeat the panel's other buttons")
    emu:shot("reader_panel_status")
    emu:press("Back")
    assert(panel_is_top(), "Back from the status list did not return to the panel")

    -- Status > Want To Read asks for confirmation (maybeConfirm is the menu's own path)
    tapText("Currently Reading")
    tapText("Want To Read")
    assert(calls.confirm and calls.confirm:find("Want To Read"), "choosing a status did not ask to confirm")
    emu:press("Back")
    assert(panel_is_top(), "Back after choosing a status did not return to the panel")

    -- the rest
    tapText("Note")
    assert(calls.note, "Add a note did not open the note form")

    -- the title (with its chevron) opens the book's details
    tapText("The Dispossessed")
    assert(calls.details == 328491, "tapping the title did not open the book")

    -- More: the reader's full tracking menu (unlink, remove, sync...) as a list over the panel
    -- More is an icon only, at the end of the Rate / Note row
    do
      local note = emu:expectText("Note")
      emu:tapExpecting(1200 - 20 - 36, note.y + math.floor(note.h / 2))
    end
    emu:expectText("Linked book")
    emu:shot("reader_panel_more")
    -- the screen is on top of the panel and whole: nothing of the sheet shows below its
    -- last row (it has none there), even when the panel redraws itself behind it, as it
    -- does when the book's record arrives
    assert(emu:top().name == "hardcover_settings", "More is not on top of the panel")
    assert(emu:ink(0, 1250, 1200, 300) == 0, "the sheet shows through the More screen")
    panel:render()
    emu:screenNodes()
    assert(emu:top().name == "hardcover_settings", "the panel came up over the More screen")
    assert(emu:ink(0, 1250, 1200, 300) == 0, "the panel drew over the More screen")
    emu:press("Back")
    assert(panel_is_top(), "Back from More did not return to the panel")
    -- the page was repainted without hatching while the screen was up: hatched again
    emu:screenNodes()
    emu:shot("reader_panel_after_more")
    hatched, darkest = margin_ink(emu)
    assert(hatched > 0, "the page is not hatched after a screen above the panel closed")
    assert(darkest >= 0xB0, string.format("the page is hatched twice (darkest grey %02x)", darkest))

    -- a popup opened from the panel: the sheet behind it is hatched, the page only once
    local line = emu:expectText("Page 142")
    local sheet_blank = { 900, line.y, 200, line.h } -- right of the progress line: nothing there
    assert(emu:ink(unpack(sheet_blank)) == 0, "the sheet is not blank where the test looks")
    tapText("Page 142 of 387")
    emu:screenNodes()
    emu:shot("reader_panel_set_page")
    assert(layers(3):find("^hardcover_reader_panel > hardcover_backdrop > "),
      "the Set page box is not over a backdrop over the panel: " .. layers(4))
    assert(emu:ink(unpack(sheet_blank)) > 0, "the sheet behind the Set page box is not hatched")
    hatched, darkest = margin_ink(emu)
    assert(hatched > 0 and darkest >= 0xB0, "the page behind the Set page box is not hatched exactly once")
    emu:top():onClose()
    emu:pump()
    assert(panel_is_top(), "closing the Set page box did not return to the panel")
    assert(emu:ink(unpack(sheet_blank)) == 0, "the sheet is still hatched after the Set page box closed")
    hatched, darkest = margin_ink(emu)
    assert(hatched > 0 and darkest >= 0xB0, "the panel's own hatching did not stay on the page")

    -- the rating box is a popup too
    tapText("Rate")
    emu:screenNodes()
    assert(layers(3):find("^hardcover_reader_panel > hardcover_backdrop > "),
      "the rating box is not over a backdrop: " .. layers(4))
    assert(emu:ink(unpack(sheet_blank)) > 0, "the sheet behind the rating box is not hatched")
    emu:top():onClose()
    emu:pump()
    assert(panel_is_top() and emu:ink(unpack(sheet_blank)) == 0, "closing the rating box left the sheet hatched")

    -- and so is a confirmation, here over the status list (a whole screen: all of it is hatched)
    tapText("Currently Reading")
    assert(emu:top().name == "hardcover_settings", "the status list is not on top")
    require("hardcover/lib/ui/dialog_manager").confirm({}, { text = "Mark book as Read?", ok_callback = function() end })
    emu:screenNodes()
    assert(layers(3):find("^hardcover_settings > hardcover_backdrop > "),
      "the confirmation is not over a backdrop: " .. layers(3))
    assert(emu:ink(0, 1250, 1200, 300) > 0, "the status list behind the confirmation is not hatched")
    emu:top():onClose()
    emu:pump()
    assert(emu:top().name == "hardcover_settings", "closing the confirmation did not return to the status list")
    assert(emu:ink(0, 1250, 1200, 300) == 0, "the status list is still hatched after the confirmation closed")
    emu:press("Back")
    assert(panel_is_top(), "Back from the status list did not return to the panel")

    -- closing the panel gives the page back
    panel:onClose()
    assert(not UIManager:isWidgetShown(panel.backdrop), "the panel's hatching outlived it")
    assert(margin_ink(emu) == 0, "the page is still hatched after the panel closed")
    emu:closeAll()

    -- reopen for the dismissal check
    emu:stub_page()
    panel = menu:showReaderPanel()
    emu:pump()
    assert(panel_is_top())
    emu:screenNodes() -- paint first: tap ranges are only real once painted
    emu:tap(600, 100) -- the page above the sheet
    assert(not UIManager:isWidgetShown(panel), "a tap above the sheet did not close the panel")
  end,
}
