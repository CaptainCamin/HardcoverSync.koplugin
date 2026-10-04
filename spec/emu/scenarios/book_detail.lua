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
        -- (a row that starts below the screen is further down a page that scrolls)
        assert(node.y >= H or node.y + node.h <= H + 1, string.format(
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

    --[[--
    The series pill, the status pill and the author open a search for the series,
    the shelf for that status, and a search for the author, on top of this screen.
    Real taps at the painted spot; closing what opened comes back here. The
    fixture book is "Currently Reading" (status 2).
    ]]
    local BookSearch = require("hardcover/lib/book_search")
    local Api = require("hardcover/lib/hardcover_api")
    local asked = {}
    local find_books = Api.findBooks
    Api.findBooks = function(self, title, ...)
      asked[#asked + 1] = title
      return find_books(self, title, ...)
    end

    -- the words are on screen, and the tap lands in the middle of their touch
    -- cell (taller than the words), where it was painted
    local function tap_on(text, row)
      emu:expectText(text)
      local d = row and row.dimen
      assert(d and d.x and d.w > 0, text .. " is not tappable")
      assert(d.h >= Theme.TOUCH_MIN, text .. " is under " .. Theme.TOUCH_MIN .. "px tall to touch")
      emu:tapExpecting(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
      emu:pump()
    end
    local function back_on_details(what)
      emu.UIManager:close(emu.UIManager:getTopmostVisibleWidget())
      emu:pump()
      assert(emu.UIManager:getTopmostVisibleWidget() == typical, what .. ": closing did not come back to the details")
    end

    tap_on("Hainish Cycle #4", typical.series_tap)
    assert(asked[#asked] == "Hainish Cycle", "the series search asked for " .. tostring(asked[#asked]))
    local results = typical_manager.search_results_dialog
    assert(results and emu.UIManager:getTopmostVisibleWidget() == results, "tapping the series did not open the results")
    emu:expectText(BookSearch.title("Hainish Cycle"))
    emu:shot("book_detail_series_search")
    back_on_details("series search")

    tap_on("Ursula K. Le Guin", typical.author_tap)
    assert(asked[#asked] == "Ursula K. Le Guin", "the author search asked for " .. tostring(asked[#asked]))
    results = typical_manager.search_results_dialog
    assert(results and emu.UIManager:getTopmostVisibleWidget() == results, "tapping the author did not open the results")
    emu:expectText(BookSearch.title("Ursula K. Le Guin"))
    back_on_details("author search")

    tap_on("Currently Reading", typical.status_tap)
    local shelf = typical_manager.shelf_dialog
    assert(shelf and emu.UIManager:getTopmostVisibleWidget() == shelf, "tapping the status did not open the shelf")
    assert(shelf.status_id == 2, "the shelf is for status " .. tostring(shelf.status_id))
    emu:shot("book_detail_status_shelf")
    back_on_details("status shelf")
    Api.findBooks = find_books

    -- what other readers say: the rating breakdown and the tags
    typical.scroll:scrollToRatio(0, 0.4)
    emu:pump()
    emu:expectText("Ratings")
    emu:expectText("Moods")
    emu:expectText("Reflective")
    emu:shot("book_detail_community")

    -- the strip is below the first screenful now: scroll to it (taps are only
    -- answered where the page is showing)
    typical.scroll:scrollToRatio(0, 1)
    emu:shot("book_detail_typical_end")

    local function centre(w) return w.dimen.x + math.floor(w.dimen.w / 2), w.dimen.y + math.floor(w.dimen.h / 2) end

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
    leave room for it. The assertion on the vertical bar makes sure this really
    is the scrolling case and not a page that happens to fit.
    ]]
    local _, long = build_detail(emu, { book_id = 109, edition_id = 10901 })
    emu:pump()
    emu:expectText("A Book With A Very Long Description")
    emu:shot("book_detail_long")
    assert(long.scroll._v_scroll_bar, "the long description did not make the page scroll; lengthen the fixture")
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
