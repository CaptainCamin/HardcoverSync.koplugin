--[[--
Shelf list: the Want to Read screen, our own paged list (mock 3).

The screen is built a page at a time: the top bar (back arrow, title, sort icon), fixed-height rows
(cover, title, author, a chevron), the scroll control at the right edge, a footer saying which books
are on show. A PNG shows spacing and placement; the assertions read the dialog's own state and the
painted text.

Screens: shelf_page1, shelf_page2, shelf_sort_menu, shelf_sorted_title.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

return {
  name = "shelf",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    -- covers for the shelf's books (every seventh has none), from the real cache
    for _, b in ipairs(fixtures.shelf_books) do
      local image = b.cached_image
      if image and image.url then fixtures.seed_cover(image.url, b.book_id % 3 + 1) end
    end
    -- the emulated settings file outlives a run: start from the default order
    settings:updateSetting(require("hardcover/lib/constants/settings").SHELF_SORT, nil)
    fixtures.install({ settings = settings })

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local HARDCOVER = require("hardcover/lib/constants/hardcover")

    local manager = DialogManager:new{ settings = settings }

    -- Go through the plugin's own entry point, not ShelfDialog directly.
    manager:showShelf(HARDCOVER.STATUS.TO_READ, "Want to Read")
    emu:pump()

    local dialog = manager.shelf_dialog
    assert(dialog, "showShelf did not produce a dialog")
    assert(UIManager:isWidgetShown(dialog), "dialog was built but never shown")

    local items = dialog.items
    assert(#items > 0, "shelf rendered with no rows")
    assert(items[1].row.cover_url, "first row lost its cover url")
    local rated = false
    for _, item in ipairs(items) do rated = rated or item.rating ~= nil end
    assert(rated, "no row shows a rating (the fixture has rated books)")

    -- the title and the first rows are on screen, and nothing internal is painted
    emu:expectText("Want to Read")
    local painted = emu:screenText()
    assert(not painted:find("hardcover-", 1, true), "an internal file marker is painted:\n" .. painted)
    assert(not painted:find("%(19%d%d%)"), "the year is back on the shelf rows")
    assert(painted:find("The Lathe of Heaven", 1, true), "no book title on screen -- the list is not rendering its rows")
    -- the footer says which books are on show
    assert(painted:find("Showing 1 to " .. #dialog.rows, 1, true), "no footer saying which books are on show:\n" .. painted)

    -- one page of rows is built, never the whole shelf
    assert(dialog.pages > 1, string.format("the shelf has %d rows and fits on one page; paging is untested", #items))
    assert(#dialog.rows == dialog.per_page, "built " .. #dialog.rows .. " rows for a page of " .. dialog.per_page)
    assert(#dialog.rows < #items, "every row was built")
    local _, nodes = emu:shot("shelf_page1")

    -- fixed-height rows
    emu:screenNodes()
    local first, second = dialog.rows[1].dimen, dialog.rows[2].dimen
    assert(second.y - first.y == first.h + require("hardcover/lib/ui/theme").line.hair, "the rows are not one height")
    assert(first.h >= require("hardcover/lib/ui/theme").TOUCH_MIN, "a row is too short to touch")

    -- paging: the key, then the scroll control's triangle, then the swipe
    local page1_text = emu:screenText()
    emu:press("NextPage")
    assert(dialog.page == 2, "NextPage did not advance: page " .. tostring(dialog.page))
    assert(page1_text ~= emu:screenText(), "page 2 shows exactly the same text as page 1")
    assert(emu:screenText():find("Showing " .. (dialog.per_page + 1) .. " to", 1, true), "the footer did not move on")
    emu:shot("shelf_page2")
    local W, H = emu.Screen:getWidth(), emu.Screen:getHeight()
    emu:screenNodes()
    emu:tapExpecting(W - 10, dialog.body_region.y + 20) -- the up triangle
    emu:pump()
    assert(dialog.page == 1, "the up triangle did not go back a page")
    emu:screenNodes()
    emu:tapExpecting(W - 10, H - 20) -- the down triangle
    emu:pump()
    assert(dialog.page == 2, "the down triangle did not turn the page")
    local Time = require("ui/time")
    local function swipe(direction)
      local gesture = { ges = "swipe", direction = direction, time = Time.now(),
        pos = require("ui/geometry"):new { x = math.floor(W / 2), y = math.floor(H / 2), w = 0, h = 0 } }
      local consumed = emu.UIManager:getTopmostVisibleWidget():handleEvent(emu.Event:new("Gesture", gesture))
      emu:pump()
      return consumed
    end
    assert(swipe("south") and dialog.page == 1, "a swipe down did not go back a page")
    assert(swipe("north") and dialog.page == 2, "a swipe up did not turn the page")
    emu:press("PrevPage")
    assert(dialog.page == 1, "PrevPage did not go back")

    -- nothing is drawn off the edge of the panel
    for _, node in ipairs(nodes) do
      if not node.relative and node.x and node.y then
        assert(node.x >= 0 and node.y >= 0, string.format("text %q drawn at negative offset (%d,%d)", node.text, node.x, node.y))
        assert(node.x + node.w <= W + 1, string.format("text %q runs past the right edge (%d+%d > %d)", node.text, node.x, node.w, W))
        assert(node.y + node.h <= H + 1, string.format("text %q runs past the bottom edge (%d+%d > %d)", node.text, node.y, node.h, H))
      end
    end
    print(string.format("  %d rows, %d pages of %d", #items, dialog.pages, dialog.per_page))

    -- a tap on a row opens that book's details
    emu:screenNodes()
    local row = dialog.rows[1].dimen
    emu:tapExpecting(row.x + math.floor(row.w / 2), row.y + math.floor(row.h / 2))
    emu:pump()
    local opened = emu.UIManager:getTopmostVisibleWidget()
    assert(opened ~= dialog and opened.name == "hardcover_book_detail", "tapping a row did not open the book")
    emu.UIManager:close(opened)
    emu:pump()

    --[[--
    Sorting. The sort icon in the top bar opens a popover under it; choosing Title re-orders the rows
    (articles ignored, so "Babel" before "The Lathe of Heaven"), with real taps, and the order is
    remembered for the next time the shelf opens.
    ]]
    emu:screenNodes()
    local sort = dialog.sort_button
    assert(sort and sort.dimen and sort.dimen.w > 0, "the shelf has no sort button")
    emu:tapExpecting(sort.dimen.x + math.floor(sort.dimen.w / 2), sort.dimen.y + math.floor(sort.dimen.h / 2))
    emu:pump()
    assert(dialog.sort_menu, "the sort icon opened no menu")
    emu:expectText("Date added (newest first)")
    emu:shot("shelf_sort_menu")

    local choice = emu:expectText("Title (A")
    emu:tapExpecting(choice.x + 5, choice.y + 5)
    emu:pump()
    assert(dialog.items[1].row.title == "Babel", "sorting by title left " .. tostring(dialog.items[1].row.title) .. " first")
    emu:expectText("Babel")
    emu:expectText("Want to Read \194\183 Title")
    emu:shot("shelf_sorted_title")

    local saved = settings:readSetting(require("hardcover/lib/constants/settings").SHELF_SORT)
    assert(type(saved) == "table" and saved[tostring(HARDCOVER.STATUS.TO_READ)] == "title", "the choice was not remembered")

    -- opened again, it keeps that order
    emu:closeAll()
    manager:showShelf(HARDCOVER.STATUS.TO_READ, "Want to Read")
    emu:pump()
    assert(manager.shelf_dialog.items[1].row.title == "Babel", "the remembered order was not applied")
    emu:closeAll()

    -- a list that is not all here ends with Load more; tapping it fetches the next books and moves on
    local ShelfDialog = require("hardcover/lib/ui/shelf_dialog")
    local first, rest = {}, {}
    for i, b in ipairs(fixtures.shelf_books) do
      if i <= 6 then first[#first + 1] = b else rest[#rest + 1] = b end
    end
    local asked
    local before = #first
    local more = ShelfDialog:new {
      title = "A long list", entries = first, has_more = true, offset = #first, page_size = 20,
      fetch_page = function(offset, limit, callback) asked = { offset, limit }; callback(rest, nil, false) end,
      select_entry_cb = function() end,
    }
    UIManager:show(more)
    emu:pump()
    assert(more.more_button, "no Load more block")
    local last_page = more.pages
    if more.page < last_page then
      more:setPage(last_page)
      emu:pump()
    end
    emu:expectText("Load more books")
    emu:shot("shelf_load_more")
    emu:screenNodes()
    local b = more.more_button.dimen
    emu:tapExpecting(b.x + math.floor(b.w / 2), b.y + math.floor(b.h / 2))
    emu:pump()
    assert(asked and asked[1] == before, "asked for the next books from " .. tostring(asked and asked[1]))
    assert(#more.entries == before + #rest and not more.has_more and more.more_button == nil, "the rows were not added")
    assert(more.page == math.floor(before / more.per_page) + 1, "did not go to the first new row, page " .. more.page)
    emu:shot("shelf_loaded_more")
    emu:closeAll()
  end,
}
