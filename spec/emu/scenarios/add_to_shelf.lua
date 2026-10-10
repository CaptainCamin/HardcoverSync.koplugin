--[[--
Putting a book on a shelf from its details screen, with real taps.

A book the reader has not shelved opens with "Add to shelf"; choosing a status
sets it (the status line and the button label follow, the cover and scroll
position stay), another choice changes it, "Remove from library" asks first, and
offline nothing is requested. The saved shelves are dropped so they are not
stale.

Screens: add_to_shelf_new, add_to_shelf_picker, add_to_shelf_want,
add_to_shelf_read, add_to_shelf_remove_confirm, add_to_shelf_removed.
]]

local fixtures = require("fixtures")

return {
  name = "add_to_shelf",

  run = function(emu)
    local UIManager = emu.UIManager
    local settings = fixtures.real_settings(emu)
    fixtures.seed_cover(fixtures.cover_url(108), 2)
    fixtures.install({
      settings = settings,
      overrides = { getShelf = function() return {}, nil, false end },
    })

    local ShelfCache = require("hardcover/lib/shelf_cache")
    local cache = ShelfCache:new {
      path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_add_to_shelf.lua",
      open = function(path) return require("luasettings"):open(path) end,
    }
    cache:clear()
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings, shelf_cache = cache }

    local function topmost() return UIManager:getTopmostVisibleWidget() end
    -- the topmost (last drawn) node whose text is exactly `text`: "Read" is also
    -- part of "Want to Read" on the screen underneath
    local function tapText(text)
      UIManager:_repaint() -- positions are only real once painted
      local node
      for _, n in ipairs(emu:screenNodes()) do
        if n.text == text then node = n end
      end
      assert(node, "no " .. text .. " on screen:\n" .. emu:screenText())
      emu:tapExpecting(node.x + 5, node.y + 5)
      emu:pump()
    end
    local function tapButton(button)
      UIManager:_repaint() -- so the button has its place on screen
      local d = button.dimen
      emu:tapExpecting(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
      emu:pump()
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
    local function screenHas(text)
      return emu:screenText():find(text, 1, true) ~= nil
    end

    -- a saved shelf and counts that the change must make wrong
    local USER = 4242
    cache:put(USER, 1, { { book_id = 7, title = "Seven", status_id = 1 } }, true)
    cache:put(USER, 3, { { book_id = 8, title = "Eight", status_id = 3 } }, true)
    cache:put(USER, 5, { { book_id = 9, title = "Nine", status_id = 5 } }, true)
    cache:putCounts(USER, { [1] = 1, [3] = 1, [5] = 1 })

    manager:showBookDetail(108)
    emu:pump()
    local dialog = topmost()
    assert(dialog and dialog.name == "hardcover_book_detail", "the details did not open")
    emu:expectText("The Obelisk Gate")
    emu:expectText("Add to shelf")
    assert(not screenHas("Currently Reading"), "a book not in the library shows a status")
    assert(not dialog.detail.user_book_id, "a book not in the library has a library record")
    emu:shot("add_to_shelf_new")

    -- offline: a message, no picker, no request
    local NetworkManager = require("ui/network/manager")
    local was = NetworkManager.isConnected
    NetworkManager.isConnected = function() return false end
    -- the plugin also trusts KOReader's own record of the connection, so go offline in both
    local was_state = NetworkManager.getConnectionState
    NetworkManager.getConnectionState = function() return false end
    tapButton(dialog.shelf_button)
    NetworkManager.isConnected = was
    NetworkManager.getConnectionState = was_state
    emu:expectText("offline")
    assert(count("updateUserBook") == 0, "offline made a request")
    emu:closeAll()
    manager:showBookDetail(108)
    emu:pump()
    dialog = topmost()

    -- the picker lists the four shelves, and no Remove for a book not in the library
    tapButton(dialog.shelf_button)
    for _, label in ipairs({ "Want to Read", "Currently Reading", "Read", "Did Not Finish" }) do
      emu:expectText(label)
    end
    assert(not screenHas("Remove from library"), "Remove is offered for a book not in the library")
    emu:shot("add_to_shelf_picker")

    -- Want to Read
    tapText("Want to Read")
    assert(topmost() == dialog, "the picker was left open")
    assert(count("updateUserBook") == 1, "no request was made")
    local sent = lastCall("updateUserBook")
    assert(sent.book_id == 108 and sent.status_id == 1, "sent the wrong status: " .. tostring(sent.status_id))
    emu:expectText("Change shelf")
    emu:expectText("Want to Read")
    assert(not screenHas("Add to shelf"), "the button still says Add to shelf")
    assert(dialog.detail.status_id == 1 and dialog.detail.user_book_id == 9108)
    emu:shot("add_to_shelf_want")

    -- the old and new shelves were dropped, the others kept
    assert(cache:get(USER, 1) == nil, "the Want to Read shelf was left stale")
    assert(cache:get(USER, 3) ~= nil, "an unrelated shelf was dropped")
    assert(next(cache:counts(USER, { 1, 3, 5 })) ~= nil)
    assert(cache:counts(USER, { 1 })[1] == nil, "the count was left stale")

    -- the cover survived the in-place update
    assert(dialog.cover_bb, "the cover was lost")

    -- change to Read; choosing the current status again does nothing
    tapButton(dialog.shelf_button)
    tapText("Read")
    assert(count("updateUserBook") == 2 and lastCall("updateUserBook").status_id == 3,
      "Read was not sent as status 3")
    emu:expectText("Change shelf")
    assert(cache:get(USER, 3) == nil, "the Read shelf was left stale")
    emu:shot("add_to_shelf_read")

    tapButton(dialog.shelf_button)
    emu:expectText("Remove from library")
    -- the bullet-marked current choice closes the picker without a request
    local current = emu:expectText("\226\128\162 Read")
    emu:tapExpecting(current.x + 5, current.y + 5)
    emu:pump()
    assert(count("updateUserBook") == 2, "choosing the current status made a request")

    -- remove: asks first, and Cancel keeps the book
    tapButton(dialog.shelf_button)
    tapText("Remove from library")
    assert(count("removeUserBook") == 0, "removed without asking")
    emu:expectText("Remove \"The Obelisk Gate\" from your library?")
    emu:shot("add_to_shelf_remove_confirm")
    tapText("Cancel")
    assert(count("removeUserBook") == 0, "Cancel removed the book")
    emu:expectText("Change shelf")

    tapButton(dialog.shelf_button)
    tapText("Remove from library")
    tapText("Remove")
    assert(count("removeUserBook") == 1, "the removal was not requested")
    assert(lastCall("removeUserBook").user_book_id == 9108, "removed the wrong record")
    emu:expectText("Add to shelf")
    emu:expectText("Not on a shelf")
    assert(not screenHas("Change shelf"), "the label was not updated")
    assert(dialog.detail.user_book_id == nil and dialog.detail.status_id == nil)
    emu:shot("add_to_shelf_removed")

    -- Close still works
    UIManager:_repaint()
    local c = dialog.close_button.dimen
    emu:tap(c.x + math.floor(c.w / 2), c.y + math.floor(c.h / 2))
    assert(not UIManager:isWidgetShown(dialog), "Close did not close the details")
    emu:closeAll()
  end,
}
