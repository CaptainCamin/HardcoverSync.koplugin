--[[--
Other readers' reviews, driven with real taps: book details -> Reviews, a hidden
spoiler, Read more, Load more (and a failed one), the empty and offline states,
and Close.

Screens: reviews_first, reviews_scrolled, reviews_spoiler_shown, reviews_full, reviews_more,
reviews_load_failed, reviews_end, reviews_empty, reviews_offline.
]]

local fixtures = require("fixtures")

local function centre(d) return d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2) end

-- the node on screen whose text contains `needle` (a button's node carries its
-- painted rectangle; so does any text)
local function find_node(emu, needle)
  local screen_h = emu.Screen:getHeight()
  for _, node in ipairs(emu:screenNodes()) do
    -- on the screen: a scrolling list also holds the blocks scrolled out of view
    if node.text:find(needle, 1, true) and node.x and not node.relative
        and node.y >= 0 and node.y + node.h <= screen_h then
      return node
    end
  end
end

local function tap_row(emu, dialog, needle)
  local node = find_node(emu, needle)
  assert(node, "nothing on this page contains " .. needle .. ":\n" .. emu:screenText())
  local ok = emu:tap(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
  assert(ok, string.format("tap on %s was not handled: %d,%d,%d,%d page %s", needle, node.x, node.y, node.w, node.h, tostring(dialog.page)))
  emu:pump()
end

-- does any widget under `widget` carry this text?
local function has_text(widget, needle, seen)
  if type(widget) ~= "table" or seen[widget] then return false end
  seen[widget] = true
  if type(widget.text) == "string" and widget.text:find(needle, 1, true) then return true end
  for _, child in pairs(widget) do
    if has_text(child, needle, seen) then return true end
  end
  return false
end

-- the painted button (a TapRow) whose label contains `needle`, found in the widget tree: a Button's
-- label is a relative node on screen, so it cannot be located from the screen text
local function find_tap(widget, needle, seen)
  seen = seen or {}
  if type(widget) ~= "table" or seen[widget] then return end
  seen[widget] = true
  if widget.callback and widget.dimen and widget.dimen.x and widget.dimen.y
      and has_text(widget, needle, {}) then
    return widget
  end
  for _, child in pairs(widget) do
    local found = find_tap(child, needle, seen)
    if found then return found end
  end
end

local function tap_button(emu, dialog, needle)
  emu:screenNodes() -- paint first: a tap range is only real once painted
  local btn = find_tap(dialog, needle)
  assert(btn, "no painted button containing " .. needle)
  local d = btn.dimen
  assert(d.y >= 0 and d.y + d.h <= emu.Screen:getHeight(), "button is off screen: " .. needle)
  assert(emu:tap(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2)), "tap on button " .. needle .. " was not handled")
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

-- tap the scroll control's down triangle until a row containing `needle` is on screen
local function scroll_to(emu, dialog, needle)
  local W, H = emu.Screen:getWidth(), emu.Screen:getHeight()
  for _ = 1, 30 do
    if find_node(emu, needle) then return end
    local btn = find_tap(dialog, needle)
    if btn and btn.dimen.y >= 0 and btn.dimen.y + btn.dimen.h <= H then return end
    local before = dialog.scroll and dialog.scroll:getScrolledOffset().y
    emu:tap(W - 10, H - 20)
    emu:pump()
    if dialog.scroll and dialog.scroll:getScrolledOffset().y == before then break end
  end
  local btn = find_tap(dialog, needle)
  assert(find_node(emu, needle) or (btn and btn.dimen.y >= 0 and btn.dimen.y + btn.dimen.h <= H), "never found a row containing " .. needle .. " (offset " .. tostring(dialog.scroll and dialog.scroll:getScrolledOffset().y) .. ", max " .. tostring(dialog.scroll and dialog.scroll._max_scroll_offset_y) .. ")\n" .. emu:screenText())
end

-- back to the top, with the up triangle
local function scroll_top(emu, dialog)
  local W = emu.Screen:getWidth()
  for _ = 1, 30 do
    if not dialog.scroll or dialog.scroll:getScrolledOffset().y <= 0 then return end
    emu:screenNodes()
    emu:tap(W - 10, dialog.scroll.dimen.y + 20)
    emu:pump()
  end
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
    emu:expectText("4.5") -- after a star icon
    emu:expectText("48 likes")
    emu:expectText("Read more")
    -- the book and its rating head the first page: the figure, the glyphs and the
    -- breakdown by star
    emu:expectText("The Left Hand of Darkness")
    emu:expectText("4.2")
    emu:expectText("120 ratings")
    assert(dialog.summary and dialog.summary.distribution and dialog.summary.distribution.total == 120, "no rating breakdown")
    emu:shot("reviews_first")

    -- one scrolling list: the scroll control steps by blocks, and no page counter or Previous/Next
    assert(dialog.scroll, "the reviews are not one scrolling list")
    gone(emu, "Previous")
    gone(emu, "Page 1 of")
    local W, H = emu.Screen:getWidth(), emu.Screen:getHeight()
    emu:tapExpecting(W - 10, H - 20)
    emu:pump()
    assert(dialog.scroll:getScrolledOffset().y > 0, "the down triangle did not scroll the list")
    emu:expectText("A reader")
    emu:shot("reviews_scrolled")
    scroll_top(emu, dialog)
    assert(dialog.scroll:getScrolledOffset().y == 0, "the up triangle did not return to the top")
    emu:expectText("Maya Okafor")

    -- the spoiler is hidden by default, and its text is not drawn anywhere. The rating
    -- summary heads page 1, so the spoiler card (the second review) is dealt to a later page.
    scroll_to(emu, dialog, "Contains spoilers")
    emu:expectText("Contains spoilers - tap to show")
    gone(emu, "turns out to have been dead")
    tap_button(emu, dialog, "Contains spoilers")
    emu:expectText("turns out to have been dead")
    gone(emu, "Contains spoilers - tap to show")
    emu:shot("reviews_spoiler_shown")
    scroll_top(emu, dialog)

    -- a long review is cut in the list; the end of it is not drawn
    gone(emu, "(6)")
    assert(#review_calls() == 1, "tapping a row fetched something")
    tap_button(emu, dialog, "Read more")
    local viewer = emu.UIManager:getTopmostVisibleWidget()
    assert(viewer ~= dialog, "Read more did not open the full review")
    emu:expectText("(6)")
    emu:shot("reviews_full")
    emu.UIManager:close(viewer)
    emu:pump()
    assert(emu.UIManager:getTopmostVisibleWidget() == dialog, "closing the viewer did not return to the list")

    -- Load more: the next ten, by offset
    scroll_to(emu, dialog, "Load more reviews")
    tap_button(emu, dialog, "Load more reviews")
    calls = review_calls()
    assert(#calls == 2 and calls[2].offset == 10 and calls[2].limit == 10,
      "Load more did not ask for the next ten")
    assert(#dialog.reviews == 20, "expected 20 reviews after Load more, got " .. #dialog.reviews)
    scroll_to(emu, dialog, "Review number 11")
    emu:shot("reviews_more")

    -- a failed page offers a retry, and the retry fetches the same page
    fixtures.reviews_fail = 1
    scroll_to(emu, dialog, "Load more reviews")
    tap_button(emu, dialog, "Load more reviews")
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
    -- to the end of the list: the down triangle goes dotted and the last block says there is no more
    for _ = 1, 40 do
      if dialog.scroll:getScrolledOffset().y >= dialog.scroll._max_scroll_offset_y then break end
      emu:screenNodes() -- paint: tap ranges are only real once painted
      emu:tap(emu.Screen:getWidth() - 10, emu.Screen:getHeight() - 20)
      emu:pump()
    end
    assert(dialog.scroll:getScrolledOffset().y >= dialog.scroll._max_scroll_offset_y, string.format("never reached the end of the list (%s of %s, top is %s)", tostring(dialog.scroll:getScrolledOffset().y), tostring(dialog.scroll._max_scroll_offset_y), tostring(emu:top() and emu:top().name)))
    emu:screenNodes()
    assert(emu:screenText():find("No more reviews", 1, true), "the end of the list does not say there are no more")
    assert(not find_node(emu, "Load more reviews"), "Load more still offered after the last page")
    emu:shot("reviews_end")

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
