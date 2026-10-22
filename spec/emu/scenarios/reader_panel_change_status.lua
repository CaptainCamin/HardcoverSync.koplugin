--[[--
The reader panel for a linked book that is not Currently Reading: "Set page" keeps its place but
is dotted and does nothing, "Change status" opens the status list, the list sets Currently
Reading, and the panel redraws with "Set page" live.
The reader and book state are stand-ins; the menu code is the real thing.
]]

local fixtures = require("fixtures")

return {
  name = "reader_panel_change_status",

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
    local state = { book_status = { id = 1, status_id = 1, rating = nil, user_book_reads = {} } }
    local menu = HardcoverMenu:new({
      settings = settings,
      enabled = true,
      ui = {
        document = { file = "/books/x.epub", getPageCount = function() return 300 end },
        doc_props = { display_title = "x" },
      },
      -- want to read: linked, but not being read yet
      state = state,
      cache = {
        cacheUserBook = function() end,
        updateBookStatus = function(_, _, status)
          calls.status = status
          state.book_status.status_id = status
        end,
      },
      sync_queue = { pendingCount = function() return 0 end, hasPending = function() return false end,
                     get = function() return nil end },
      auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
               statusText = function() return "Signed in" end },
      dialog_manager = {
        -- the confirm is on: take the ok path straight away
        maybeConfirm = function(_, o) calls.confirm = o.text; o.ok_callback() end,
      },
      hardcover = {},
    })

    local function tapText(text)
      local node = emu:expectText(text)
      emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
    end

    menu:showReaderPanel()
    emu:pump()
    emu:screenNodes() -- paint first: tap ranges are only real once painted

    -- the same buttons as for any book; the page cannot be set until the book is being read
    local nodes = emu:screenText()
    assert(nodes:find("Change status", 1, true), "a book not being read has no Change status button")
    assert(nodes:find("Set page", 1, true), "Set page moved away for a book not being read")
    tapText("Set page")
    assert(emu:top().name == "hardcover_reader_panel", "Set page did something on a book not being read")

    -- the status list sets Currently Reading
    tapText("Change status")
    emu:pump()
    emu:screenNodes()
    emu:shot("reader_panel_status_list")
    tapText("Currently Reading")
    assert(calls.confirm == "Mark book as Currently Reading?", "setting Currently Reading did not ask first")
    assert(calls.status == 2, "Currently Reading was not set")

    -- the status list stays open on a radio choice; closing it (its back arrow) shows the panel
    assert(emu:top().name == "hardcover_settings", "the status list closed on its own")
    emu:top():onClose()

    -- the panel redraws with the buttons where they were
    emu:pump()
    emu:screenNodes()
    nodes = emu:screenText()
    assert(nodes:find("Set page", 1, true) and nodes:find("Change status", 1, true), "the panel lost a button after Currently Reading was set")
    emu:shot("reader_panel_change_status")
    emu:closeAll()
  end,
}
