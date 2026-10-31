--[[--
The two pickers: "Select book" (the link-book search) and "Select edition" (Change edition).

Both are the shelf screen with a search field under the bar (search_dialog.lua). Checked: the text
on screen, that every row is a book the picker can hand back, that a no-match search says so, that a
search made from the field replaces the rows and shows the new words, that the linked edition has its radio
filled (also on a long title, where the label has to share the row), and that choosing a row hands its
edition back.

Screens: search_results, search_empty, edition_picker, edition_picker_long.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function new_manager(emu)
  local settings = fixtures.real_settings(emu)
  fixtures.install({ settings = settings })

  local DialogManager = require("hardcover/lib/ui/dialog_manager")
  return DialogManager:new { settings = settings }
end

local function open_book_picker(emu, query)
  local manager = new_manager(emu)

  local books = fixtures.install().findBooks(nil, query, nil)
  manager:buildSearchDialog("Select book", books, nil, function() end, function() return true end, query)
  emu:pump()

  local dialog = manager.search_dialog
  assert(dialog, "buildSearchDialog produced no dialog")
  assert(UIManager:isWidgetShown(dialog), "book picker was built but never shown")
  return dialog, manager
end

local function open_edition_picker(emu, book_id, linked_edition_id, on_pick)
  local manager = new_manager(emu)

  -- the same fetch the Change edition row makes, through the real normaliser (see fixtures.lua)
  local Api = require("hardcover/lib/hardcover_api")
  manager:buildLoadingSearchDialog("Select edition",
    function(callback) callback(Api.findEditions(Api, book_id, fixtures.USER_ID)) end,
    { edition_id = linked_edition_id },
    on_pick, nil, nil, true)
  emu:pump()

  local dialog = manager.search_dialog
  assert(dialog, "buildLoadingSearchDialog produced no dialog")
  assert(UIManager:isWidgetShown(dialog), "edition picker was built but never shown")
  return dialog
end

-- Every row of a picker, shaped the way the screen shapes it.
local function shaped_rows(dialog)
  local rows = {}
  for i, entry in ipairs(dialog.entries) do
    rows[i] = dialog:createListItem(entry)
  end
  return rows
end

-- The current row(s) of an edition picker: the edition ids whose radio is filled.
local function marked_current(dialog)
  local marked = {}
  for _, row in ipairs(shaped_rows(dialog)) do
    if row.current then marked[#marked + 1] = row.edition_id end
  end
  return marked
end

return {
  name = "search",

  run = function(emu)
    local dialog = open_book_picker(emu, "the")
    emu:expectText("Select book")
    emu:expectText("N. K. Jemisin")

    local rows = shaped_rows(dialog)
    assert(#rows > 0, "search produced no rows")
    for i, row in ipairs(rows) do
      assert(row.book_id, string.format("row %d has no book_id: a tap could not pick it", i))
      assert(row.title and row.title ~= "", string.format("row %d has no title", i))
      assert(row.chooser, string.format("row %d would show a chevron on a picker", i))
      assert(row.detail == nil, string.format("row %d shows edition detail on the book picker", i))
    end
    emu:shot("search_results")

    -- keys and d-pad: the search field comes first in the focus order, so the picker can be searched
    assert(dialog.layout[1][1] == dialog.search_field.field_button,
      "the search field is not the first thing keyboard focus reaches")

    -- A search made from the field: the field shows the new words and the rows are the new results.
    -- This one finds nothing, so the answer is said where the rows would be.
    emu:closeAll()
    local again, search_manager = open_book_picker(emu, "the")
    search_manager:updateSearchResults("zzzzznotfound")
    emu:pump()
    assert(again.search_value == "zzzzznotfound", "the field kept the old words")
    emu:expectText("zzzzznotfound")
    emu:expectText("No results")
    emu:shot("search_empty")

    print(string.format("  %d book rows", #rows))

    -- The edition picker: the linked edition (the second of three) is marked, its second line says the
    -- format and pages, and a tap hands its edition back in the row shape the reader's link code reads.
    emu:closeAll()
    local book = fixtures.books[1]
    local linked = book.book_id * 100 + 2
    local picked
    local editions = open_edition_picker(emu, book.book_id, linked, function(row) picked = row end)
    emu:expectText("Select edition")
    emu:expectText("Paperback")
    emu:expectText("Ebook")

    local current = marked_current(editions)
    assert(#current == 1 and current[1] == linked,
      "the linked edition is not the one with its radio filled (marked: " .. table.concat(current, ",") .. ")")
    emu:shot("edition_picker")

    editions.select_entry_cb(editions.entries[3])
    assert(picked and picked.edition_id == book.book_id * 100 + 3,
      "choosing an edition did not hand its edition back")
    assert(picked.edition_format == "Ebook", "the picked edition lost its format")

    -- The longest title in the fixtures, with its edition linked: the label and the title share a row.
    emu:closeAll()
    local longest = fixtures.books[1]
    for _, b in ipairs(fixtures.books) do
      if #b.title > #longest.title then longest = b end
    end
    local long_linked = longest.book_id * 100 + 1
    local long_picker = open_edition_picker(emu, longest.book_id, long_linked, function() end)
    assert(#marked_current(long_picker) == 1, "the long-title edition picker marks no edition")
    emu:shot("edition_picker_long")

    print("  edition picker marks edition " .. linked .. " as the current choice; long title " .. longest.title)

    -- Local search uses KOReader's real Unicode case-folding, not a test's ASCII stand-in.
    emu:closeAll()
    local shelf = require("hardcover/lib/ui/shelf_dialog"):new {
      title = "Local search", local_searchable = true,
      entries = {
        { book_id = 1, title = "École", authors = "Иван Петров" },
        { book_id = 2, title = "Économie", authors = "Сергей" },
      },
    }
    UIManager:show(shelf)
    for _, query in ipairs({ "école иван", "ÉCOLE ИВАН" }) do
      shelf:setLocalSearch(query)
      assert(#shelf.visible_entries == 1 and shelf.visible_entries[1].book_id == 1,
        "Unicode title/author search missed: " .. query)
    end
    shelf:setLocalSearch("école сергей")
    assert(#shelf.visible_entries == 0, "a missing author word should reject the book")
    shelf:setLocalSearch("école иван")
    emu:pump()
    emu:expectText("École")
    emu:expectText("Иван Петров")
    emu:expectText("1 matches")
    emu:shot("search_unicode")
    emu:closeAll()
  end,
}
