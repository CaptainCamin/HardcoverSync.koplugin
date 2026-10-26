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
  fixtures.seed_cover(fixtures.cover_url(328491))
  local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
  local dialog_manager = require("hardcover/lib/ui/dialog_manager"):new({ book_store = { rows = function()
    return { [328491] = { cached_image = { url = fixtures.cover_url(328491) } } }
  end } })
  function dialog_manager:showHomeBody(host)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")
    return CenterContainer:new { dimen = Geom:new { w = host.width, h = host.height },
      require("hardcover/lib/ui/theme").mmdText("Home opened from reader", "strong", 24) }
  end
  local menu = HardcoverMenu:new({
    settings = settings,
    enabled = true,
    ui = { document = { file = "/books/x.epub" }, doc_props = { display_title = "x" } },
    state = { book_status = linked and {
      id = 1, status_id = 2, rating = 4.5,
      user_book_reads = { { progress_pages = 142 } },
    } or {} },
    cache = { cacheUserBook = function() end },
    sync_queue = { pendingCount = function() return 0 end, changeCount = function() return 0 end,
      hasPending = function() return false end,
      get = function() return nil end },
    auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
             statusText = function() return "Signed in" end },
    dialog_manager = dialog_manager, hardcover = {},
  })
  return menu
end

return {
  name = "reader_panel",

  run = function(emu)
    local menu = build(emu, true)
    menu:showReaderPanel()
    emu:pump()
    emu:expectText("The Dispossessed")
    emu:expectText("Page 142 of 387")
    for _, label in ipairs({ "Progress", "Status", "Rate", "Journal", "Details" }) do emu:expectText(label) end
    assert(not emu:screenText():find("Update Hardcover as I read", 1, true))
    emu:expectNoButtonOverlap()
    emu:shot("reader_panel")
    menu.settings.getLinkedTitle = function() return "The Dispossessed: A Very Long Book Title That Must Leave Room for Both Top Controls" end
    menu.reader_panel:render()
    emu:pump()
    emu:screenNodes()
    emu:expectNoButtonOverlap()
    local gear, close = menu.reader_panel.gear.dimen, menu.reader_panel.close_button.dimen
    assert(gear.x + gear.w <= close.x, "options and close targets overlap")
    emu:shot("reader_panel_long_title")

    emu:tapExpecting(gear.x + math.floor(gear.w / 2), gear.y + math.floor(gear.h / 2))
    local home = emu:expectText("Hardcover Home")
    emu:expectText("Unlink book")
    emu:expectText("All Hardcover settings")
    assert(not emu:screenText():find("Link a different book", 1, true),
      "linked book's options still offer Link a different book")
    emu:shot("reader_panel_options")
    emu:tapExpecting(home.x + math.floor(home.w / 2), home.y + math.floor(home.h / 2))
    local shell = emu:top()
    assert(shell and shell.name == "hardcover_shell" and shell.active == "home",
      "Hardcover Home did not open the Home tab")
    emu:expectText("Home opened from reader")
    assert(not emu.UIManager:isWidgetShown(menu.reader_panel), "opening Home left the reader panel open")
    emu:closeAll()

    menu = build(emu, false)
    menu:showReaderPanel()
    emu:pump()
    emu:expectText("Not linked to Hardcover")
    emu:expectText("Link this book")
    emu:shot("reader_panel_unlinked")
    gear = menu.reader_panel.gear.dimen
    emu:tapExpecting(gear.x + math.floor(gear.w / 2), gear.y + math.floor(gear.h / 2))
    home = emu:expectText("Hardcover Home")
    emu:expectText("Link this book")
    assert(not emu:screenText():find("Unlink book", 1, true), "unlinked book has an Unlink action")
    emu:expectText("All Hardcover settings")
    emu:shot("reader_panel_unlinked_options")
    emu:tapExpecting(home.x + math.floor(home.w / 2), home.y + math.floor(home.h / 2))
    shell = emu:top()
    assert(shell and shell.name == "hardcover_shell" and shell.active == "home",
      "unlinked book's menu did not open the Home tab")
    emu:expectText("Home opened from reader")
    assert(not emu.UIManager:isWidgetShown(menu.reader_panel), "Home left the unlinked reader panel open")
    emu:closeAll()
  end,
}
