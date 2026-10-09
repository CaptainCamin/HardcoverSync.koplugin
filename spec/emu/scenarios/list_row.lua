--[[--
The row of buttons under a list screen's title bar, with real taps.

A shelf has Sort and Search. Sort names the order and opens the picker; Search opens a box
and filters the shelf's own books in place: the row then shows the words as a black button
and a small x that clears them, and a word nothing matches says so. Back leaves the shelf and
the X quits the plugin. Search results have one button, "New search", and no filter.

Screens: list_row_shelf, list_row_search, list_row_results, list_row_reload.
]]

local fixtures = require("fixtures")
local perf = require("perf")
local UIManager = require("ui/uimanager")
local EntrySearch = require("hardcover/lib/entry_search")
local ScreenRegistry = require("hardcover/lib/screen_registry")
local Theme = require("hardcover/lib/ui/theme")

local function plugin_windows()
  local stack = {}
  for i = #UIManager._window_stack, 1, -1 do stack[#stack + 1] = UIManager._window_stack[i].widget end
  return ScreenRegistry.pluginWindows(stack)
end

local function top() return UIManager:getTopmostVisibleWidget() end

local function center(widget)
  local d = widget.dimen
  return d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2)
end

-- The button of the screen's row whose text starts with `prefix`. The row is rebuilt when
-- it changes, so this is read afresh each time, after a paint (positions are only real then).
local function row_button(emu, dialog, prefix)
  emu:screenNodes()
  for _, button in ipairs(dialog.menu.title_bar.row_buttons) do
    if button.text:sub(1, #prefix) == prefix then return button end
  end
  local names = {}
  for _, button in ipairs(dialog.menu.title_bar.row_buttons) do names[#names + 1] = button.text end
  error("no '" .. prefix .. "' button in the row: " .. table.concat(names, " | "))
end

local function tap_button(emu, button)
  assert(button and button.dimen, "the button is not painted")
  emu:tapExpecting(center(button))
  perf.run_loop()
end

-- Tap the button whose painted text is exactly `label`, the one drawn last (a box on top)
local function tap_label(emu, label)
  UIManager:setDirty(nil, "full")
  UIManager:_repaint()
  local found
  for _, node in ipairs(emu:screenNodes()) do
    if node.text == label then found = node end
  end
  assert(found and found.x, "no '" .. label .. "' on screen:\n" .. emu:screenText())
  emu:tapExpecting(found.x + math.floor(found.w / 2), found.y + math.floor(found.h / 2))
  perf.run_loop()
end

-- Open the search box from the row, type `words`, and press Search
local function search_for(emu, dialog, words, opener)
  tap_button(emu, row_button(emu, dialog, opener))
  local input = top()
  assert(input and input.getInputText, "the button did not open a text box, top is " .. tostring(input and input.name))
  input:setInputText(words)
  tap_label(emu, "Search")
end

local function texts(dialog)
  local out = {}
  for _, button in ipairs(dialog.menu.title_bar.row_buttons) do out[#out + 1] = button.text end
  return table.concat(out, " | ")
end

return {
  name = "list_row",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    local SETTING = require("hardcover/lib/constants/settings")
    -- covers for the shelf's books (every seventh has none), from the real cache
    for _, b in ipairs(fixtures.shelf_books) do
      local image = b.cached_image
      if image and image.url then fixtures.seed_cover(image.url, b.book_id % 3 + 1) end
    end
    -- the emulated settings file outlives a run: the default order, and the cover list
    settings:updateSetting(SETTING.SHELF_SORT, nil)
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    fixtures.install({ settings = settings })

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local HARDCOVER = require("hardcover/lib/constants/hardcover")
    local manager = DialogManager:new { settings = settings }
    local W = emu.Screen:getWidth()

    -- a. the shelf: Sort and Search under the title, which is just the shelf's name
    manager:showShelf(HARDCOVER.STATUS.TO_READ, "Want to Read")
    perf.run_loop()
    local dialog = manager.shelf_dialog
    assert(dialog and UIManager:isWidgetShown(dialog), "the shelf did not open")
    local menu = dialog.menu
    assert(menu.title_bar == dialog.header, "the menu is not using the shelf's header")
    local shelf_entries = dialog.entries
    local total = #shelf_entries
    assert(total > 5, "the fixture shelf is too short to filter: " .. total)

    emu:shot("list_row_shelf")
    local sort = row_button(emu, dialog, "Sort:")
    local search = row_button(emu, dialog, "Search")
    assert(sort.text == "Sort: Date added (newest first)", "the Sort button says " .. sort.text)
    assert(#menu.title_bar.row_buttons == 2, "the row is not Sort and Search: " .. texts(dialog))
    assert(menu.title_bar.title == "Want to Read", "the title is " .. tostring(menu.title_bar.title))
    assert(not emu:screenText():find(" \194\183 ", 1, true), "the title carries the order")
    emu:expectText("Want to Read")

    -- the buttons sit inside the margins, side by side, and the list starts below them
    assert(sort.dimen.x >= Theme.margin, "Sort starts outside the margin")
    assert(sort.dimen.x + sort.dimen.w <= search.dimen.x, "Sort and Search overlap")
    assert(search.dimen.x + search.dimen.w <= W - Theme.margin, "Search runs past the margin")
    local header = dialog.header
    assert(header:getHeight() == header:getSize().h and header.dimen.h == header:getHeight(),
      "the header's height disagrees with what it paints")
    local first = emu:expectText(menu.item_table[1].title)
    assert(first.y >= header.dimen.y + header.dimen.h,
      "the first book starts at " .. first.y .. ", inside the header (" .. header.dimen.h .. " tall)")
    emu:expectNoButtonOverlap()
    local height = header:getHeight()

    -- the corners nearest the bar's Back and X are the buttons', not theirs: those two have
    -- tap zones that reach down over the row's top edge, and a tap there must not go back or
    -- quit
    local zone = header.title_bar.left_button.dimen
    assert(zone.y + zone.h > sort.dimen.y and zone.x + zone.w > sort.dimen.x,
      "Back's tap zone no longer reaches the row: this check proves nothing")
    -- (tap, not tapExpecting: when the tap goes back or quits there is no window left for
    -- tapExpecting's message to name)
    emu:tap(sort.dimen.x + 5, sort.dimen.y + 2)
    assert(UIManager:isWidgetShown(dialog), "a tap on the corner of Sort went Back")
    emu:expectText("Sort by")
    UIManager:close(dialog.sort_menu)
    perf.run_loop()
    emu:tap(search.dimen.x + search.dimen.w - 5, search.dimen.y + 2)
    assert(UIManager:isWidgetShown(dialog), "a tap on the corner of Search quit the plugin")
    local corner_box = top()
    assert(corner_box and corner_box.getInputText, "a tap on the corner of Search did not open the box, top is "
      .. tostring(corner_box and corner_box.name))
    UIManager:close(corner_box)
    perf.run_loop()

    -- b. Sort opens the picker; the button then names the order that was chosen
    tap_button(emu, sort)
    emu:expectText("Sort by")
    local picker = emu:screenText()
    assert(not picker:find("Load the rest", 1, true), "the picker has more than the orders")
    local choice = emu:expectText("Author (A")
    emu:tapExpecting(choice.x + 5, choice.y + 5)
    perf.run_loop()
    sort = row_button(emu, dialog, "Sort:")
    assert(sort.text == "Sort: Author (A\226\128\147Z)", "the Sort button says " .. sort.text)
    assert(dialog.sort_key == "author", "the order is " .. tostring(dialog.sort_key))
    assert(header:getHeight() == height, "the header changed height with the order")

    -- c. Search: a word that some of the books have
    local word = "hyperion"
    local expected = EntrySearch.filter(dialog.entries, word)
    assert(#expected > 0 and #expected < total, "the word does not split the fixture shelf")
    search_for(emu, dialog, word, "Search")
    assert(dialog.filter == word, "the filter is " .. tostring(dialog.filter))
    assert(#menu.item_table == #expected, string.format("the shelf holds %d rows, expected %d",
      #menu.item_table, #expected))
    for _, item in ipairs(menu.item_table) do
      assert(item.entry and EntrySearch.matches(item.entry, word), "a row that does not match is shown: " .. tostring(item.text))
    end
    assert(#dialog.entries == total, "searching dropped books from the shelf itself")
    local buttons = menu.title_bar.row_buttons
    assert(#buttons == 3, "the row is not Sort, the words and x: " .. texts(dialog))
    local filled = row_button(emu, dialog, "\226\128\156")
    assert(filled.text == "\226\128\156" .. word .. "\226\128\157", "the button says " .. filled.text)
    assert(filled.label.fgcolor == Theme.WHITE, "the words are not white on black")
    local clear = row_button(emu, dialog, "\195\151")
    assert(clear.width < filled.width, "the x is not the narrow one")
    assert(clear.dimen.x + clear.dimen.w <= W - Theme.margin, "the x runs past the margin")
    assert(filled.dimen.x + filled.dimen.w <= clear.dimen.x, "the words and the x overlap")
    assert(header:getHeight() == height, "the header changed height with the filter")
    emu:expectText("Hyperion")
    emu:shot("list_row_search")

    -- paging and selection work on what is shown
    local opened
    dialog.select_entry_cb = function(entry) opened = entry end
    local title = emu:expectText(expected[1].title)
    emu:tapExpecting(title.x + 5, title.y + 5)
    assert(opened and EntrySearch.matches(opened, word), "tapping a found book opened " .. tostring(opened and opened.title))

    -- a word that matches more than a page: paging runs over what is left, and only that
    local wide_word = "the"
    local wide = EntrySearch.filter(dialog.entries, wide_word)
    assert(#wide > menu.perpage and #wide < total, string.format("'%s' matches %d of %d books: not a good paging word",
      wide_word, #wide, total))
    search_for(emu, dialog, wide_word, "\226\128\156")
    assert(dialog.filter == wide_word and #menu.item_table == #wide, "the filter is not on: " .. #menu.item_table .. " rows")
    local pages = math.ceil(#wide / menu.perpage)
    assert(menu.page_num == pages and pages > 1, string.format("%d pages for %d matches", menu.page_num, #wide))
    assert(menu.page == 1, "a new filter did not start on page 1")
    local page1 = emu:screenText()
    emu:press("NextPage")
    assert(menu.page == 2, "NextPage did not advance the filtered list")
    assert(emu:screenText() ~= page1, "page 2 of the filtered list looks like page 1")
    local on_page = 0
    for i = (menu.page - 1) * menu.perpage + 1, math.min(#menu.item_table, menu.page * menu.perpage) do
      on_page = on_page + 1
      assert(EntrySearch.matches(menu.item_table[i].entry, wide_word), "page 2 shows a book that does not match: " .. tostring(menu.item_table[i].title))
    end
    assert(on_page == #wide - menu.perpage or on_page == menu.perpage, "page 2 holds " .. on_page .. " rows")
    -- and a tap on a row of page 2 is that book
    local second = menu.item_table[menu.perpage + 1]
    local seen
    dialog.select_entry_cb = function(entry) seen = entry end
    local row_title = emu:expectText(second.title)
    emu:tapExpecting(row_title.x + 5, row_title.y + 5)
    assert(seen and seen.book_id == second.entry.book_id, "tapping a row on page 2 opened " .. tostring(seen and seen.title))
    dialog.select_entry_cb = nil
    -- back to the one-page filter the next step expects
    search_for(emu, dialog, word, "\226\128\156")
    assert(dialog.filter == word and #menu.item_table == #expected)

    -- d. the words open the box again, with the filter in it; a word nothing matches says so
    tap_button(emu, filled)
    local input = top()
    assert(input and input.getInputText and input:getInputText() == word,
      "the box did not come back with the words: " .. tostring(input and input.getInputText and input:getInputText()))
    input:setInputText("zzqx")
    tap_label(emu, "Search")
    assert(dialog.filter == "zzqx", "the filter is " .. tostring(dialog.filter))
    emu:expectText("No books match")
    emu:expectText("zzqx")
    assert(#menu.item_table == 1 and menu.item_table[1].file, "the empty answer is not a row")
    assert(dialog.has_more == false and #dialog.entries == total)

    -- e. the x clears it: every book is back, and the row is Sort and Search again
    tap_button(emu, row_button(emu, dialog, "\195\151"))
    assert(dialog.filter == nil, "the x left a filter on")
    assert(#menu.item_table == total, string.format("%d rows after clearing, expected %d", #menu.item_table, total))
    assert(#menu.title_bar.row_buttons == 2 and row_button(emu, dialog, "Search").text == "Search",
      "the row is not back to Sort and Search: " .. texts(dialog))
    assert(header:getHeight() == height, "the header changed height when the filter went")

    -- searching with nothing in the box clears it too
    search_for(emu, dialog, word, "Search")
    assert(dialog.filter == word)
    search_for(emu, dialog, "   ", "\226\128\156")
    assert(dialog.filter == nil and #menu.item_table == total, "an empty search left the filter on")

    -- f. Back leaves the shelf; the X quits the plugin
    -- (the shelf is the only window, so there is nothing left to name in a failed tap's
    -- message: tap, not tapExpecting)
    emu:screenNodes()
    emu:tap(center(menu.title_bar.left_button))
    perf.run_loop()
    assert(not UIManager:isWidgetShown(dialog), "Back left the shelf open")
    manager:showShelf(HARDCOVER.STATUS.TO_READ, "Want to Read")
    perf.run_loop()
    dialog = manager.shelf_dialog
    assert(dialog and UIManager:isWidgetShown(dialog), "the shelf did not open again")
    assert(dialog.sort_key == "author", "the order was not remembered: " .. tostring(dialog.sort_key))
    assert(dialog.filter == nil, "a new shelf starts with a filter")
    emu:screenNodes()
    local X = dialog.menu.title_bar.right_button
    assert(X and X.dimen, "the X is not painted")
    -- the X closes the window it is in, so judge it by what is left on the stack
    emu:tap(center(X))
    perf.run_loop()
    local left = plugin_windows()
    assert(#left == 0, string.format("the X left %d plugin screen(s) open", #left))

    -- g. search results: "New search" and nothing to filter
    local books = {}
    for i = 6, 9 do books[#books + 1] = shelf_entries[i] end
    manager:showSearchResults("dark", books)
    perf.run_loop()
    local results = manager.search_results_dialog
    assert(results and UIManager:isWidgetShown(results), "the results did not open")
    emu:shot("list_row_results")
    local names = texts(results)
    assert(#results.menu.title_bar.row_buttons == 1 and names == "New search",
      "the results' row is not just New search: " .. names)
    assert(not emu:screenText():find("\195\151", 1, true), "the results have an x")
    assert(results.header:getHeight() == height, "the results' header is not the shelf's height")

    -- New search opens the box with the words in it
    tap_button(emu, row_button(emu, results, "New search"))
    input = top()
    assert(input and input.getInputText and input:getInputText() == "dark",
      "New search did not open the box with the words")
    tap_label(emu, "Cancel")
    assert(UIManager:isWidgetShown(results), "Cancel closed the results")

    -- h. the reload icon beside the X: there while the screen can fetch itself again or has
    -- more to load, gone when it has neither, and the header keeps its height either way
    local ShelfDialog = require("hardcover/lib/ui/shelf_dialog")
    local refreshed, fetched = 0, nil
    local list
    list = ShelfDialog:new {
      compatibility_mode = false,
      title = "A list",
      entries = { shelf_entries[1], shelf_entries[2], shelf_entries[3] },
      offset = 3,
      has_more = false,
      page_size = 3,
      on_refresh = function() refreshed = refreshed + 1 end,
      fetch_page = function(offset, _limit, callback) fetched = { offset = offset, callback = callback } end,
      select_entry_cb = function() end,
    }
    UIManager:show(list)
    perf.run_loop()
    local bar = list.menu.title_bar
    assert(bar.title_bar.extra_right_button, "a list that can refresh has no reload icon")
    assert(bar.right_button and bar.left_button, "the X or Back is gone with the reload icon")
    assert(bar:getHeight() == height, "the reload icon changed the header's height")
    emu:shot("list_row_reload")
    emu:screenNodes()
    emu:tapExpecting(center(bar.title_bar.extra_right_button))
    assert(refreshed == 1, "the reload icon ran Refresh " .. refreshed .. " times")
    assert(fetched == nil, "the icon loaded more with nothing more to load")

    -- no refresh and nothing more to load: no icon
    list.on_refresh = nil
    list:updatePager()
    perf.run_loop()
    assert(not bar.title_bar.extra_right_button, "the reload icon stayed with nothing to do")
    assert(bar:getHeight() == height, "taking the icon away changed the header's height")
    emu:screenNodes()
    assert(bar.right_button.dimen and bar.right_button.dimen.x + bar.right_button.dimen.w <= W, "the X is off the screen")

    -- more to load: the icon is back and carries on loading; the last page takes it away
    list:setEntries({ shelf_entries[1], shelf_entries[2], shelf_entries[3] }, true, true)
    perf.run_loop()
    assert(bar.title_bar.extra_right_button, "an interrupted load shows no reload icon")
    emu:screenNodes()
    emu:tapExpecting(center(bar.title_bar.extra_right_button))
    assert(fetched and fetched.offset == 3, "the icon did not ask for the next page")
    fetched.callback({ shelf_entries[4], shelf_entries[5] }, nil, false)
    perf.run_loop()
    assert(#list.entries == 5 and list.has_more == false, "the last page was not appended")
    assert(not bar.title_bar.extra_right_button, "the reload icon stayed after the last page")

    -- an answer that arrives inside the tap itself (the saved copy) rebuilds the icon that
    -- was tapped: nothing may break
    list.fetch_page = function(offset, _limit, callback) callback({ shelf_entries[6] }, nil, false) end
    list:setEntries({ shelf_entries[1], shelf_entries[2] }, true, true)
    list.offset = 2
    perf.run_loop()
    emu:screenNodes()
    emu:tapExpecting(center(bar.title_bar.extra_right_button))
    perf.run_loop()
    assert(#list.entries == 3 and not bar.title_bar.extra_right_button, "a load answered at once went wrong")
    UIManager:close(list)

    -- i. the stock list (compatibility mode, for older KOReaders) takes the same header
    local plain = ShelfDialog:new {
      compatibility_mode = true,
      title = "Plain list",
      sortable = true,
      entries = { shelf_entries[1], shelf_entries[2], shelf_entries[3] },
      offset = 3,
      select_entry_cb = function() end,
    }
    UIManager:show(plain)
    perf.run_loop()
    local plain_header = plain.menu.title_bar
    assert(plain_header == plain.header and plain_header:getHeight() == height,
      "the stock list's header is not the same height as the cover list's")
    local plain_first = emu:expectText("Lathe of Heaven")
    assert(plain_first.y >= plain_header.dimen.y + plain_header.dimen.h, "the first book starts inside the header")
    search_for(emu, plain, "kindred", "Search")
    assert(#plain.menu.item_table == 1 and plain.menu.item_table[1].entry.title == "Kindred",
      "searching the stock list found " .. #plain.menu.item_table .. " rows")
    emu:expectText("Kindred")
    UIManager:close(plain)

    print("  row: Sort, Search, x, Back, the X, New search and the reload icon all do what they say")
    emu:closeAll()
  end,
}
