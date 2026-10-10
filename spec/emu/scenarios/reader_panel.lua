--[[--
The panel for the open book: linked (status, page, rating, tracking, the action
grid) and not linked (one big Link button). The menu is built against a stand-in
reader and book state; what the buttons do is the menu items' own logic.
]]

local fixtures = require("fixtures")

local function build(emu, linked)
  local settings = {
    bookLinked = function() return linked end,
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
  return HardcoverMenu:new({
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
end

return {
  name = "reader_panel",

  run = function(emu)
    local menu = build(emu, true)
    menu:showReaderPanel()
    emu:pump()
    emu:expectText("The Dispossessed")
    emu:expectText("Page 142 of 387")
    emu:expectText("Update Hardcover as I read")
    emu:expectText("Update progress")
    emu:expectText("Open book page")
    emu:shot("reader_panel")
    emu:closeAll()

    menu = build(emu, false)
    menu:showReaderPanel()
    emu:pump()
    emu:expectText("Not linked to Hardcover")
    emu:expectText("Link this book")
    emu:shot("reader_panel_unlinked")
    emu:closeAll()
  end,
}
