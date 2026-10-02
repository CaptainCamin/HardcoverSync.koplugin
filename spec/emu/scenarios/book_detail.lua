--[[--
Book detail: the screen shown after picking a row on the shelf.

Long-form text, so this is where wrapping, scrolling and the page counter
matter. Runs against both the plain-Menu and SearchMenu (compatibility mode
off) paths, because the plugin ships a vendored menu for the second and a bug
in one does not show up in the other.

Screens: book_detail, book_detail_compat.
]]

local fixtures = require("fixtures")

--[[--
The page must never scroll sideways.

ScrollableContainer treats content wider than its viewport as scrollable
sideways and draws a horizontal scroll bar -- a heavy black bar above the Close
button. It came from a cover frame whose border was not counted in the header's
width, and from content laid out as wide as the dialog when the vertical bar
takes 3 * scroll_bar_width off the viewport. A pixel-level check would be
fragile; the container records exactly what it decided.
]]
local function assert_no_sideways_scroll(dialog, label)
  local scroll = dialog.scroll
  assert(scroll, label .. ": the dialog has no scroll container")
  assert(scroll._max_scroll_offset_x == 0 and scroll._h_scroll_bar == nil, string.format(
    "%s scrolls sideways: the content is %dpx too wide for its viewport",
    label, scroll._max_scroll_offset_x or -1))
end

local function build_detail(emu, opts)
  local settings = fixtures.real_settings(emu)
  -- every fixture cover is the same synthetic picture, served from the real
  -- cover cache so the real loader and renderer run without a network
  for _, id in ipairs({ 103, 106, 109 }) do
    fixtures.seed_cover("https://covers.hardcover.app/fixture/" .. id .. ".jpg")
  end
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

    -- The cover was in the cache, so the loader delivered it into its box.
    emu:pump()
    assert(dialog.cover_bb, "the cover never arrived in its box")

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
    assert_no_sideways_scroll(dialog, "the long-title book")

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

    --[[--
    A typical book, linked to an edition: series line, community rating, and the
    Details rows (publisher, language, ISBN) the header does not repeat.
    ]]
    local _, typical = build_detail(emu, { book_id = 103, edition_id = 10301 })
    emu:pump()
    for _, expected in ipairs({ "The Left Hand of Darkness", "Hainish Cycle #2", "Fixture Press", "English" }) do
      emu:expectText(expected)
    end
    assert(typical.cover_bb, "the cover never arrived in its box")
    emu:shot("book_detail_typical")
    assert_no_sideways_scroll(typical, "the typical book")

    --[[--
    No cover at all (the fixture has no image url): no box is reserved, and
    nothing is fetched.
    ]]
    local _, bare = build_detail(emu, { book_id = 105 })
    emu:pump()
    emu:expectText("The Hundred Thousand Kingdoms")
    assert(bare.cover_cell == nil, "a cover box was reserved for a book with no cover")
    emu:shot("book_detail_nocover")
    assert_no_sideways_scroll(bare, "the book with no cover")

    --[[--
    A description long enough that the page scrolls vertically. That is the case
    where the vertical scroll bar narrows the viewport, so the content has to
    leave room for it. The assertion on the vertical bar makes sure this really
    is the scrolling case and not a page that happens to fit.
    ]]
    local _, long = build_detail(emu, { book_id = 109, edition_id = 10901 })
    emu:pump()
    emu:expectText("A Book With A Very Long Description")
    emu:shot("book_detail_long")
    assert(long.scroll._v_scroll_bar, "the long description did not make the page scroll; lengthen the fixture")
    assert_no_sideways_scroll(long, "the long-description book")

    print(string.format("  detail rendered in both menu modes"))
  end,
}
