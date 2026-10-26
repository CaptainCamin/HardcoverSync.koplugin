--[[--
Lists: the index (yours, then the ones you
follow, each with covers, a name and its small print), opening a list in the shelf
screen (a ranked list is numbered), an empty list, the failed and offline states.

Screens: lists, lists_search, lists_search_empty, lists_ranked, lists_ranked_search, lists_followed, lists_empty_list, lists_none.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function new_manager(emu, settings)
  local LuaSettings = require("luasettings")
  local ShelfCache = require("hardcover/lib/shelf_cache")
  local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_lists.lua"
  os.remove(path)
  local DialogManager = require("hardcover/lib/ui/dialog_manager")
  return DialogManager:new {
    settings = settings,
    shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end },
  }
end

local function tap_text(emu, needle)
  local node = emu:expectText(needle)
  emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
  emu:pump()
end

local function calls_named(name)
  local n = 0
  for _, c in ipairs(fixtures.calls) do if c.name == name then n = n + 1 end end
  return n
end

local function search_bar()
  for widget in UIManager:topdown_widgets_iter() do
    if widget.name == "hardcover_search_bar" then return widget end
  end
end

return {
  name = "lists",

  run = function(emu)
    local SETTING = require("hardcover/lib/constants/settings")
    local settings = fixtures.real_settings(emu)
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    for _, b in ipairs(fixtures.shelf_books) do
      local image = b.cached_image
      if image and image.url then fixtures.seed_cover(image.url, b.book_id % 3 + 1) end
    end
    fixtures.install({ settings = settings })
    local manager = new_manager(emu, settings)

    -- the index
    manager:showLists()
    emu:pump()
    local dialog = manager.lists_dialog
    assert(dialog and UIManager:isWidgetShown(dialog), "the lists did not open")
    for _, expected in ipairs({
      "Your lists", "To Read - SciFi", "7 books \194\183 ranked", "Books that made me grin", "4 books",
      "Research", "1 book \194\183 private", "Someday", "0 books", "Following",
      "Top 25 Books to Unleash Your Creative Potential", "18 books \194\183 by hardcover",
    }) do
      emu:expectText(expected)
    end
    emu:shot("lists")

    -- The index searches names locally; it must not issue another API request.
    local calls_before_search = #fixtures.calls
    dialog.search_field.field_button:onTapSelectRow()
    local input = search_bar()
    assert(input and input.name == "hardcover_search_bar", "the list search field did not open its input")
    input:setInputText("Research")
    input:submit()
    emu:pump()
    assert(dialog.search_query == "Research", "the query was not applied")
    emu:expectText("Research")
    assert(not emu:screenText():find("To Read - SciFi", 1, true), "unmatched lists were still shown")
    assert(#fixtures.calls == calls_before_search, "local index search made an API request")
    emu:shot("lists_search")
    dialog.search_field.clear_button:onTapSelectRow()
    emu:pump()
    emu:expectText("To Read - SciFi")
    dialog.search_field.field_button:onTapSelectRow()
    input = search_bar()
    input:setInputText("not a list")
    input:submit()
    emu:pump()
    emu:expectText("No lists found")
    assert(#fixtures.calls == calls_before_search, "empty local index search made an API request")
    emu:shot("lists_search_empty")
    dialog.search_field.clear_button:onTapSelectRow()
    emu:pump()
    emu:expectText("To Read - SciFi")

    -- a ranked list opens in the shelf screen, in the list's order, numbered
    tap_text(emu, "To Read - SciFi")
    local shelf = manager.shelf_dialog
    local top = UIManager:getTopmostVisibleWidget()
    assert(top and top.title == "To Read - SciFi", "the list did not open, top is " .. tostring(top and top.name))
    emu:expectText("The Lathe of Heaven")
    -- (the rank is a large numeral at the left of each row)
    assert(top.items[1].rank == 1 and top.items[2].rank == 2, "the rows are not numbered")
    assert(#top.entries == 7, "the list holds 7 books, the screen has " .. #top.entries)
    assert(top.entries[1].rank == 1 and top.entries[7].rank == 7, "ranks are not 1..7")
    emu:shot("lists_ranked")
    -- Search the downloaded list by title and author, retaining the list's rank order and making no request.
    calls_before_search = #fixtures.calls
    assert(top.search_button, "the list has no search action")
    top.search_button:onTapSelectRow()
    input = search_bar()
    assert(input and input.name == "hardcover_search_bar", "the list-content search action did not open")
    input:setInputText("lathe le guin")
    input:submit()
    emu:pump()
    assert(#top.visible_entries == 1 and top.visible_entries[1].title == "The Lathe of Heaven",
      "local title-and-author search returned " .. #top.visible_entries .. " rows")
    assert(top.visible_entries[1].rank == 1, "the ranked list's position was not kept")
    assert(#fixtures.calls == calls_before_search, "local list search made an API request")
    emu:expectText("The Lathe of Heaven")
    assert(not emu:screenText():find("Kindred", 1, true), "an unmatched book was still shown")
    emu:shot("lists_ranked_search")
    top.search_field.clear_button:onTapSelectRow()
    emu:pump()
    assert(#top.visible_entries == 7, "clearing the search did not restore all books")
    -- the order is the list's own, not the shelf's added-date order
    assert(top.entries[1].title == fixtures.shelf_books[1].title, "not in list order")
    -- a book opens its details; closing comes back to the list
    tap_text(emu, "Kindred")
    local detail = UIManager:getTopmostVisibleWidget()
    assert(detail and detail.name == "hardcover_book_detail", "a book did not open: " .. tostring(detail and detail.name))
    UIManager:close(detail)
    emu:pump()
    top:onClose()
    emu:pump()
    assert(UIManager:getTopmostVisibleWidget() == dialog, "closing the list did not come back to the lists")

    -- an unranked list has no numbers
    tap_text(emu, "Books that made me grin")
    top = UIManager:getTopmostVisibleWidget()
    assert(top.title == "Books that made me grin" and #top.entries == 4)
    for _, entry in ipairs(top.entries) do assert(entry.rank == nil, "an unranked list was numbered") end
    top:onClose()
    emu:pump()

    -- a list with nothing in it says so
    tap_text(emu, "Someday")
    emu:expectText("No books on this list yet")
    emu:shot("lists_empty_list")
    UIManager:getTopmostVisibleWidget():onClose()
    emu:pump()

    -- a followed list is read through the followed part of `me`
    tap_text(emu, "Top 25 Books")
    local followed_call
    for _, c in ipairs(fixtures.calls) do
      if c.name == "getListBooks" and c.args.list_id == 106 then followed_call = c.args end
    end
    assert(followed_call and followed_call.source == "followed" and followed_call.ranked == false,
      "a followed list was not read as followed")
    emu:shot("lists_followed")
    UIManager:getTopmostVisibleWidget():onClose()
    emu:pump()

    -- closing the index leaves it
    dialog:onClose()
    emu:pump()
    assert(not UIManager:isWidgetShown(dialog), "closing the lists left them on screen")
    emu:closeAll()

    -- no lists at all
    fixtures.install({ settings = settings, lists_me = { { lists = {}, followed_lists = {} } } })
    manager = new_manager(emu, settings)
    manager:showLists()
    emu:pump()
    emu:expectText("No lists yet")
    emu:shot("lists_none")
    emu:closeAll()
  end,
}
