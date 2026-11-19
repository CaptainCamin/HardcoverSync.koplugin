--[[--
Regression for #343: Start reading from a Want to Read book's reader panel must
not leave an earlier panel behind. Follows the GUI steps: tap Start reading,
close the panel, reopen it from the reader menu.
]]

local fixtures = require("fixtures")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")

return {
  name = "reader_panel_start_reading_stack",

  run = function(emu)
    local HARDCOVER = require("hardcover/lib/constants/hardcover")
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
      startReadingPages = function() return 5 end,
    }
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
    local state = { book_status = {
      id = 1, status_id = HARDCOVER.STATUS.TO_READ, rating = nil, user_book_reads = {},
    } }
    local menu = HardcoverMenu:new({
      settings = settings,
      enabled = true,
      ui = {
        document = { file = "/books/x.epub", getPageCount = function() return 387 end },
        doc_props = { display_title = "x" },
        getCurrentPage = function() return 32 end,
      },
      state = state,
      cache = {
        cacheUserBook = function() end,
        updateBookStatus = function(_, file, status)
          state.book_status.status_id = status
          return true
        end,
      },
      sync_queue = { pendingCount = function() return 0 end, changeCount = function() return 0 end,
                     hasPending = function() return false end, get = function() return nil end,
                     shelfOp = function() return nil end, statusOf = function() return nil end },
      auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
               statusText = function() return "Signed in" end },
      dialog_manager = { maybeConfirm = function(_, o) o.ok_callback() end },
      hardcover = {},
    })

    local function panels()
      local found = {}
      for _, entry in ipairs(UIManager._window_stack) do
        if entry.widget.name == "hardcover_reader_panel" then found[#found + 1] = entry.widget end
      end
      return found
    end
    local function report(stage)
      print(string.format("STACK %s: %d panels", stage, #panels()))
    end
    local function dark_pixels(top, bottom)
      local bb = emu.Screen.bb
      local dark = 0
      for y = top + 12, bottom - 4 do
        for x = 0, Device.screen:getWidth() - 1, 8 do
          if bb:getPixel(x, y):getR() < 0x55 then dark = dark + 1 end
        end
      end
      return dark
    end

    -- A plain reader page under the panel. When the sheet shrinks, its old top
    -- strip must be painted from this page, not left showing the old header.
    local page = Widget:new { name = "reader_page_stub" }
    function page:paintTo(bb, x, y)
      bb:paintRect(x, y, Device.screen:getWidth(), Device.screen:getHeight(), Blitbuffer.COLOR_WHITE)
    end
    UIManager:show(page, "full")

    local panel = menu:showReaderPanel()
    emu:pump()
    emu:screenNodes()
    report("open")
    assert(#panels() == 1, "the panel did not open alone")
    emu:expectText("Start reading")
    emu:shot("start_reading_before")
    local old_top = panel.sheet_top

    local start = emu:expectText("Start reading")
    emu:tapExpecting(start.x + math.floor(start.w / 2), start.y + math.floor(start.h / 2))
    emu:pump()
    emu:screenNodes()
    report("after Start reading")
    emu:shot("start_reading_after")
    assert(state.book_status.status_id == HARDCOVER.STATUS.READING, "Start reading did not change the shelf")
    assert(panel.sheet_top > old_top, "the panel should shrink when Start reading removes the card")
    local ghost = dark_pixels(old_top, panel.sheet_top)
    print(string.format("GHOST after Start reading: %d dark pixels in exposed strip", ghost))
    assert(ghost == 0, "the old sheet's header is still painted above the shorter panel")

    -- Close the panel the way a reader does, with the X at its top right.
    local close = panel.close_button.dimen
    emu:tapExpecting(close.x + math.floor(close.w / 2), close.y + math.floor(close.h / 2))
    emu:pump()
    report("closed")

    -- Reopen from the reader menu (HardcoverMenu:open is its button's callback).
    menu:open()
    emu:pump()
    emu:screenNodes()
    report("reopened")
    emu:shot("start_reading_reopened")
    assert(#panels() == 1, "reopening left an old panel stacked under the new one")
    assert(emu:top() == panels()[1], "the reopened panel is not the top window")
    emu:closeAll()
  end,
}
