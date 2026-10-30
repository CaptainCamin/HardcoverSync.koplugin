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
    ui = { document = { file = "/books/x.epub" }, doc_props = { display_title = "x" },
      getCurrentPage = function() return 120 end },
    state = { book_status = linked and {
      id = 1, status_id = 2, rating = 4.5,
      user_book_reads = { { progress_pages = 142 } },
    } or {} },
    cache = { cacheUserBook = function() end },
    sync_queue = { pendingCount = function() return 0 end, changeCount = function() return 0 end,
      hasPending = function() return false end,
      get = function() return nil end, statusOf = function() return nil end },
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

    -- Before the first sync: no library record, a locally chosen reading status, and real queues
    -- persisted to disk. Exercise the reader's buttons, not just the queue methods.
    local NetworkManager = require("ui/network/manager")
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end
    menu = build(emu, true)
    menu.state.book_status = { book_id = 328491 }
    menu.settings.readBookSettings = function()
      return { book_id = 328491, title = "The Dispossessed", edition_id = 10100, edition_format = "Paperback" }
    end
    menu.ui.document.getPageCount = function() return 387 end
    local LuaSettings = require("luasettings")
    local path = emu.DataStorage:getSettingsDir() .. "/first_sync_queue.lua"
    os.remove(path)
    local queue_settings = LuaSettings:open(path)
    menu.rating_queue = require("hardcover/lib/rating_queue"):new { settings = queue_settings }
    local dm = menu.dialog_manager
    dm.settings, dm.rating_queue = menu.settings, menu.rating_queue
    dm.page_mapper = { getMappedPage = function(_, page, pages, remote_pages)
      assert(page == 120 and pages == 387 and remote_pages == 387)
      return 200
    end }
    dm.journal_queue = require("hardcover/lib/journal_queue"):new { settings = queue_settings }
    dm.review_queue = require("hardcover/lib/review_queue"):new { settings = queue_settings }
    dm.shelf_queue = require("hardcover/lib/shelf_queue"):new { settings = queue_settings }
    menu.shelf_queue = dm.shelf_queue
    local db_path = emu.DataStorage:getSettingsDir() .. "/first_sync_library.sqlite3"
    for _, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do os.remove(db_path .. suffix) end
    local db = require("hardcover/lib/sqlite_store"):new { path = db_path }
    dm.book_store = require("hardcover/lib/book_store"):new { db = db }
    dm.shelf_store = require("hardcover/lib/shelf_store"):new { db = db, books = dm.book_store }

    local function dismissNotes()
      for i = #emu.UIManager._window_stack, 1, -1 do
        local w = emu.UIManager._window_stack[i].widget
        if w.toast or w.snackbar then emu.UIManager:close(w) end
      end
      emu:pump()
    end
    local function tapText(label)
      dismissNotes()
      local node = emu:expectText(label)
      emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
      emu:pump()
    end
    local function findCallback(root, callback, seen)
      if type(root) ~= "table" then return end
      seen = seen or {}
      if seen[root] then return end
      seen[root] = true
      if root.callback == callback and root.dimen then return root end
      for _, child in pairs(root) do
        local found = findCallback(child, callback, seen)
        if found then return found end
      end
    end
    -- Choose the shelf from Details, which updates the saved shelves but not the reader snapshot.
    local detail = require("hardcover/lib/ui/book_detail_dialog"):new {
      detail = { book = { book_id = 328491, title = "The Dispossessed", pages = 387,
        cached_image = { url = fixtures.cover_url(328491) } } },
      on_shelf = function(d) dm:chooseShelf(d) end,
    }
    emu.UIManager:show(detail)
    emu:pump()
    emu:screenNodes()
    local shelf_button = detail.add_button.dimen
    emu:tapExpecting(shelf_button.x + math.floor(shelf_button.w / 2), shelf_button.y + math.floor(shelf_button.h / 2))
    emu:pump()
    tapText("Currently Reading")
    dismissNotes()
    assert(detail.detail.status_id == 2 and menu.state.book_status.status_id == nil)
    emu:closeAll()
    menu:showReaderPanel()
    emu:pump()
    tapText("Rate")
    emu:expectText("Set rating")
    emu:shot("reader_first_sync_rating")
    tapText("Save")
    dismissNotes()
    assert(menu.rating_queue:get(nil, 328491) == 2.5, "rating was not kept without a library record")
    -- Simulate reopening from an older snapshot: the queue must win.
    emu:closeAll()
    menu.state.book_status.rating = nil
    menu:showReaderPanel()
    emu:pump()
    emu:expectText("2.5")
    emu:shot("reader_first_sync")
    tapText("Journal")
    local journal = emu:top()
    assert(journal.name == "hardcover_journal_screen", "Journal is still disabled before first sync")
    emu:expectText("You can add an entry offline.")
    emu:shot("reader_first_sync_empty_journal")
    local function addEntry(label)
      dismissNotes()
      emu:screenNodes()
      local fab = findCallback(journal, journal.add_cb)
      assert(fab, "no Add entry control")
      local d = fab.dimen
      emu:tapExpecting(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
      emu:pump()
      tapText(label)
    end
    addEntry("Note")
    local editor = emu:top()
    -- KOReader may put the virtual keyboard above its editor.
    for _, window in ipairs(emu.UIManager._window_stack) do
      if window.widget.name == "hardcover_input_dialog" then editor = window.widget end
    end
    editor:setInputText("Written before my first sync.")
    editor:onCloseKeyboard()
    emu:pump()
    tapText("Done")
    emu:expectText("Page 200 of 387")
    tapText("Save")
    dismissNotes()
    assert(dm.journal_queue:count() == 1 and dm.journal_queue:list()[1].book_id == 328491
      and dm.journal_queue:list()[1].page == 200)
    emu:expectText("Written before my first sync.")
    addEntry("Review")
    editor = emu:top()
    for _, window in ipairs(emu.UIManager._window_stack) do
      if window.widget.name == "hardcover_input_dialog" then editor = window.widget end
    end
    editor:setInputText("A review saved entirely offline.")
    editor:onCloseKeyboard()
    emu:pump()
    tapText("Next")
    tapText("No spoilers")
    dismissNotes()
    assert(dm.review_queue:get(nil, 328491).text == "A review saved entirely offline.")
    emu:expectText("Waiting to send")
    emu:shot("reader_first_sync_journal")
    assert(menu.state.book_status.id == nil and #fixtures.calls == 0, "offline actions made requests")
    queue_settings:close()
    local restored = LuaSettings:open(path)
    assert(require("hardcover/lib/rating_queue"):new { settings = restored }:get(nil, 328491) == 2.5)
    assert(require("hardcover/lib/journal_queue"):new { settings = restored }:list()[1].text == "Written before my first sync.")
    assert(require("hardcover/lib/review_queue"):new { settings = restored }:get(nil, 328491).text == "A review saved entirely offline.")
    restored:close()
    emu:closeAll()
    db:close()
  end,
}
