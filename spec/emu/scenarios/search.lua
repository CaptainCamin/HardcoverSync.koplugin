--[[--
Link-book search: the screen reached from the plugin's main menu.

Exercises the search dialog in both menu modes, since compatibility mode swaps
the vendored SearchMenu in for the stock Menu and the two do not share a draw
path.

Screens: search_results, search_results_compat, search_empty.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")
local SETTING = require("hardcover/lib/constants/settings")

local function open_search(emu, opts)
  local settings = fixtures.real_settings(emu)
  if opts.compatibility then
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, true)
  else
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
  end
  fixtures.install({ settings = settings })

  local DialogManager = require("hardcover/lib/ui/dialog_manager")
  local manager = DialogManager:new{ settings = settings }

  local books = fixtures.install().findBooks(nil, opts.query or "the", nil)
  manager:buildSearchDialog("Link book", books, nil, function() end, nil, opts.query)
  emu:pump()

  local dialog = manager.search_dialog
  assert(dialog, "buildSearchDialog produced no dialog")
  assert(UIManager:isWidgetShown(dialog), "search dialog was built but never shown")
  return dialog
end

return {
  name = "search",

  run = function(emu)
    -- Stock Menu path.
    local dialog = open_search(emu, { query = "the" })
    emu:expectText("Link book")
    emu:expectText("N. K. Jemisin")
    assert(dialog.name == "hardcover_search_dialog", "the dialog is named " .. tostring(dialog.name))

    --[[--
    Same file-marker invariant as the shelf: an item with neither .file nor
    .is_file is drawn through the folder branch, which is where this plugin
    crashed before.
    ]]
    local items = dialog.menu.item_table
    assert(#items > 0, "search produced no rows")
    for i, item in ipairs(items) do
      assert(item.file, string.format(
        "row %d (%s) has no file marker: it will draw as a folder",
        i, tostring(item.text)))
    end

    emu:shot("search_results")

    -- Vendored SearchMenu path.
    emu:closeAll()
    open_search(emu, { query = "the", compatibility = true })
    emu:shot("search_results_compat")

    -- A query that matches nothing must still produce a usable dialog rather
    -- than an error or a stale list.
    emu:closeAll()
    local empty = open_search(emu, { query = "zzzzznotfound" })
    assert(#empty.menu.item_table == 0,
      "a no-match query returned " .. #empty.menu.item_table .. " rows")
    emu:shot("search_empty")

    print(string.format("  %d search rows in each mode", #items))
  end,
}
