--[[--
Other readers' reviews, driven with real taps: book details -> Reviews, a hidden
spoiler, Read more, Load more (and a failed one), the empty and offline states,
and Close.

Screens: reviews_first, reviews_spoiler_shown, reviews_full, reviews_more,
reviews_load_failed, reviews_empty, reviews_offline.
]]

local fixtures = require("fixtures")

local function centre(d) return d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2) end

-- the node on screen whose text contains `needle` (a button's node carries its
-- painted rectangle; so does any text)
local function find_node(emu, needle)
  for _, node in ipairs(emu:screenNodes()) do
    if node.text:find(needle, 1, true) and node.x and not node.relative then return node end
  end
end

local function tap_row(emu, dialog, needle)
  local node = find_node(emu, needle)
  assert(node, "nothing on this page contains " .. needle .. ":\n" .. emu:screenText())
  local ok = emu:tap(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
  assert(ok, string.format("tap on %s was not handled: %d,%d,%d,%d page %s", needle, node.x, node.y, node.w, node.h, tostring(dialog.page)))
  emu:pump()
end

local function gone(emu, needle)
  for _, node in ipairs(emu:screenNodes()) do
    assert(not node.text:find(needle, 1, true), "should not be on screen: " .. needle)
  end
end

-- a button with this text anywhere under `widget` (ConfirmBox keeps its table private)
local function find_button(widget, text, seen)
  seen = seen or {}
  if type(widget) ~= "table" or seen[widget] then return end
  seen[widget] = true
  if widget.text == text and widget.callback and widget.dimen then return widget end
  for _, child in pairs(widget) do
    local found = find_button(child, text, seen)
    if found then return found end
  end
end

local function review_calls()
  local out = {}
  for _, c in ipairs(fixtures.calls) do
    if c.name == "getReviews" then out[#out + 1] = c.args end
  end
  return out
end

-- turn pages until a row containing `needle` is on screen
local function page_to(emu, dialog, needle)
  for _ = 1, 20 do
    if find_node(emu, needle) then return end
    dialog:onNextPage()
    emu:pump()
  end
  error("never found a row containing " .. needle)
end

return {
  name = "reviews",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings, overrides = { getShelf = function() return {}, nil, false end } })
    for _, id in ipairs({ 103, 105, 301, 302, 303, 304, 305, 306, 101 }) do
      fixtures.seed_cover(fixtures.cover_url(id), id % 3 + 1)
    end

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings }
    local NetworkManager = require("ui/network/manager")

    manager:showBookDetail(103)
    emu:pump()
    local details = emu.UIManager:getTopmostVisibleWidget()
    assert(details and details.reviews_button, "the details screen has no Reviews button")
    assert(#review_calls() == 0, "reviews were fetched before the reader asked")

    -- The button is under About, in the scrolling body: it must be inside what is visible
    -- (nothing is clipped away from a tap on it).
    emu:expectText("Reviews")
    emu:shot("reviews_details")
    assert(emu:tap(centre(details.reviews_button.dimen)), "tapping Reviews did nothing")
    emu:pump()

    local dialog = emu.UIManager:getTopmostVisibleWidget()
    assert(dialog and dialog.name == "hardcover_reviews_dialog", "Reviews did not open the reviews screen")
    local calls = review_calls()
    assert(#calls == 1 and calls[1].offset == 0 and calls[1].limit == 10,
      "expected exactly one request for ten reviews")

    -- first page: names, stars, likes
    emu:expectText("Maya Okafor")
    emu:expectText("\226\152\133 4.5")
    emu:expectText("48 likes")
    emu:expectText("Read more")
    -- the book and its rating head the first page: the figure, the glyphs and the
    -- breakdown by star
    emu:expectText("The Left Hand of Darkness")
    emu:expectText("4.2")
    emu:expectText("120 ratings")
    assert(dialog.summary and dialog.summary.distribution and dialog.summary.distribution.total == 120, "no rating breakdown")
    emu:shot("reviews_first")

    -- cards are dealt into pages that fit, and Next / Previous turn them
    assert(dialog.pages and #dialog.pages > 1, "the reviews were not paged")
    emu:expectText("Page 1 of " .. #dialog.pages)
    local screen_h = emu.Screen:getHeight()
    for _, node in ipairs(emu:screenNodes()) do
      assert(node.relative or node.y + node.h <= screen_h, node.text .. " is off the screen")
    end
    tap_row(emu, dialog, "Next")
    assert(dialog.page == 2, "Next did not turn the page")
    emu:expectText("Page 2 of")
    emu:expectText("A reader")
    tap_row(emu, dialog, "Previous")
    assert(dialog.page == 1, "Previous did not turn back")
    emu:expectText("Maya Okafor")

    -- the spoiler is hidden by default, and its text is not drawn anywhere. The rating
    -- summary heads page 1, so the spoiler card (the second review) is dealt to a later page.
    page_to(emu, dialog, "Contains spoilers")
    emu:expectText("Contains spoilers - tap to show")
    gone(emu, "turns out to have been dead")
    tap_row(emu, dialog, "Contains spoilers")
    emu:expectText("turns out to have been dead")
    gone(emu, "Contains spoilers - tap to show")
    emu:shot("reviews_spoiler_shown")
    while dialog.page > 1 do
      dialog:onPrevPage()
      emu:pump()
    end

    -- a long review is cut in the list; the end of it is not drawn
    gone(emu, "(6)")
    assert(#review_calls() == 1, "tapping a row fetched something")
    tap_row(emu, dialog, "Read more")
    local viewer = emu.UIManager:getTopmostVisibleWidget()
    assert(viewer ~= dialog, "Read more did not open the full review")
    emu:expectText("(6)")
    emu:shot("reviews_full")
    emu.UIManager:close(viewer)
    emu:pump()
    assert(emu.UIManager:getTopmostVisibleWidget() == dialog, "closing the viewer did not return to the list")

    -- Load more: the next ten, by offset
    page_to(emu, dialog, "Load more reviews")
    tap_row(emu, dialog, "Load more reviews")
    calls = review_calls()
    assert(#calls == 2 and calls[2].offset == 10 and calls[2].limit == 10,
      "Load more did not ask for the next ten")
    assert(#dialog.reviews == 20, "expected 20 reviews after Load more, got " .. #dialog.reviews)
    emu:expectText("Review number 11")
    emu:shot("reviews_more")

    -- a failed page offers a retry, and the retry fetches the same page
    fixtures.reviews_fail = 1
    page_to(emu, dialog, "Load more reviews")
    tap_row(emu, dialog, "Load more reviews")
    local box = emu.UIManager:getTopmostVisibleWidget()
    assert(box ~= dialog, "a failed page showed no retry")
    emu:expectText("Retry")
    emu:shot("reviews_load_failed")
    local retry = find_button(box, "Retry")
    assert(retry, "no Retry button on the failure dialog")
    assert(emu:tap(centre(retry.dimen)), "tapping Retry did nothing")
    emu:pump()
    calls = review_calls()
    assert(#calls == 4 and calls[4].offset == 20, "Retry did not refetch offset 20")
    assert(#dialog.reviews == 23, "expected 23 reviews, got " .. #dialog.reviews)
    assert(not dialog.has_more, "a short page left Load more on offer")
    assert(not find_node(emu, "Load more reviews"), "Load more still offered after the last page")

    -- Close returns to the details
    emu:key("Back")
    emu:pump()
    assert(not emu.UIManager:isWidgetShown(dialog), "Back did not close the reviews")
    assert(emu.UIManager:getTopmostVisibleWidget() == details, "closing reviews did not return to the details")

    -- a book with no reviews says so
    manager:showReviews(105)
    emu:pump()
    emu:expectText("No reviews yet")
    emu:shot("reviews_empty")
    emu:closeAll()

    -- offline: a clear message and no request
    local before = #review_calls()
    local was = NetworkManager.isConnected
    NetworkManager.isConnected = function() return false end
    -- the plugin also trusts KOReader's own record of the connection, so go offline in both
    local was_state = NetworkManager.getConnectionState
    NetworkManager.getConnectionState = function() return false end
    manager:showReviews(103)
    emu:pump()
    NetworkManager.isConnected = was
    NetworkManager.getConnectionState = was_state
    emu:expectText("internet connection")
    assert(#review_calls() == before, "asked for reviews while offline")
    emu:shot("reviews_offline")
    emu:closeAll()
  end,
}
