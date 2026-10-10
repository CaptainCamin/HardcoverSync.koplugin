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
  -- fixture covers are three synthetic pictures, served from the real cover
  -- cache so the real loader and renderer run without a network
  local ids = { 103, 106, 109 }
  for _, series in pairs(fixtures.series_books) do
    for _, b in ipairs(series.books) do ids[#ids + 1] = b.book_id end
  end
  for _, id in ipairs(ids) do
    fixtures.seed_cover(fixtures.cover_url(id), id % 3 + 1)
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

    -- Watch the cover request the details make: it must ask for the size the cover
    -- is drawn at (see book_detail_dialog.lua's coverBox), not a rounded one.
    local loader = require("hardcover/lib/ui/image_loader")
    local real_loadImages = loader.loadImages
    local asked = {}
    loader.loadImages = function(self, urls, callback, opts)
      asked[#asked + 1] = { url = urls[1], opts = opts }
      return real_loadImages(self, urls, callback, opts)
    end
    local _, dialog = build_detail(emu, { book_id = book_id })
    loader.loadImages = real_loadImages
    emu:expectText("Extremely Long Title")

    -- The cover was in the cache, so the loader delivered it into its box.
    emu:pump()
    assert(dialog.cover_bb, "the cover never arrived in its box")

    -- The picture is in the box (not the placeholder icon), and the page is dithered
    -- from then on, so the grey of the photo does not band on the e-ink panel.
    assert(dialog.cover_cell[1][1].image == dialog.cover_bb,
      "the cover box still shows the placeholder icon")
    assert(dialog.dithered == true, "the details page is not dithered once its cover is in")

    local box_w, box_h = require("hardcover/lib/ui/book_detail_dialog").coverBox(
      require("device").screen:getWidth())
    local request
    for _, a in ipairs(asked) do
      if a.url == fixtures.cover_url(book_id) then request = a end
    end
    assert(request and request.opts and request.opts.size == "large",
      "the details did not ask for the cover at the details size")
    assert(request.opts.box and request.opts.box.w == box_w and request.opts.box.h == box_h,
      "the details asked for the cover at a size other than the box it is drawn in")

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
      -- (the title bar's own title is reported by several of its widgets)
      if seen[node.text] and node.text ~= dialog.title then
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
        -- (a row that starts below the screen is further down a page that scrolls, and a block
        -- cut by the bottom edge of a page that scrolls is the next block coming into view)
        local scrolls = dialog.scroll and dialog.scroll._max_scroll_offset_y and dialog.scroll._max_scroll_offset_y > 0
        assert(scrolls or node.y >= H or node.y + node.h <= H + 1, string.format(
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
    local typical_manager, typical = build_detail(emu, { book_id = 103, edition_id = 10301 })
    emu:pump()
    for _, expected in ipairs({ "The Left Hand of Darkness", "Hainish Cycle #4", "Fixture Press", "English" }) do
      emu:expectText(expected)
    end
    assert(typical.cover_bb, "the cover never arrived in its box")
    assert_no_sideways_scroll(typical, "the typical book")

    --[[--
    The series carousel. The book's own series arrives in the background and is
    added to the open screen: covers with numbers, the current book marked and not
    tappable, the arrows paging, and a tap on a cover opening that book on top.
    ]]
    local carousel = typical.carousel
    assert(typical.series_card and carousel, "the series carousel never arrived")
    for _, expected in ipairs({ "More in Hainish Cycle", "8 books", "#2", "#5" }) do
      emu:expectText(expected)
    end
    emu:shot("book_detail_typical")

    -- the action bar sits inside the page margins (the buttons used to run a few
    -- pixels past the right one) and its buttons are comfortably tall
    local Theme = require("hardcover/lib/ui/theme")
    local M = Theme.margin
    for _, name in ipairs({ "shelf_button", "reviews_button" }) do
      local b = typical[name]
      assert(b and b.dimen and b.dimen.w > 0, name .. " is not on screen")
      assert(b.dimen.x >= M, name .. " starts left of the margin")
      assert(b.dimen.x + b.dimen.w <= emu.Screen:getWidth() - M, name .. " runs past the right margin")
      assert(b.dimen.h >= emu.Screen:scaleBySize(48), name .. " is under 48 units tall")
    end

    -- the author and the series are plain text under the title (not links)
    emu:expectText("Ursula K. Le Guin")
    emu:expectText("Hainish Cycle #4")
    assert(typical.author_tap == nil and typical.series_tap == nil, "the author or the series is tappable")

    -- the page is the same size for every book: About is cut and Read more opens the whole
    -- synopsis on a screen of its own
    emu:expectText("Change shelf")
    emu:expectText("Currently Reading")
    local function open_and_close(button, expect, shot)
      emu:screenNodes() -- paint first: a tap range is only real once painted
      local d = button.dimen
      assert(d and d.w > 0, "the button is not painted")
      local top = emu.UIManager:getTopmostVisibleWidget()
      assert(emu:tap(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2)), "the tap was not handled")
      emu:pump()
      local opened = emu.UIManager:getTopmostVisibleWidget()
      assert(opened ~= top, "tapping the button opened nothing")
      for _, text in ipairs(expect) do emu:expectText(text) end
      if shot then emu:shot(shot) end
      emu.UIManager:close(opened)
      emu:pump()
      assert(emu.UIManager:getTopmostVisibleWidget() == top, "closing did not come back to the details")
    end
    -- the page scrolls by blocks with the scroll control; step down to a button and tap it
    local function reach(button)
      for _ = 1, 30 do
        emu:screenNodes()
        local d = button.dimen
        if d and d.y and d.y >= typical.scroll.dimen.y and d.y + d.h <= emu.Screen:getHeight() then return end
        emu:tap(emu.Screen:getWidth() - 10, emu.Screen:getHeight() - 20)
        emu:pump()
      end
      error("never scrolled to the button")
    end
    if typical.about_more then
      reach(typical.about_more)
      open_and_close(typical.about_more, { "About" }, "book_detail_about_full")
    end

    -- what other readers say: the genres in a line, and the rest behind +N more
    assert(typical.tags_more, "no +N more beside the genres")
    reach(typical.tags_more)
    emu:expectText("Genres")
    open_and_close(typical.tags_more, { "Moods", "Reflective" }, "book_detail_community")

    -- Details: five rows, then All details for the rest
    if typical.all_details then
      reach(typical.all_details)
      assert(#typical.meta_rows == 5, "the page shows " .. #typical.meta_rows .. " detail rows, not five")
      open_and_close(typical.all_details, { "All details" }, "book_detail_all_details")
    end

    -- the strip is below the first screenful now: scroll to it (taps are only
    -- answered where the page is showing)
    typical.scroll:scrollToRatio(0, 1)
    emu:shot("book_detail_typical_end")

    local function centre(w) return w.dimen.x + math.floor(w.dimen.w / 2), w.dimen.y + math.floor(w.dimen.h / 2) end
    -- the strip is not always in the last screenful (a short screen shows Details there): bring it into view
    local function show_strip()
      for ratio = 1, 0, -0.05 do
        typical.scroll:scrollToRatio(0, ratio)
        emu:screenNodes()
        local d, v = carousel.holder.dimen, typical.scroll.dimen
        if d and d.y and d.y >= v.y and d.y + d.h <= v.y + v.h then return end
      end
      error("could not bring the series strip into view")
    end
    show_strip()

    if carousel.paged then
      local before_first = carousel.first
      emu:tap(centre(carousel.next))
      emu:pump()
      assert(carousel.first > before_first, "tapping the next arrow did not turn the page")
      emu:shot("book_detail_carousel_page2")
      local forward = carousel.first
      emu:tap(centre(carousel.prev))
      emu:pump()
      -- the last page is clamped, so back is not always where it started
      assert(carousel.first < forward, "tapping the previous arrow did not turn back")
    end

    -- the first other book's cover
    local target = carousel.targets and carousel.targets[1]
    assert(target, "the carousel has no tappable covers")
    show_strip()
    emu:tap(centre(target))
    emu:pump()
    local sibling = emu.UIManager:getTopmostVisibleWidget()
    assert(sibling ~= typical, "tapping a cover did not open that book")
    assert(emu.UIManager:isWidgetShown(typical), "opening a book from the carousel closed the one underneath")
    emu.UIManager:close(sibling)
    assert(emu.UIManager:getTopmostVisibleWidget() == typical, "closing the sibling did not come back to this book")

    --[[--
    No cover at all (the fixture has no image url): the same box holds a generic
    book icon, and nothing is fetched.
    ]]
    local _, bare = build_detail(emu, { book_id = 105 })
    emu:pump()
    emu:expectText("The Hundred Thousand Kingdoms")
    assert(bare.series_card == nil, "a book in no series got a series card")
    assert(bare.cover_cell, "a book with no cover has no placeholder box")
    assert(bare.cover_bb == nil, "a picture was rendered for a book with no cover")
    emu:shot("book_detail_nocover")
    assert_no_sideways_scroll(bare, "the book with no cover")

    --[[--
    A description long enough that the page scrolls vertically. That is the case
    where the vertical scroll bar narrows the viewport, so the content has to
    leave room for it. The assertion on the scroll state makes sure this really
    is the scrolling case and not a page that happens to fit.
    ]]
    local _, long = build_detail(emu, { book_id = 109, edition_id = 10901 })
    emu:pump()
    emu:expectText("A Book With A Very Long Description")
    emu:shot("book_detail_long")
    assert(long.scroll._is_scrollable and long.scroll._max_scroll_offset_y > 0, "the long description did not make the page scroll; lengthen the fixture")
    assert_no_sideways_scroll(long, "the long-description book")

    --[[--
    A long series is paged, not listed: the book on screen starts on the page
    that holds it, and there is more on either side.
    ]]
    assert(long.series_card and #long.series_card.items == 24, "the long series did not load")
    assert(long.carousel and long.carousel.paged, "the long series is not paged")
    emu:shot("book_detail_series_long")

    -- the carousel on the first screen: drop the long blurb
    local _, series_demo = build_detail(emu, { book_id = 109 })
    emu:pump()
    series_demo.detail.book.description = "A shorter description, so the carousel is on the first screen."
    series_demo:rebuild()
    emu:pump()
    emu:shot("book_detail_series_short_description")
    assert_no_sideways_scroll(series_demo, "the long series carousel")

    --[[--
    A tap on Close must close the screen, whatever is laid out beneath it.

    ScrollableContainer paints its content in screen coordinates shifted by the
    scroll offset, so a tappable widget scrolled out of view keeps a tap range at
    that shifted position -- which can be directly over Close. Widgets nearer the
    top of the event order win, so a series row below the visible area would take
    the tap and open another book instead of closing this one.
    ]]
    local before = #emu.UIManager._window_stack
    local c = series_demo.close_button.dimen
    emu:tap(c.x + math.floor(c.w / 2), c.y + math.floor(c.h / 2))
    assert(not emu.UIManager:isWidgetShown(series_demo),
      "a tap on Close did not close the screen (a widget under it took the tap?)")
    assert(#emu.UIManager._window_stack <= before - 1,
      "tapping Close opened something instead of closing: the stack grew")

    print(string.format("  detail rendered in both menu modes"))
  end,
}
