--[[--
Putting a book on your lists from its details screen, with real taps.

"Lists" sits in the action bar (only for an OAuth sign-in); it opens a picker with
a tick box per list of yours. Tapping a box adds or removes at once, one request
each (insert with the list and book ids and the end position, delete with the
list_books id); a failure puts the tick back and says so; offline sends nothing; a
sign-in known to lack the write:lists scope is told to sign out and back in, with
nothing sent. Done brings the names ("On your lists: ...") to the details, and the
lists screen underneath shows the new sizes.

Screens: add_to_list_bar, add_to_list_scope, add_to_list_picker, add_to_list_added,
add_to_list_failed, add_to_list_details, add_to_list_bar_compat.
]]

local fixtures = require("fixtures")

return {
  name = "add_to_list",

  run = function(emu)
    local UIManager = emu.UIManager
    local Api = require("hardcover/lib/hardcover_api")
    local SETTING = require("hardcover/lib/constants/settings")
    local settings = fixtures.real_settings(emu)
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    fixtures.seed_cover(fixtures.cover_url(103), 2)
    for _, b in ipairs(fixtures.series_books[12].books) do
      fixtures.seed_cover(fixtures.cover_url(b.book_id), b.book_id % 3 + 1)
    end
    fixtures.install({ settings = settings, overrides = { getShelf = function() return {}, nil, false end } })
    Api.auth = fixtures.fake_auth(true)

    -- the Z-library stand-in, so the bar is at its fullest: Shelf | Lists | Reviews | Z-library
    local plugin = {}
    function plugin:performSearch() end
    function plugin:showMultiSearchDialog() end
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings, ui = { {}, plugin } }

    local function topmost() return UIManager:getTopmostVisibleWidget() end
    -- the topmost (last drawn) node whose text contains `text`
    local function nodeWith(text)
      local found
      for _, n in ipairs(emu:screenNodes()) do
        if n.text:find(text, 1, true) then found = n end
      end
      return found
    end
    local function tapText(text)
      local node = nodeWith(text)
      assert(node, "no " .. text .. " on screen:\n" .. emu:screenText())
      emu:tapExpecting(node.x + 5, node.y + 5)
      emu:pump()
    end
    local function tapButton(button)
      UIManager:_repaint()
      local d = button.dimen
      emu:tapExpecting(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
      emu:pump()
    end
    -- Shelf and Lists are buttons of their own: `row` is "Lists", or a shelf row's text for Shelf
    local function tapAdd(dialog, row)
      tapButton(row == "Lists" and dialog.lists_button or dialog.add_button)
    end
    local function count(name)
      local n = 0
      for _, c in ipairs(fixtures.calls or {}) do if c.name == name then n = n + 1 end end
      return n
    end
    local function lastCall(name)
      for i = #(fixtures.calls or {}), 1, -1 do
        if fixtures.calls[i].name == name then return fixtures.calls[i].args end
      end
    end
    local function screenHas(text) return nodeWith(text) ~= nil end
    -- close the message on top (an InfoMessage waits for its timeout, which does not run here)
    local function dismiss(expected_under)
      local top = topmost()
      assert(top ~= expected_under, "no message was on top")
      UIManager:close(top)
      emu:pump()
      assert(topmost() == expected_under, "the message did not leave the picker on top")
    end

    manager:showBookDetail(103, 10301)
    emu:pump()
    local dialog = topmost()
    assert(dialog and dialog.name == "hardcover_book_detail", "the details did not open")
    -- close whatever is over the details (a message, a picker)
    local function dismissAll()
      emu:pump()
      while topmost() ~= dialog do
        UIManager:close(topmost())
        emu:pump()
      end
    end
    emu:expectText("The Left Hand of Darkness")

    -- the buttons: round buttons in reading order (Download, Shelf, Lists,
    -- Reviews), inside the margins, none on another
    assert(dialog.add_button and dialog.lists_button and dialog.on_lists, "no Lists to add to for an OAuth sign-in")
    emu:expectText("Shelf")
    emu:expectText("Lists")
    local M = require("hardcover/lib/ui/theme").margin
    UIManager:_repaint()
    local at = function(name) return dialog[name].dimen end
    local previous
    for _, name in ipairs({ "zlibrary_button", "add_button", "lists_button", "reviews_button" }) do
      local d = at(name)
      assert(not previous or d.y > previous.y or (d.y == previous.y and d.x > previous.x),
        "Download, Shelf, Lists, Reviews are not in reading order")
      previous = d
    end
    for _, name in ipairs({ "add_button", "lists_button", "reviews_button", "zlibrary_button" }) do
      local d = dialog[name].dimen
      assert(d and d.x >= M and d.x + d.w <= emu.Screen:getWidth() - M, name .. " is outside the margins")
    end
    emu:expectNoButtonOverlap()
    assert(not screenHas("On your lists"), "the lists were named before they were asked for")
    emu:shot("add_to_list_bar")

    -- offline: a message, no request of any kind
    local NetworkManager = require("ui/network/manager")
    local was = NetworkManager.isConnected
    NetworkManager.isConnected = function() return false end
    -- the plugin also trusts KOReader's own record of the connection, so go offline in both
    local was_state = NetworkManager.getConnectionState
    NetworkManager.getConnectionState = function() return false end
    tapAdd(dialog, "Lists")
    NetworkManager.isConnected = was
    NetworkManager.getConnectionState = was_state
    emu:expectText("offline")
    assert(count("getBookLists") == 0 and count("addToList") == 0 and count("removeFromList") == 0,
      "offline made a request")
    dismiss(dialog)

    -- a sign-in known to lack the scope: told what to do, nothing sent
    Api.auth = fixtures.fake_auth(false)
    tapAdd(dialog, "Lists")
    emu:expectText("Sign out and back in")
    emu:expectText("Settings > Account")
    assert(count("getBookLists") == 0 and count("addToList") == 0, "a sign-in without the scope made a request")
    emu:shot("add_to_list_scope")
    dismiss(dialog)

    -- the right scope: one request for the membership, then the picker
    Api.auth = fixtures.fake_auth(true)
    tapAdd(dialog, "Lists")
    local picker = topmost()
    assert(picker ~= dialog and picker.rows, "the picker did not open")
    assert(count("getBookLists") == 1 and lastCall("getBookLists").book_id == 103, "the membership was not asked for once")
    emu:expectText("Add to lists")
    emu:expectText("To Read - SciFi (7)") -- on it
    emu:expectText("Books that made me grin (4)") -- not
    emu:expectText("Research (1)")
    emu:expectText("Someday (0)")
    emu:expectText("Done")
    assert(not screenHas("Top 25"), "a followed list was offered")
    emu:shot("add_to_list_picker")

    -- ticks only mark the rows: nothing is sent, nothing is said, until Done
    tapText("Books that made me grin")
    tapText("Someday")
    assert(count("addToList") == 0, "a tick sent an insert before Done")
    assert(topmost() == picker, "the picker closed on a tick")
    emu:expectText("Books that made me grin (4)")
    emu:shot("add_to_list_picker_ticked")

    -- Back/X/outside throws them away
    UIManager:close(picker)
    emu:pump()
    assert(count("addToList") == 0, "closing the picker sent something")
    tapAdd(dialog, "Lists")
    picker = topmost()
    assert(picker ~= dialog and picker.rows, "the picker did not reopen")
    assert(count("getBookLists") == 1, "reopening asked for the lists again")

    -- Done: one insert per ticked list with the list and book ids, at the end of the list
    tapText("Books that made me grin")
    tapText("Someday")
    tapText("Done")
    assert(not UIManager:isWidgetShown(picker), "Done left the picker open")
    assert(count("addToList") == 2, "Done did not send both inserts")
    local grin, someday
    for _, c in ipairs(fixtures.calls) do
      if c.name == "addToList" and c.args.list_id == 2 then grin = c.args end
      if c.name == "addToList" and c.args.list_id == 4 then someday = c.args end
    end
    assert(grin and grin.book_id == 103 and grin.position == 4, "wrong insert for the grin list")
    assert(someday and someday.position == 0, "the empty list was not added to at position 0")
    emu:expectText("Lists updated.")
    emu:shot("add_to_list_added")

    -- untick one list: one delete with the list_books id (501, from the membership)
    dismissAll()
    tapAdd(dialog, "Lists")
    picker = topmost()
    tapText("To Read - SciFi")
    tapText("Done")
    assert(count("removeFromList") == 1 and lastCall("removeFromList").id == 501, "the delete did not carry the list_books id")
    dismissAll()

    -- a failure: reported once after Done, the list stays as it was
    fixtures.list_write_fail = "List not found"
    tapAdd(dialog, "Lists")
    picker = topmost()
    tapText("Research")
    tapText("Done")
    emu:expectText("Could not change")
    emu:expectText("List not found")
    emu:shot("add_to_list_failed")
    fixtures.list_write_fail = nil
    dismissAll()

    -- a refusal for the scope gives the sign-in message
    fixtures.list_write_fail = { errors = { "insufficient_scope" }, status = 403 }
    tapAdd(dialog, "Lists")
    picker = topmost()
    tapText("Someday")
    tapText("Done")
    emu:expectText("Sign out and back in")
    fixtures.list_write_fail = nil
    dismissAll()
    tapAdd(dialog, "Lists")
    picker = topmost()

    -- the lists screen, if it is underneath, follows: here only the picker/details are
    -- on the stack, so nothing to refresh and nothing raised
    tapText("Done")
    assert(not UIManager:isWidgetShown(picker), "Done left the picker open")
    dismissAll()
    assert(topmost() == dialog, "Done did not return to the details")
    emu:expectText("On your lists: Books that made me grin, Research, Someday")
    assert(not screenHas("To Read - SciFi"), "a list the book left is still named")
    assert(dialog.cover_bb, "the cover was lost in the update")
    emu:shot("add_to_list_details")

    -- opening again asks nothing: the membership is already on the screen
    local asked = count("getBookLists")
    tapAdd(dialog, "Lists")
    assert(count("getBookLists") == asked, "the picker asked for the lists again")
    emu:expectText("Books that made me grin (5)")
    UIManager:close(topmost())
    emu:pump()
    emu:closeAll()

    -- the lists screen underneath shows the new sizes
    manager = DialogManager:new { settings = settings, ui = { {}, plugin } }
    manager:showLists()
    emu:pump()
    local lists_screen = manager.lists_dialog
    assert(lists_screen and UIManager:isWidgetShown(lists_screen), "the lists screen did not open")
    manager:showBookDetail(103, 10301)
    emu:pump()
    dialog = topmost()
    tapAdd(dialog, "Lists")
    picker = topmost()
    tapText("Someday")
    tapText("Done")
    local row
    for _, r in ipairs(lists_screen.mine) do if r.id == 4 then row = r end end
    -- Someday was added above, so the lists screen starts at 1 and Done takes it off: 0
    assert(row and row.count == 0, "the lists screen was not told Someday now holds 0: " .. tostring(row and row.count))
    emu:closeAll()

    -- compatibility mode: the same bar, still all the buttons fit
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, true)
    manager = DialogManager:new { settings = settings, ui = { {}, plugin } }
    manager:showBookDetail(103, 10301)
    emu:pump()
    dialog = topmost()
    assert(dialog.add_button and dialog.zlibrary_button, "the bar lost a button in compatibility mode")
    UIManager:_repaint()
    for _, name in ipairs({ "add_button", "lists_button", "reviews_button", "zlibrary_button" }) do
      local d = dialog[name].dimen
      assert(d and d.x >= M and d.x + d.w <= emu.Screen:getWidth() - M, name .. " is outside the margins (compat)")
    end
    emu:expectNoButtonOverlap()
    emu:shot("add_to_list_bar_compat")
    emu:closeAll()

    -- no OAuth sign-in (a personal token, or none): no Lists button
    Api.auth = nil
    manager = DialogManager:new { settings = settings, ui = { {}, plugin } }
    manager:showBookDetail(103, 10301)
    emu:pump()
    dialog = topmost()
    assert(dialog.add_button and dialog.on_lists == nil, "Lists offered without an OAuth sign-in")
    assert(dialog.lists_button == nil, "a Lists button without an OAuth sign-in")
    emu:closeAll()
  end,
}
