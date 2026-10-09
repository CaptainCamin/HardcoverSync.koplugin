--[[--
The footer's "Page 1 of N" button on the shelf, with real taps.

Tapping it opens a "Go to page" box. Go jumps to the typed page, Cancel closes
the box and leaves the page where it was, and a number past the last page goes
to the last page.

Screens: page_box_open, page_box_last.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

-- the node whose text is exactly `text` (the last one: dialogs draw on top)
local function exact(emu, text)
  local found
  for _, node in ipairs(emu:screenNodes()) do
    if node.text == text then found = node end
  end
  assert(found, "no '" .. text .. "' on screen:\n" .. emu:screenText())
  return found
end

return {
  name = "page_box",

  run = function(emu)
    local SETTINGS = require("hardcover/lib/constants/settings")
    local HARDCOVER = require("hardcover/lib/constants/hardcover")

    local settings = fixtures.real_settings(emu)
    for _, b in ipairs(fixtures.shelf_books) do
      local image = b.cached_image
      if image and image.url then fixtures.seed_cover(image.url, b.book_id % 3 + 1) end
    end
    settings:updateSetting(SETTINGS.SHELF_SORT, nil)
    settings:updateSetting(SETTINGS.COMPATIBILITY_MODE, false)
    fixtures.install({ settings = settings })

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new{ settings = settings }
    manager:showShelf(HARDCOVER.STATUS.TO_READ, "Want to Read")
    emu:pump()

    local menu = manager.shelf_dialog.menu
    -- the jump checks below mean nothing on a list with one page or two
    assert(menu.page_num > 2, string.format(
      "shelf has %d pages; the page box needs more than two to test a jump",
      menu.page_num))

    -- tap the footer's "Page n of N" and return the box it opened
    local function openBox()
      local footer = menu.page_info_text
      emu:expectText(string.format("Page %d of %d", menu.page, menu.page_num))
      emu:tapExpecting(footer.dimen.x + 5, footer.dimen.y + 5)
      local box = emu:top()
      assert(box and box.getInputText, "the footer opened nothing, top is " .. tostring(box and box.name))
      assert(box == footer.input_dialog, "the box is not the one the footer tracks")
      assert(box.title == "Go to page", "the box is titled " .. tostring(box.title))
      return box
    end

    -- Go: the typed page is shown and the box closes
    local box = openBox()
    emu:expectText("1 - " .. menu.page_num)
    emu:shot("page_box_open")
    box:setInputText("2")
    local go = exact(emu, "Go")
    emu:tapExpecting(go.x + 5, go.y + 5)
    assert(menu.page == 2, "Go to page 2 left the menu on page " .. tostring(menu.page))
    assert(not UIManager:isWidgetShown(box), "the box is still open after Go")

    -- Cancel: the box closes and the page does not change
    local before = menu.page
    box = openBox()
    local cancel = exact(emu, "Cancel")
    emu:tapExpecting(cancel.x + 5, cancel.y + 5)
    assert(not UIManager:isWidgetShown(box), "Cancel did not close the box")
    assert(menu.page == before, string.format(
      "Cancel changed the page from %d to %d", before, menu.page))

    -- past the end: clamped to the last page
    box = openBox()
    box:setInputText(tostring(menu.page_num + 10))
    go = exact(emu, "Go")
    emu:tapExpecting(go.x + 5, go.y + 5)
    assert(menu.page == menu.page_num, string.format(
      "a page past the end left the menu on page %d of %d", menu.page, menu.page_num))
    assert(not UIManager:isWidgetShown(box), "the box is still open after Go past the end")
    emu:expectText(string.format("Page %d of %d", menu.page_num, menu.page_num))
    emu:shot("page_box_last")

    print(string.format("  Go to page: 2 -> page 2, Cancel kept page %d, past the end -> page %d of %d",
      before, menu.page_num, menu.page_num))
  end,
}
