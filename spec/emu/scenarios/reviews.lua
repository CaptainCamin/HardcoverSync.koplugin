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
    -- a reviewer whose name carries an emoji: no shipped font draws the rat, so the name
    -- must reach the screen without it (a missing-glyph box otherwise)
    fixtures.reviews[4].user = { username = "ratreader", name = "Rat \240\159\144\128" }
    fixtures.install({ settings = settings, overrides = { getShelf = function() return {}, nil, false end } })
    for _, id in ipairs({ 103, 105, 301, 302, 303, 304, 305, 306, 101 }) do
      fixtures.seed_cover(fixtures.cover_url(id), id % 3 + 1)
    end

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local SqliteStore = require("hardcover/lib/sqlite_store")
    local ReviewStore = require("hardcover/lib/review_store")
    local User = require("hardcover/lib/user")
    local db = SqliteStore:new { path = os.getenv("KO_HOME") .. "/reviews.sqlite3" }
    db:clear()
    local store = ReviewStore:new { db = db }
    local manager = DialogManager:new { settings = settings, review_store = store }
    local NetworkManager = require("ui/network/manager")

    manager:showBookDetail(103)
    emu:pump()
    local details = emu.UIManager:getTopmostVisibleWidget()
    assert(details and details.reviews_heading, "the details screen has no Reviews heading")
    assert(#review_calls() == 0, "reviews were fetched before the reader asked")

    -- The button is under About, in the scrolling body: it must be inside what is visible
    -- (nothing is clipped away from a tap on it).
    emu:expectText("Reviews")
    emu:shot("reviews_details")
    assert(emu:tap(centre(details.reviews_heading.dimen)), "tapping Reviews did nothing")
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

    -- the emoji reviewer: the name is drawn, the rat is not (no font has it). Bring the fourth
    -- card to the top of the scroll: its place is the fixed blocks above it plus three cards.
    local Theme = require("hardcover/lib/ui/theme")
    local cw = dialog.width - 2 * Theme.margin - require("hardcover/lib/ui/components/scroll_control").gutter()
    local function block_h(w)
      local s = w:getSize().h
      if type(w.free) == "function" then pcall(w.free, w) end
      return s
    end
    local top = Theme.space.m
    local summary = dialog:buildSummary(cw)
    if summary then top = top + block_h(summary) end
    local own = dialog:buildYourBlock(cw)
    if own then top = top + block_h(own) end
    top = top + block_h(dialog:communityHeader(cw, #dialog:communityReviews()))
    top = top + 3 * dialog:cardMetrics(cw).height
    local scroll = dialog.scroll
    local crop, max = scroll._crop_h, scroll._max_scroll_offset_y
    local target = math.max(0, math.min(max, top - 20))
    scroll:scrollToRatio(0, (target + math.floor(crop / 2 + 0.5)) / (max + crop))
    emu:pump()
    emu:expectText("Rat")
    assert(not emu:screenText():find("\240\159\144\128", 1, true), "the emoji reached the screen")
    emu:shot("reviews_emoji_name")
    scroll_top(emu, dialog)

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

    -- a long review is cut in the list; the end of it is not drawn. On a short screen the
    -- first card's button may be below the fold, so bring the card into view before tapping.
    gone(emu, "(6)")
    assert(#review_calls() == 1, "tapping a row fetched something")
    scroll_to(emu, dialog, "Read more")
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
    -- A new store instance reads the saved full text and every loaded page from SQLite.
    db:close()
    db = SqliteStore:new { path = os.getenv("KO_HOME") .. "/reviews.sqlite3" }
    manager.review_store = ReviewStore:new { db = db }
    manager:showReviews(103)
    emu:pump()
    dialog = emu:top()
    assert(#dialog.reviews == 23 and dialog.offset == 23 and not dialog.has_more)
    emu:expectText("Offline. Saved")
    emu:expectText("Maya Okafor")
    emu:shot("reviews_cached_offline")
    scroll_to(emu, dialog, "Contains spoilers")
    gone(emu, "turns out to have been dead")
    tap_button(emu, dialog, "Contains spoilers")
    emu:expectText("turns out to have been dead")
    scroll_top(emu, dialog)
    tap_button(emu, dialog, "Read more")
    emu:expectText("(6)")
    emu:shot("reviews_cached_full")
    emu:closeAll()

    manager:showReviews(105)
    emu:pump()
    emu:expectText("No reviews yet")
    emu:expectText("Offline. Saved")
    emu:shot("reviews_cached_empty")
    emu:closeAll()

    manager:showReviews(999)
    emu:pump()
    emu:expectText("No reviews saved")
    emu:shot("reviews_offline")
    emu:closeAll()

    -- Offline with no saved community page, your own block is still there.
    manager:showReviews(999, nil, { rating = 4, text = "", rating_state = "Waiting to send" }, nil)
    emu:pump()
    for _, expected in ipairs({ "Your review", "No written review", "Write your review" }) do
      emu:expectText(expected)
    end
    emu:shot("reviews_offline_mine")
    emu:closeAll()
    assert(#review_calls() == before, "asked for reviews while offline")

    NetworkManager.isConnected = was
    NetworkManager.getConnectionState = was_state

    -- A failed background refresh leaves all the saved pages visible and on disk.
    local Api = require("hardcover/lib/hardcover_api")
    local async = Api.getReviewsAsync
    local pending
    Api.getReviewsAsync = function(_, _, _, _, cb) pending = cb end
    manager:showReviews(103)
    emu:pump()
    dialog = emu:top()
    assert(#dialog.reviews == 23 and dialog.loading, "saved copy was not shown before refresh")
    pending(nil, { message = "offline" })
    emu:pump()
    emu:expectText("Could not refresh")
    assert(#dialog.reviews == 23 and not dialog.loading)
    assert(#manager.review_store:get(User:getId(), 103).reviews == 23)
    emu:shot("reviews_cached_refresh_failed")
    emu:closeAll()

    -- Refresh replaces old ordering and old text, rather than appending a second copy.
    manager:showReviews(103)
    pending({ { id = 1, review_raw = "Updated review after refresh.", user = { name = "Maya" } } })
    emu:pump()
    dialog = emu:top()
    assert(#dialog.reviews == 1 and dialog.offset == 1 and not dialog.cache_note)
    emu:expectText("Updated review after refresh.")
    emu:shot("reviews_refreshed")
    emu:closeAll()

    -- Closing before a response must still save it, without rebuilding the closed screen.
    manager:showReviews(103)
    emu:closeAll()
    local raw = {}
    for i = 1, 10 do raw[i] = { id = i, review_raw = "Partial saved review " .. i } end
    pending(raw)
    Api.getReviewsAsync = async
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end
    manager:showReviews(103)
    emu:pump()
    dialog = emu:top()
    assert(#dialog.reviews == 10 and dialog.offset == 10 and dialog.has_more)
    for _ = 1, 40 do
      if dialog.scroll:getScrolledOffset().y >= dialog.scroll._max_scroll_offset_y then break end
      emu:screenNodes()
      emu:tap(emu.Screen:getWidth() - 10, emu.Screen:getHeight() - 20)
      emu:pump()
    end
    assert(dialog.scroll:getScrolledOffset().y >= dialog.scroll._max_scroll_offset_y)
    emu:expectText("More reviews need a connection")
    gone(emu, "No more reviews")
    gone(emu, "Load more reviews")
    emu:shot("reviews_cached_partial")
    emu:closeAll()
    NetworkManager.isConnected = was
    NetworkManager.getConnectionState = was_state
    assert(manager.review_store:get(User:getId() + 1, 103) == nil, "another account saw the saved reviews")

    -- An older pagination response cannot restore pages discarded by a newer visit's refresh.
    Api.getReviewsAsync = function(_, _, _, _, cb) pending = cb end
    manager:showReviews(103)
    pending(raw)
    dialog = emu:top()
    dialog:loadMore()
    local old_page = pending
    emu:closeAll()
    manager:showReviews(103)
    pending({ { id = 901, review_raw = "Newest visit's review." } })
    old_page({ { id = 902, review_raw = "Late page from the previous visit." } })
    emu:pump()
    local latest = manager.review_store:get(User:getId(), 103)
    assert(#latest.reviews == 1 and latest.reviews[1].id == 901 and latest.offset == 1,
      "a superseded page overwrote the latest snapshot")
    emu:expectText("Newest visit's review.")
    emu:closeAll()

    -- A disk write failure leaves the old saved copy intact, without blocking reading online.
    manager:showReviews(103)
    local put = db.putBlob
    db.putBlob = function() return false end
    pending({ { id = 903, review_raw = "Readable even when the cache cannot be written." } })
    db.putBlob = put
    emu:pump()
    emu:expectText("Readable even when the cache cannot be written.")
    assert(manager.review_store:get(User:getId(), 103).reviews[1].id == 901)
    emu:closeAll()

    -- Sign-out invalidates outstanding requests before clearing the account's library.
    manager:showReviews(103)
    emu:closeAll()
    manager.review_store:invalidate()
    db:clear()
    pending(raw)
    assert(manager.review_store:get(User:getId(), 103) == nil, "a late response repopulated a cleared cache")

    -- Ten rating-only rows are not an empty completed snapshot: paging still starts at ten.
    manager:showReviews(103)
    local textless = {}
    for i = 1, 10 do textless[i] = { id = i, review_raw = "" } end
    pending(textless)
    dialog = emu:top()
    assert(#dialog.reviews == 0 and dialog.has_more and dialog.offset == 10 and not dialog.message)
    latest = manager.review_store:get(User:getId(), 103)
    assert(#latest.reviews == 0 and latest.more and latest.offset == 10)
    emu:pump()
    emu:expectText("Load more reviews")
    gone(emu, "No reviews yet")
    emu:closeAll()
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end
    manager:showReviews(103)
    emu:pump()
    emu:expectText("More reviews need a connection")
    gone(emu, "No reviews yet")
    emu:closeAll()
    NetworkManager.isConnected = was
    NetworkManager.getConnectionState = was_state
    Api.getReviewsAsync = async

    -- The combined page: your review and rating above the community list.
    manager:showReviews(103, { title = "The Left Hand of Darkness", rating = 4.2, count = 120 },
      { rating = 4, text = "My own words", rating_state = "Waiting to send",
        review_state = "Saved on this device" }, nil)
    emu:pump()
    for _, expected in ipairs({ "Your review", "Your rating", "My own words",
      "Saved on this device", "Edit your review" }) do
      emu:expectText(expected)
    end
    emu:shot("reviews_mine")
    emu:closeAll()

    manager:showReviews(105, { title = "The Hundred Thousand Kingdoms", rating = 3.8, count = 40 },
      { rating = 4, text = "", rating_state = "Waiting to send" }, nil)
    emu:pump()
    for _, expected in ipairs({ "No written review", "Write your review", "Waiting to send" }) do
      emu:expectText(expected)
    end
    emu:shot("reviews_mine_no_review")
    emu:closeAll()

    manager:showReviews(103, { title = "The Left Hand of Darkness", rating = 4.2, count = 120 },
      { rating = 4, text = "My own words", spoilers = true,
        rating_state = "Needs your decision", review_state = "Needs your decision" }, nil)
    emu:pump()
    for _, expected in ipairs({ "Needs your decision", "Your review", "Contains spoilers",
      "Your rating", "My own words" }) do
      emu:expectText(expected)
    end
    emu:shot("reviews_mine_conflict")
    emu:closeAll()

    db:close()
  end,
}
