--[[--
The home screen: what you are reading now (cards), then your shelves with how
many books are on each.

Run through the plugin's own entry point (DialogManager:showHome), the way the
Hardcover: Home action and the menu item reach it, against the real Menu widget.

Screens: home (counts and cards known), home_no_counts (nothing saved, nothing
fetched), home_shelf (a shelf opened from it), home_book (a card tapped).
Taps go through the gesture path, at the coordinates the screen was drawn at.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function new_manager(emu, name)
  local settings = fixtures.real_settings(emu)
  local LuaSettings = require("luasettings")
  local ShelfCache = require("hardcover/lib/shelf_cache")
  -- a cache file of its own per run, so one screen's saved counts never leak
  -- into the next one
  local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_" .. name .. ".lua"
  os.remove(path)

  local DialogManager = require("hardcover/lib/ui/dialog_manager")
  return DialogManager:new {
    settings = settings,
    shelf_cache = ShelfCache:new {
      path = path,
      open = function(p) return LuaSettings:open(p) end,
    },
  }, settings
end

return {
  name = "home",

  run = function(emu)
    --[[--
    Counts known: the screen opens, then the count query lands and the numbers
    appear. Rows are in a fixed order, reading first.
    ]]
    local manager, settings = new_manager(emu, "counts")
    for _, id in ipairs({ 101, 102 }) do
      fixtures.seed_cover("https://covers.hardcover.app/fixture/" .. id .. ".jpg")
    end
    fixtures.install({ settings = settings })

    manager:showHome()
    emu:pump()

    local dialog = manager.home_dialog
    assert(dialog, "showHome did not produce a dialog")
    assert(UIManager:isWidgetShown(dialog), "the home screen was built but never shown")

    -- the shelves are tiles (its count big, its name beside it); what you are
    -- reading is opened from its own heading, which carries the count
    for _, expected in ipairs({
      "3 books", "Currently reading", "42", "Want to Read", "130", "Read", "2", "Did Not Finish", "Library",
    }) do
      emu:expectText(expected)
    end
    for _, expected in ipairs({
      "The Dispossessed", "A Wizard of Earthsea", "The Hundred Thousand Kingdoms",
      "120 / 341", "20 / 183", "300 / 418", "Ursula K. Le Guin",
    }) do
      emu:expectText(expected)
    end

    -- the search field is at the top, above the reading list, a full-width
    -- field inside the page margins whose words sit in the middle of it
    local screen = require("device").screen
    local order = {}
    for i, node in ipairs(emu:screenNodes()) do order[node.text] = order[node.text] or i end
    assert(order["Search books on Hardcover"] and order["Currently reading"]
      and order["Search books on Hardcover"] < order["Currently reading"], "the search field is not above the list")
    local rows = dialog.rows
    assert(#rows == 4 and rows[1].title == "Currently Reading",
      "rows are not in the expected order")
    -- ...but the tile for it is gone: the heading takes its place
    for _, node in ipairs(emu:screenNodes()) do
      assert(node.text ~= "Currently Reading", "a Currently Reading tile is still drawn")
    end
    emu:shot("home")

    -- geometry is only real once the screen has been painted
    local field = manager.home_dialog.search_button
    assert(field and field.dimen, "no search field")
    -- (a page tall enough to scroll leaves its scroll bar a gutter on the right)
    assert(field.dimen.x == require("hardcover/lib/ui/theme").margin
      and field.dimen.x + field.dimen.w <= screen:getWidth() - require("hardcover/lib/ui/theme").margin,
      "the search field does not sit inside the margins")
    assert(field.dimen.h < screen:scaleBySize(60), "the search field is tall")
    -- (text drawn inside a scrolling page is not positioned in screen terms, so these two
    -- only mean something while the page fits)
    if not manager.home_dialog.scroll then
      local words = emu:expectText("Search books on Hardcover")
      assert(math.abs((words.y + words.h / 2) - (field.dimen.y + field.dimen.h / 2)) <= 4,
        "the search words are not vertically centred in the field")
      -- everything fits: the last tile ends above the bottom edge
      for _, node in ipairs(emu:screenNodes()) do
        assert(node.relative or node.y + node.h <= screen:getHeight(), node.text .. " is off the screen")
      end
    end


    -- every cover the fixture has was drawn: two pictures, one placeholder
    assert(#dialog.cover_bbs == 2, "expected 2 covers drawn, got " .. #(dialog.cover_bbs or {}))

    --[[--
    A tap on empty space below the shelves opens nothing: the cards answer only
    inside what they draw.
    ]]
    local bottom = emu:expectText("Did Not Finish")
    emu:tap(bottom.x + 5, bottom.y + 400)
    assert(UIManager:getTopmostVisibleWidget() == dialog, "a tap on empty space opened something")

    --[[--
    Tapping a card opens that book's details.
    ]]
    local title = emu:expectText("A Wizard of Earthsea")
    emu:tapExpecting(title.x + 5, title.y + 5)
    local top = UIManager:getTopmostVisibleWidget()
    assert(top and top.name == "hardcover_book_detail",
      "tapping a card did not open the book, top is " .. tostring(top and top.name))
    emu:shot("home_book")
    UIManager:close(top)
    emu:pump()

    --[[--
    The "Currently reading" heading is a button: it opens that shelf.
    ]]
    local heading = emu:expectText("Currently reading")
    emu:tapExpecting(heading.x + 5, heading.y + 5)
    assert(manager.shelf_dialog and UIManager:isWidgetShown(manager.shelf_dialog),
      "tapping the heading did not open the Currently Reading shelf")
    manager.shelf_dialog:onClose()
    emu:pump()
    assert(UIManager:getTopmostVisibleWidget() == dialog, "closing the shelf did not come back to Home")

    --[[--
    Choosing a shelf opens it on top, so closing it comes back here. A real tap
    on its button, not a call to the callback.
    ]]
    local row = emu:expectText("Want to Read")
    emu:tapExpecting(row.x + 5, row.y + 5)
    assert(manager.shelf_dialog and UIManager:isWidgetShown(manager.shelf_dialog),
      "tapping a shelf did not open it")
    assert(UIManager:isWidgetShown(dialog), "opening a shelf closed the home screen")
    emu:shot("home_shelf")
    emu:closeAll()

    --[[--
    Settings: a button on the home screen opens the same settings the menu has,
    in a screen of their own. Real taps throughout: into the list, on an option
    (which must flip the saved setting and redraw its tick), into a submenu and
    back out.
    ]]
    local SETTING = require("hardcover/lib/constants/settings")
    manager.settings_items = function()
      return require("hardcover/lib/ui/hardcover_menu"):new({
        settings = settings,
        auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
                 statusText = function() return "Signed in" end },
        enabled = true,
        sync_queue = { pendingCount = function() return 2 end, hasPending = function() return true end },
      }):getHomeSettingsItems()
    end
    manager:showHome()
    emu:pump()
    emu:shot("home_again")
    local cog = manager.home_dialog.title_bar.left_button
    assert(cog and cog.dimen, "the title bar has no settings cog")
    emu:tapExpecting(cog.dimen.x + 5, cog.dimen.y + 5)
    local top = UIManager:getTopmostVisibleWidget()
    assert(top ~= manager.home_dialog, "tapping Settings opened nothing")
    emu:expectText("Automatically link by ISBN")
    emu:expectText("Sync pending changes (2)")
    -- the account is a tile: a label and what it says ("Account: Signed in" would
    -- say the label twice)
    emu:expectText("Account")
    emu:expectText("Signed in")
    -- About is the last entry: everything the file browser's menu used to list
    emu:expectText("About")
    emu:shot("home_settings")

    -- every row is a boxed row inside the page margins, tall enough to hit
    local Theme = require("hardcover/lib/ui/theme")
    local ticks = function()
      local n = 0
      for _, node in ipairs(emu:screenNodes()) do
        if node.text == "\226\156\147" then n = n + 1 end
      end
      return n
    end
    local screen_w = require("device").screen:getWidth()
    for _, node in ipairs(emu:screenNodes()) do
      if node.text == "Automatically link by ISBN" or node.text == "About" then
        assert(node.x >= Theme.margin and node.x + node.w <= screen_w - Theme.margin, node.text .. " is outside the margins")
      end
    end
    local ticks_before = ticks()

    local before = settings:readSetting(SETTING.LINK_BY_ISBN) == true
    local option = emu:expectText("Automatically link by ISBN")
    emu:tapExpecting(option.x + 5, option.y + 5)
    assert(ticks() ~= ticks_before, "the tick box did not change when its option was tapped")
    assert((settings:readSetting(SETTING.LINK_BY_ISBN) == true) ~= before,
      "tapping an option did not change the setting")

    local sub = emu:expectText("Track progress settings")
    emu:tapExpecting(sub.x + 5, sub.y + 5)
    emu:expectText("Back")
    emu:shot("home_settings_sub")
    local back = emu:expectText("Back")
    emu:tapExpecting(back.x + 5, back.y + 5)
    emu:expectText("Automatically link by ISBN")
    emu:closeAll()

    --[[--
    Nothing saved and the count query failing (as when offline): the screen still
    opens, and shows no number rather than a made-up zero.
    ]]
    local bare, bare_settings = new_manager(emu, "bare")
    fixtures.install({
      settings = bare_settings,
      overrides = {
        getShelfCounts = function() return nil, { completed = false } end,
        getCurrentlyReading = function() return nil, { completed = false } end,
      },
    })

    bare:showHome()
    emu:pump()
    assert(bare.home_dialog, "the home screen did not open without counts")
    emu:expectText("Currently reading") -- the heading stays: it opens the shelf
    assert(not emu:screenText():find("The Dispossessed", 1, true), "showed cards that were never loaded")
    for _, row in ipairs(bare.home_dialog.rows) do
      assert(row.count == nil, "invented a count for " .. row.title)
    end
    emu:shot("home_no_counts")
    emu:closeAll()
  end,
}
