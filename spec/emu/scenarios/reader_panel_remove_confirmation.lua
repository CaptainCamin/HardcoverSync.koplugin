--[[--
Removing a book from the reader panel's status list asks first, with the same
copy as the book details screen, even though "Confirm changes to book read
status" is off by default. Cancelling sends nothing.

Screens: reader_panel_remove_confirm.
]]

local fixtures = require("fixtures")
local HARDCOVER = require("hardcover/lib/constants/hardcover")

return {
  name = "reader_panel_remove_confirmation",

  run = function(emu)
    local FILE = "/books/remove-confirmation.epub"
    local ui = emu:stub_ui { file = FILE, pages = 387 }
    local settings = fixtures.real_settings(emu, ui)
    settings:updateBookSetting(FILE, {
      book_id = 328491,
      title = "The Dispossessed",
      pages = 387,
      sync = true,
    })
    fixtures.install({ settings = settings })

    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
    local state = { book_status = { id = 1, status_id = HARDCOVER.STATUS.TO_READ,
      rating = nil, user_book_reads = {} } }
    local menu = HardcoverMenu:new({
      settings = settings,
      enabled = true,
      ui = ui,
      state = state,
      cache = {
        cacheUserBook = function() end,
        updateBookStatus = function() end,
      },
      sync_queue = { pendingCount = function() return 0 end, changeCount = function() return 0 end,
                     hasPending = function() return false end,
                     get = function() return nil end, shelfOp = function() return nil end,
                     statusOf = function() return nil end, clear = function() end },
      auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
               statusText = function() return "Signed in" end },
      dialog_manager = {
        -- removal must not come through the optional status-change confirmation
        maybeConfirm = function() error("Remove used maybeConfirm") end,
      },
      hardcover = {},
    })

    local function tapText(text)
      local node = emu:expectText(text)
      emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
      emu:pump()
    end
    local function count(name)
      local n = 0
      for _, c in ipairs(fixtures.calls or {}) do if c.name == name then n = n + 1 end end
      return n
    end

    menu:showReaderPanel()
    emu:pump()
    emu:screenNodes()
    tapText("Status")
    emu:pump()
    emu:screenNodes()
    emu:expectText("Remove")
    tapText("Remove")

    emu:expectText("Remove \"The Dispossessed\" from your library?")
    emu:expectText("Its status, rating and review are deleted.")
    emu:expectText("Its journal entries stay on Hardcover: notes, quotes, reading history and the review record, which may keep the review text.")
    emu:expectText("Public entries stay public.")
    emu:shot("reader_panel_remove_confirm")

    tapText("Cancel")
    assert(count("removeRead") == 0, "cancelling the confirmation still removed the book")
    emu:closeAll()
  end,
}
