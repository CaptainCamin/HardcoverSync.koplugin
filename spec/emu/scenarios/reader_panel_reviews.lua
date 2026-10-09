--[[--
Reviews from the reader popup. The More menu lists Reviews straight after Book details.
For a linked book it opens the reviews screen; for an unlinked one it is greyed out and
does nothing. The menu and the dialogs are the real ones; the reader and the book state
are stand-ins, as in reader_panel_taps.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")
local NetworkManager = require("ui/network/manager")

local BOOK_ID = 103 -- the fixture book with 23 reviews

-- a menu for the reader popup, linked or not; `asks` collects what each withWifiThen was asked
local function build(linked, dialog_manager, asks)
  local settings = {
    bookLinked = function() return linked end,
    getLinkedTitle = function() return "The Left Hand of Darkness" end,
    getLinkedBookId = function() return BOOK_ID end,
    getLinkedEditionId = function() return nil end,
    getLinkedEditionFormat = function() return nil end,
    pages = function() return 304 end,
    syncEnabled = function() return true end,
    setSync = function() end,
    readSetting = function() return nil end,
  }
  local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
  local menu = HardcoverMenu:new({
    settings = settings,
    enabled = true,
    ui = {
      document = { file = "/books/x.epub", getPageCount = function() return 300 end },
      doc_props = { display_title = "x" },
      getCurrentPage = function() return 120 end,
    },
    state = { book_status = linked and { id = 1, status_id = 2, rating = 4.5,
      user_book_reads = { { progress_pages = 142 } } } or {} },
    cache = { cacheUserBook = function() end },
    sync_queue = { pendingCount = function() return 0 end, hasPending = function() return false end },
    auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
             statusText = function() return "Signed in" end },
    dialog_manager = dialog_manager,
    hardcover = {},
  })
  -- Book details and Reviews go through withWifiThen; wifi handling is not under test
  menu.withWifiThen = function(_, action, needs_wifi)
    asks[#asks + 1] = needs_wifi
    action(false)
  end
  return menu
end

-- the node drawn exactly as `text`, with its painted rectangle
local function node(emu, text)
  for _, n in ipairs(emu:screenNodes()) do
    if n.text == text and not n.relative then return n end
  end
  return emu:expectText(text)
end

local function centre(n) return n.x + math.floor(n.w / 2), n.y + math.floor(n.h / 2) end

-- the rows of the More screen, in order: each is { tap = the row, shows = "text|checked|dim" }
local function more_rows(emu)
  local top = emu:top()
  assert(top and top.name == "hardcover_settings", "More did not open its menu: " .. tostring(top and top.name))
  return top.taps
end

local function index_of(rows, text)
  for i, row in ipairs(rows) do
    if row.tap.text == text then return i end
  end
  error("no row called " .. text)
end

-- what is on the window stack, top first, by widget name
local function on_stack(name)
  for i = #UIManager._window_stack, 1, -1 do
    local widget = UIManager._window_stack[i].widget
    if widget and widget.name == name then return widget end
  end
end

local function review_calls()
  local out = {}
  for _, c in ipairs(fixtures.calls) do
    if c.name == "getReviews" then out[#out + 1] = c.args end
  end
  return out
end

return {
  name = "reader_panel_reviews",

  run = function(emu)
    local was_connected = NetworkManager.isConnected
    NetworkManager.isConnected = function() return true end

    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local dialog_manager = DialogManager:new { settings = settings }
    local asks = {}

    -- linked: Reviews sits right after Book details, is enabled, and opens the reviews
    local menu = build(true, dialog_manager, asks)
    menu:showReaderPanel()
    emu:pump()
    assert(emu:top() and emu:top().name == "hardcover_reader_panel", "the panel is not on top")

    -- More is the icon tile at the end of the Rate / Note row
    local note = emu:expectText("Note")
    emu:tapExpecting(emu.Screen:getWidth() - 20 - 36, note.y + math.floor(note.h / 2))
    emu:expectText("Linked book")

    local rows = more_rows(emu)
    local i = index_of(rows, "Book details")
    assert(rows[i + 1] and rows[i + 1].tap.text == "Reviews",
      "Reviews is not listed directly after Book details")
    assert(rows[i + 1].shows == "Reviews|false|nil",
      "Reviews should be enabled for a linked book: " .. rows[i + 1].shows)

    -- the separator moved from Book details to Reviews: a bigger gap follows Reviews
    -- than the one between Book details and Reviews
    local bd, rv = node(emu, "Book details"), node(emu, "Reviews")
    local after = node(emu, rows[i + 2].tap.text)
    assert(not rv.relative and not bd.relative and not after.relative, "the rows have no painted position")
    assert(after.y - rv.y > rv.y - bd.y, "no separator after Reviews: the gap is no bigger than between Book details and Reviews")
    emu:shot("reader_panel_reviews_menu")

    -- Reviews opens the reviews screen for the book, through the wifi wrapper like Book details
    local before = #review_calls()
    local reviews = node(emu, "Reviews")
    emu:tapExpecting(centre(reviews))
    emu:pump()
    assert(#asks == 1 and asks[1] == true, "Reviews did not ask for wifi the way Book details does")
    local dialog = on_stack("hardcover_reviews_dialog")
    assert(dialog, "Reviews did not open hardcover_reviews_dialog on the window stack")
    assert(emu:top() == dialog, "the reviews screen is not on top")
    local calls = review_calls()
    assert(#calls == before + 1 and calls[#calls].book_id == BOOK_ID and calls[#calls].offset == 0,
      "Reviews did not ask for the first page of this book")
    emu:closeAll()
    assert(not on_stack("hardcover_reviews_dialog"), "closeAll left the reviews screen open")

    -- unlinked: Reviews is greyed out in the same place, and a tap does nothing
    menu = build(false, dialog_manager, asks)
    menu:showReaderPanel()
    emu:pump()
    assert(emu:top() and emu:top().name == "hardcover_reader_panel", "the unlinked panel is not on top")
    local more = node(emu, "More")
    emu:tapExpecting(centre(more))
    emu:expectText("Link book")

    rows = more_rows(emu)
    i = index_of(rows, "Book details")
    assert(rows[i + 1] and rows[i + 1].tap.text == "Reviews",
      "Reviews is not listed directly after Book details (unlinked)")
    assert(rows[i + 1].shows == "Reviews|false|true",
      "Reviews should be greyed out for an unlinked book: " .. rows[i + 1].shows)
    -- and the menu item itself says the same
    local item
    for _, it in ipairs(menu:getSubMenuItems(true)) do
      if it.text == "Reviews" then item = it end
    end
    assert(item and item.enabled_func and item.enabled_func() == false, "the Reviews item is enabled for an unlinked book")
    emu:shot("reader_panel_reviews_unlinked_menu")

    local asked_before, calls_before = #asks, #review_calls()
    local greyed = node(emu, "Reviews")
    emu:tap(centre(greyed))
    emu:pump()
    assert(#asks == asked_before, "a greyed out Reviews still asked for wifi")
    assert(#review_calls() == calls_before, "a greyed out Reviews still fetched reviews")
    assert(not on_stack("hardcover_reviews_dialog"), "a greyed out Reviews opened the reviews screen")
    emu:closeAll()

    NetworkManager.isConnected = was_connected
    print("  reader popup: Reviews follows Book details, opens the reviews for a linked book, and is greyed out and inert when unlinked")
  end,
}
