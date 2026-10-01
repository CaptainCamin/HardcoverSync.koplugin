--[[--
Shelf list: the Want to Read screen, on the real Menu widget.

This is the screen that crashed on device -- rows were drawn through ListMenu's
folder branch because no item carried a file marker. A PNG looks the same
whether the marker is present or not, so the assertions inspect the built item
table and the collected text nodes; the PNGs are for what only pixels show
(truncation, spacing, cover placement).

Screens: shelf_page1, shelf_page2.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

return {
  name = "shelf",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local HARDCOVER = require("hardcover/lib/constants/hardcover")

    local manager = DialogManager:new{ settings = settings }

    -- Go through the plugin's own entry point, not ShelfDialog directly: the
    -- path that broke on device started at showShelf.
    manager:showShelf(HARDCOVER.STATUS.TO_READ, "Want to Read")
    emu:pump()

    local dialog = manager.shelf_dialog
    assert(dialog, "showShelf did not produce a dialog")
    assert(UIManager:isWidgetShown(dialog), "dialog was built but never shown")

    local menu = dialog.menu

    --[[--
    The regression this screen exists for: every row must carry a file marker,
    or ListMenu draws it as a folder. Asserted on the item table because that
    is the input the branch actually tests.
    ]]
    local items = menu.item_table
    assert(#items > 0, "shelf rendered with no rows")
    for i, item in ipairs(items) do
      assert(item.file, string.format(
        "row %d (%s) has no file marker: ListMenu will draw it as a folder",
        i, tostring(item.text)))
    end

    -- Covers and status labels come straight from the API response, so a
    -- fixture change that breaks that mapping surfaces here.
    assert(items[1].cover_url, "first row lost its cover url")
    assert(items[1].mandatory, "first row lost its status label")

    -- The title has to be on screen; if the dialog silently failed to build its
    -- menu, that is where it shows.
    emu:expectText("Want to Read")

    --[[
    The synthetic file marker must never appear in the painted text.

    It used to: every row printed "hardcover-201" between its title and its
    status label. vendored/listmenu.lua:277 sets bookinfo = self.entry and :502
    renders title = bookinfo.title or filename_without_suffix, and
    filename_without_suffix is parsed out of entry.file -- so a row carrying the
    marker but no `title` prints the marker as the book's name.

    Asserted on the rendered text rather than the item table on purpose. The
    item table is correct in the broken case too -- it has a `file` and a
    `mandatory`, exactly as it should -- which is why this went unnoticed until
    a text dump was read. A stub harness checking row fields cannot see it; only
    the painted output can.
    ]]
    local painted = emu:screenText()
    assert(not painted:find("hardcover-", 1, true),
           "the synthetic file marker is being painted as a book name:\n" .. painted)

    local _, nodes = emu:shot("shelf_page1")

    --[[--
    The `file` marker must never reach the screen.

    Rows carry file = "hardcover-<book_id>" so the vendored ListMenu draws them
    through the book branch rather than the directory branch -- the branch that
    crashed both shelf views. ListMenu also derives a row's display name from
    that same field:

        title = bookinfo.title and bookinfo.title or filename_without_suffix

    where filename_without_suffix is parsed out of `file`. So marking a row
    without also setting `title` makes the marker the visible book name, and
    every row reads "hardcover-201".

    This is the class of bug a stub harness cannot see: the item table is
    correct in every field, the table-level assertions all pass, and only the
    painted text is wrong. Assert on what was drawn.
    NOTE: this comment is closed on purpose. The file header at line 1 opens a
    long block comment that runs to EOF, so anything added after it silently never
    executes -- which is exactly how the first version of this guard passed
    against broken code.
    ]]--
    local painted = emu:screenText()
    assert(not painted:find("hardcover-", 1, true), string.format(
      "the internal file marker leaked onto the screen: %s",
      painted:match("[^\n]*hardcover-[^\n]*") or "?"))
    assert(painted:find("The Lathe of Heaven", 1, true),
      "no book title on screen -- the list is not rendering its rows")

    --[[--
    Paging, and why the guard is there.

    Menu:onNextPage cycles back to page 1 when there is only one page, so a
    NextPage assertion on a short list passes while proving nothing. Assert the
    menu really has more than one page first -- if a fixture change ever shrinks
    the shelf, this fails loudly instead of silently gutting the check.
    ]]
    assert(menu.page_num > 1, string.format(
      "shelf has %d rows and fits on one page (%s); paging is untested",
      #items, tostring(menu.page_num)))

    local page1_text = emu:screenText()
    emu:press("NextPage")
    local page2_text = emu:screenText()

    assert(menu.page == 2, string.format(
      "NextPage did not advance: still on page %s of %s",
      tostring(menu.page), tostring(menu.page_num)))
    assert(page1_text ~= page2_text,
      "page 2 shows exactly the same text as page 1 -- paging changed nothing")

    emu:shot("shelf_page2")

    -- Rows drawn off the edge of the panel are a layout fault. Only nodes with
    -- absolute coordinates can be checked; see the note in book_detail.lua.
    local Screen = emu.Screen
    local W, H = Screen:getWidth(), Screen:getHeight()
    for _, node in ipairs(nodes) do
      if not node.relative and node.x and node.y then
        assert(node.x >= 0 and node.y >= 0, string.format(
          "text %q drawn at negative offset (%d,%d)", node.text, node.x, node.y))
        assert(node.x + node.w <= W + 1, string.format(
          "text %q runs past the right edge (%d+%d > %d)", node.text, node.x, node.w, W))
        assert(node.y + node.h <= H + 1, string.format(
          "text %q runs past the bottom edge (%d+%d > %d)", node.text, node.y, node.h, H))
      end
    end

    print(string.format("  %d rows, %d pages, all with file markers",
      #items, menu.page_num))
  end,
}