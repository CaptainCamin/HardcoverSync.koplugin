--[[--
The panel for the open book: linked (status, page, rating, tracking, the action
grid) and not linked (one big Link button). The menu is built against a stand-in
reader and book state; what the buttons do is the menu items' own logic.

The panel is drawn over a stand-in book page, as it is over the reader: without one
a screenshot keeps the pixels of whatever was there before (a panel that was just
closed, a screen that was just left) and shows things that are not on the stack.
]]

local fixtures = require("fixtures")
local Theme = require("hardcover/lib/ui/theme")

-- the page's left margin is blank, so only the hatching can put ink there
local function margin_ink(emu) return emu:ink(2, 200, 60, 60) end

-- how many rows of the left margin, around the sheet's top edge, are black: one firm
-- rule is Theme.line.firm of them; the hatching is grey, never black
local function rule_rows(emu, panel)
  emu:screenNodes()
  local n = 0
  for y = panel.sheet_top - 40, panel.sheet_top + 40 do
    if emu.Screen.bb:getPixel(30, y):getColor8().a == 0 then n = n + 1 end
  end
  return n
end

local function build(emu, linked)
  local state = { linked = linked }
  local settings = {
    bookLinked = function() return state.linked end,
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
    ui = { document = { file = "/books/x.epub" }, doc_props = { display_title = "x" } },
    state = { book_status = linked and {
      id = 1, status_id = 2, rating = 4.5,
      user_book_reads = { { progress_pages = 142 } },
    } or {} },
    cache = { cacheUserBook = function() end },
    sync_queue = { pendingCount = function() return 0 end, hasPending = function() return false end },
    auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
             statusText = function() return "Signed in" end },
    dialog_manager = {}, hardcover = {},
  })
  return menu, state
end

return {
  name = "reader_panel",

  run = function(emu)
    emu:stub_page()
    local menu = build(emu, true)
    local panel = menu:showReaderPanel()
    emu:pump()
    emu:expectText("The Dispossessed")
    emu:expectText("Currently Reading")
    emu:expectText("Page 142 of 387")
    emu:expectText("Tracking on")
    emu:expectText("Rate")
    emu:shot("reader_panel")
    local count, darkest = margin_ink(emu)
    assert(count > 0, "the page above the sheet is not hatched")
    assert(darkest >= 0xB0, string.format("the page is hatched twice (darkest grey %02x)", darkest))
    assert(rule_rows(emu, panel) == Theme.line.firm,
      "the linked sheet's top edge is not exactly one firm rule")
    panel:onClose()
    assert(margin_ink(emu) == 0, "closing the panel left the page hatched")
    emu:closeAll()

    emu:stub_page()
    local state
    menu, state = build(emu, false)
    panel = menu:showReaderPanel()
    emu:pump()
    emu:expectText("Not linked to Hardcover")
    emu:expectText("Link this book")
    emu:shot("reader_panel_unlinked")
    assert(margin_ink(emu) > 0, "the page above the unlinked sheet is not hatched")
    -- one firm rule at the top of the sheet, not two (the first panel's rule used to
    -- stay in the framebuffer when this one opened over it)
    assert(rule_rows(emu, panel) == Theme.line.firm,
      "the unlinked sheet's top edge is not exactly one firm rule")
    emu:closeAll()

    -- a panel that gets shorter while it is up (the book is unlinked): the strip it
    -- uncovers is the page again, hatched, not the old sheet with its rule
    emu:stub_page()
    menu, state = build(emu, true)
    panel = menu:showReaderPanel()
    emu:pump()
    emu:screenNodes() -- the linked sheet is drawn
    local was_top = panel.sheet_top
    state.linked = false
    menu.state.book_status = {}
    panel:render()
    emu:pump()
    assert(panel.sheet_top > was_top, "the unlinked sheet is not shorter than the linked one")
    assert(rule_rows(emu, panel) == Theme.line.firm,
      "the old sheet's rule is still there after the sheet got shorter")
    local strip = emu:ink(2, was_top - 2, 60, panel.sheet_top - was_top + 2)
    assert(strip > 0, "the strip the shorter sheet uncovered is not hatched")
    emu:closeAll()
  end,
}
