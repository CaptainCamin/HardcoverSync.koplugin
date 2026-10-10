--[[--
Searching for books from the home screen, with real taps.

Home -> "Search books" button -> input dialog -> Search -> results list (the
shelf's five-tall-row list) -> tap a row -> book details -> close -> back on the
results -> Close -> home again. Also a query with no matches, an empty query
(must make no request) and an offline search (must make no request).

Screens: search_home, search_input, search_results, search_book, search_none,
search_offline.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function topmost() return UIManager:getTopmostVisibleWidget() end

-- the node whose text is exactly `text` (the last one: dialogs draw on top)
local function exact(emu, text)
  local found
  for _, node in ipairs(emu:screenNodes()) do
    if node.text == text then found = node end
  end
  assert(found, "no '" .. text .. "' on screen:\n" .. emu:screenText())
  return found
end

local function type_and_submit(emu, text)
  local input = topmost()
  assert(input and input.getInputText, "the Search books button did not open an input dialog, top is "
    .. tostring(input and input.name))
  input:setInputText(text)
  -- positions are only real once painted
  UIManager:setDirty(nil, "full")
  UIManager:_repaint()
  local button = exact(emu, "Search")
  emu:tapExpecting(button.x + 5, button.y + 5)
end

return {
  name = "search_home",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    for _, id in ipairs({ 101, 102, 105 }) do
      fixtures.seed_cover("https://covers.hardcover.app/fixture/" .. id .. ".jpg")
    end
    local api = fixtures.install({ settings = settings })

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings }
    local NetworkManager = require("ui/network/manager")

    manager:showHome()
    emu:pump()
    local home = manager.home_dialog
    assert(home and UIManager:isWidgetShown(home), "home did not open")
    emu:expectText("Search books")
    emu:expectText("Library")
    emu:shot("search_home")

    -- the button is above the cards and everything still fits on the screen
    local button = emu:expectText("Search books")
    local screen_h = require("device").screen:getHeight()
    for _, row in ipairs(home.rows) do
      -- Currently Reading has no tile: its heading opens it
      local node = emu:expectText(row.title == "Currently Reading" and "Currently reading" or row.title)
      assert(node.y + node.h <= screen_h, "shelf button " .. row.title .. " is off the screen")
    end

    -- the button opens the input
    -- (the field's own rectangle: text drawn inside a scrolling page is not positioned in
    -- screen coordinates)
    local field = home.search_button.dimen
    emu:tapExpecting(field.x + 5, field.y + 5)
    local input = topmost()
    assert(input and input.getInputText, "the button opened nothing")
    emu:shot("search_input")

    -- an empty submit makes no request and leaves the input open
    local before = #(api.calls or {})
    input:setInputText("   ")
    local go = exact(emu, "Search")
    emu:tap(go.x + 5, go.y + 5)
    assert(topmost() == input, "an empty search closed the input")
    assert(not manager.search_results_dialog, "an empty search opened results")
    assert(#(api.calls or {}) == before, "an empty search made a request")

    -- a real query
    type_and_submit(emu, "earthsea")
    emu:pump()
    local results = manager.search_results_dialog
    assert(results and UIManager:isWidgetShown(results), "submitting did not show results")
    emu:expectText("A Wizard of Earthsea")
    emu:expectText("Ursula K. Le Guin")
    local items = results.items
    assert(#items == 1, "expected 1 result, got " .. #items)
    for i, item in ipairs(items) do
      assert(item.row.title and item.row.title ~= "", "row " .. i .. " has no title")
      assert(item.rating == nil and item.rank == nil, "row " .. i .. " shows a rating or a rank it does not have")
    end
    assert(results.sort_button == nil, "search results have a sort button (they are in relevance order)")
    emu:shot("search_results")

    -- tapping a row opens its details
    local title = emu:expectText("A Wizard of Earthsea")
    emu:tapExpecting(title.x + 5, title.y + 5)
    local top = topmost()
    assert(top and top.name == "hardcover_book_detail",
      "tapping a result did not open the book, top is " .. tostring(top and top.name))
    emu:shot("search_book")
    UIManager:close(top)
    emu:pump()
    assert(topmost() == results, "closing the details did not return to the results")

    -- Close returns to home
    emu:screenNodes()
    local close = results.close_button
    assert(close and close.dimen, "results have no back button")
    emu:tapExpecting(close.dimen.x + 5, close.dimen.y + 5)
    emu:pump()
    assert(not UIManager:isWidgetShown(results), "Close left the results open")
    assert(topmost() == home, "closing the results did not return to home")

    -- no matches: an answer, not a blank list
    local b = home.search_button.dimen
    emu:tapExpecting(b.x + 5, b.y + 5)
    type_and_submit(emu, "zzzzznotfound")
    emu:pump()
    emu:expectText("No results")
    emu:shot("search_none")
    emu:closeAll()

    -- offline: a clear message and no request
    manager:showHome()
    emu:pump()
    local calls = #(api.calls or {})
    local was = NetworkManager.isConnected
    NetworkManager.isConnected = function() return false end
    -- the plugin also trusts KOReader's own record of the connection, so go offline in both
    local was_state = NetworkManager.getConnectionState
    NetworkManager.getConnectionState = function() return false end
    manager:searchBooks("earthsea")
    emu:pump()
    NetworkManager.isConnected = was
    NetworkManager.getConnectionState = was_state
    emu:expectText("internet connection")
    assert(#(api.calls or {}) == calls, "searched while offline")
    emu:shot("search_offline")
    emu:closeAll()
  end,
}
