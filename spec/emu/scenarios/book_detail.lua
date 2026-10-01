--[[--
Book detail: the screen shown after picking a row on the shelf.

Long-form text, so this is where wrapping, scrolling and the page counter
matter. Runs against both the plain-Menu and SearchMenu (compatibility mode
off) paths, because the plugin ships a vendored menu for the second and a bug
in one does not show up in the other.

Screens: book_detail, book_detail_compat.
]]

local fixtures = require("fixtures")

local function build_detail(emu, opts)
  local settings = fixtures.real_settings(emu)
  fixtures.install({
    settings = settings,
    overrides = {
      getShelf = function() return {}, nil, false end,
    },
  })

  local DialogManager = require("hardcover/lib/ui/dialog_manager")

  local manager = DialogManager:new{ settings = settings }
  manager:showBookDetail(opts.book_id, opts.edition_id)
  emu:pump()

  local dialog = emu.UIManager:getTopmostVisibleWidget()
  assert(dialog, "showBookDetail showed nothing")
  return manager, dialog
end

return {
  name = "book_detail",

  run = function(emu)
    -- The long-title book, so truncation and wrapping are under load.
    local book_id = 106

    local _, dialog = build_detail(emu, { book_id = book_id })
    emu:expectText("Extremely Long Title")

    --[[--
    No text may appear twice on screen.

    This caught a real duplication: Shelf.detailRows emits the description as a
    metadata row, and the dialog also gives it a dedicated wrapping box, so the
    whole paragraph printed twice. A screenshot makes that easy to miss --
    two identical paragraphs look like a rendering artefact -- but counting
    occurrences does not.
    ]]
    local seen = {}
    local dupes = {}
    for _, node in ipairs(emu:screenNodes()) do
      -- Long strings are legitimately repeated in a scrolling view only if
      -- they are genuinely distinct widgets; compare exactly, not by prefix.
      if seen[node.text] then
        dupes[#dupes + 1] = node.text
      end
      seen[node.text] = true
    end
    assert(#dupes == 0, "text rendered more than once: " ..
      table.concat(dupes, " | "))

    -- The detail view is a scrolling text page; make sure it reports a sane
    -- page count and that paging changes the content.
    local page1 = emu:screenText()
    emu:shot("book_detail")

    -- Anything drawn outside the panel is a layout fault. Only nodes with
    -- absolute coordinates can be checked -- a widget nested in a
    -- VerticalGroup reports a size but no screen position, and reading its
    -- missing x as 0 would produce nonsense failures.
    local W, H = emu.Screen:getWidth(), emu.Screen:getHeight()
    local checked = 0
    for _, node in ipairs(emu:screenNodes()) do
      if not node.relative and node.x and node.y then
        checked = checked + 1
        assert(node.y + node.h <= H + 1, string.format(
          "text %q runs past the bottom edge (%d+%d > %d)", node.text, node.y, node.h, H))
        assert(node.x >= 0, string.format(
          "text %q drawn at negative x (%d)", node.text, node.x))
      end
    end
    print(string.format("  %d nodes with absolute geometry checked", checked))

    -- If the description made it long enough to scroll, paging must move it.
    if dialog.page_num and dialog.page_num > 1 then
      emu:press("NextPage")
      assert(dialog.page == 2, string.format(
        "NextPage did not advance the detail page (page %s of %s)",
        tostring(dialog.page), tostring(dialog.page_num)))
      assert(emu:screenText() ~= page1, "page 2 of the detail view is identical to page 1")
      emu:shot("book_detail_page2")
    else
      print("  detail fits on one page; scrolling untested")
    end

    --[[--
    The same book with compatibility mode on, which takes the plugin's vendored
    SearchMenu instead of the vendored-or-stock Menu. Both paths are shipped, so
    both need to render.
    ]]
    local settings = fixtures.real_settings(emu)
    settings:updateSetting(require("hardcover/lib/constants/settings").COMPATIBILITY_MODE, true)

    local manager = build_detail(emu, { book_id = book_id })
    emu:shot("book_detail_compat")

    print(string.format("  detail rendered in both menu modes"))
  end,
}
