--[[--
"Similar to <title>" on a book's details: a strip of covers (Hardcover's ranking, in its
order) that arrives after the screen is up, a tap opening that book, a book with no
ranking or a failed answer showing nothing (the screen carries on), and the offline
case (no request at all).

Screens: similar_strip, similar_none, similar_loading, similar_with_series, similar_with_series_end.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function top() return UIManager:getTopmostVisibleWidget() end

local function calls_named(name)
  local n = 0
  for _, c in ipairs(fixtures.calls) do if c.name == name then n = n + 1 end end
  return n
end

local function tap_widget(emu, w)
  emu:screenNodes()
  assert(w and w.dimen and w.dimen.w > 0, "nothing to tap")
  emu:tapExpecting(w.dimen.x + math.floor(w.dimen.w / 2), w.dimen.y + math.floor(w.dimen.h / 2))
  emu:pump()
end

return {
  name = "similar",

  run = function(emu)
    local SETTING = require("hardcover/lib/constants/settings")
    local settings = fixtures.real_settings(emu)
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    for _, b in ipairs(fixtures.shelf_books) do
      local image = b.cached_image
      if image and image.url then fixtures.seed_cover(image.url, b.book_id % 3 + 1) end
    end
    fixtures.install({ settings = settings })
    -- this scenario is about the two strips, which both have to show at the bottom of the page:
    -- books with no community tags, ratings or extra detail rows keep the page short
    for _, b in pairs(fixtures.books_by_id) do
      b.cached_tags, b.ratings_distribution = {}, {}
      b.first_release_date, b.reviews_count, b.lists_count, b.editions_count = nil, nil, nil, nil
      b.contributions = { b.contributions and b.contributions[1] or nil }
    end
    fixtures.similar_ids = { 9, 4, 7, 2 } -- indexes into the fixture books: Hyperion first

    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_similar.lua"
    os.remove(path)
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new {
      settings = settings,
      shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end },
    }

    -- the strip arrives after the details are up, in the ranking's order
    local book_id = fixtures.shelf_books[1].book_id
    local details = manager:showBookDetail(book_id)
    emu:pump()
    local strip = details.similar_carousel
    assert(strip and details.similar_card, "the strip never arrived")
    assert(calls_named("getSimilarBooks") == 1, "requests: " .. calls_named("getSimilarBooks"))
    for i, idx in ipairs(fixtures.similar_ids) do
      assert(details.similar_card.items[i].book_id == fixtures.shelf_books[idx].book_id, "cover " .. i .. " is not in ranking order")
    end
    for _, expected in ipairs({ "Similar to The Lathe of Heaven", "4 books" }) do emu:expectText(expected) end
    emu:shot("similar_strip")

    -- a very long title: the heading is cut short, never wider than the page
    local real_open = details.on_open_similar
    local long = {}
    for i, item in ipairs(details.similar_card.items) do long[i] = item end
    details:setSimilar({ title = "Similar to " .. string.rep("The Extraordinarily Long Title ", 6), subtitle = "20 books",
      title_first = true, items = long }, function() end)
    local width = details.similar_carousel.widget:getSize().w
    local screen_w = emu.Screen:getWidth()
    assert(width <= screen_w, "the heading is " .. width .. " wide on a " .. screen_w .. " screen")
    assert(width <= details.similar_carousel.width, "the heading is wider than its strip: " .. width .. " > " .. details.similar_carousel.width)
    emu:expectText("20 books")
    emu:shot("similar_long_title")
    details:setSimilar(details.similar_card, real_open)
    UIManager:setDirty(nil, "full")
    UIManager:_repaint()
    details.scroll:scrollToRatio(0, 1)
    strip = details.similar_carousel

    -- a tap on a cover opens that book on top of this one; closing comes back
    -- (the strip is below the first screenful: scroll to it, taps are only answered where
    -- the page is showing)
    details.scroll:scrollToRatio(0, 1)
    emu:shot("similar_strip_end")
    local target = strip.targets[1]
    emu:screenNodes()
    emu:tapExpecting(target.dimen.x + math.floor(target.dimen.w / 2), target.dimen.y + math.floor(target.dimen.h / 2))
    emu:pump()
    local opened = top()
    assert(opened and opened.name == "hardcover_book_detail" and opened ~= details, "a cover did not open its book")
    UIManager:close(opened)
    emu:pump()
    assert(top() == details, "closing the book did not come back")
    emu:closeAll()

    -- on a book in a series too: "More in <series>" first, then "Similar to", both paging
    -- and both opening their own books
    fixtures.similar_ids = { 9, 4, 7, 2, 1, 3, 5, 6 }
    details = manager:showBookDetail(103, 10301)
    emu:pump()
    assert(details.similar_carousel and details.carousel, "both strips are not there")
    emu:shot("similar_with_series")
    details.scroll:scrollToRatio(0, 1)
    emu:shot("similar_with_series_end")
    for _, expected in ipairs({ "Similar to The Left Hand of Darkness", "8 books", "More in Hainish Cycle" }) do
      emu:expectText(expected)
    end
    -- a swipe along a strip turns its page (like the arrows); a vertical swipe scrolls the page
    local function swipe(strip, direction)
      local d = strip.holder.dimen
      local Time = require("ui/time")
      local gesture = { ges = "swipe", direction = direction, time = Time.now(),
        pos = require("ui/geometry"):new { x = d.x + math.floor(d.w / 2), y = d.y + math.floor(d.h / 2), w = 0, h = 0 } }
      local consumed = top():handleEvent(emu.Event:new("Gesture", gesture))
      emu:pump()
      return consumed
    end
    local s_first, r_first = details.similar_carousel.first, details.carousel.first
    assert(swipe(details.similar_carousel, "west"), "a swipe on the similar strip was not handled")
    assert(details.similar_carousel.first > s_first, "swiping left did not turn the similar strip")
    assert(details.carousel.first == r_first, "swiping the similar strip turned the series strip")
    assert(swipe(details.carousel, "west"), "a swipe on the series strip was not handled")
    assert(details.carousel.first > r_first, "swiping left did not turn the series strip")
    local advanced = details.carousel.first
    swipe(details.carousel, "east")
    assert(details.carousel.first < advanced, "swiping right did not turn the series strip back")
    details.carousel.first = r_first
    details.carousel:render()
    assert(swipe(details.similar_carousel, "east"))
    assert(details.similar_carousel.first == s_first, "swiping right did not turn back")
    swipe(details.similar_carousel, "east") -- already at the start: nothing happens, nothing breaks
    assert(details.similar_carousel.first == s_first)
    local before = details.scroll:getScrolledOffset()
    swipe(details.similar_carousel, "south")
    assert(details.similar_carousel.first == s_first, "a vertical swipe turned the strip")
    assert(details.scroll:getScrolledOffset().y ~= before.y, "a vertical swipe on the strip did not scroll the page")
    details.scroll:scrollToRatio(0, 1)
    emu:pump()

    local sim_first = details.similar_carousel.first
    local ser_first = details.carousel.first
    local function centre(w) return w.dimen.x + math.floor(w.dimen.w / 2), w.dimen.y + math.floor(w.dimen.h / 2) end
    emu:tap(centre(details.similar_carousel.next))
    emu:pump()
    assert(details.similar_carousel.first > sim_first, "the similar strip did not turn")
    assert(details.carousel.first == ser_first, "turning the similar strip turned the series strip")
    emu:tap(centre(details.carousel.next))
    emu:pump()
    assert(details.carousel.first > ser_first, "the series strip did not turn")
    -- a similar cover opens a similar book, a series cover opens a series book
    emu:tap(centre(details.similar_carousel.targets[1]))
    emu:pump()
    local first_open = top()
    assert(first_open ~= details and first_open.name == "hardcover_book_detail", "a similar cover did not open")
    UIManager:close(first_open)
    emu:pump()
    emu:tap(centre(details.carousel.targets[1]))
    emu:pump()
    assert(top() ~= details and top().name == "hardcover_book_detail", "a series cover did not open")
    emu:closeAll()

    -- no ranking: no strip. A failed answer: the placeholder stays while it is tried again
    -- (it goes, with a message, when the tries run out: see the retries below)
    for _, mode in ipairs({ "empty", "failed" }) do
      fixtures.similar_ids = mode == "empty" and {} or { 9 }
      fixtures.similar_fail = mode == "failed" or nil
      details = manager:showBookDetail(book_id)
      emu:pump()
      if mode == "empty" then
        assert(details.similar_carousel == nil and details.similar_card == nil, "a strip with no ranking")
      else
        assert(details.similar_card and details.similar_card.loading, "no placeholder while retrying")
      end
      emu:expectText("The Lathe of Heaven")
      if mode == "failed" then emu:shot("similar_none") end
      emu:closeAll()
    end
    fixtures.similar_fail = nil

    -- a request that fails is tried again, twice; if it keeps failing the reader is told
    -- (the 2-second waits are skipped here)
    local schedule = UIManager.scheduleIn
    UIManager.scheduleIn = function(self, delay, fn, ...) if delay == 2 then fn() else schedule(self, delay, fn, ...) end end
    fixtures.similar_ids = { 9, 4 }
    for _, case in ipairs({ { "error", 3 }, { "cancelled", 8 } }) do
      local mode, want = case[1], case[2]
      fixtures.similar_fail = mode == "error" and "error" or true
      local asked = calls_named("getSimilarBooks")
      details = manager:showBookDetail(book_id)
      for _ = 1, 30 do emu:pump() end
      assert(calls_named("getSimilarBooks") - asked == want, mode .. " tries: " .. (calls_named("getSimilarBooks") - asked))
      emu:expectText("Couldn't load similar books.")
      assert(details.similar_card == nil)
      emu:closeAll()
    end
    fixtures.similar_fail = nil
    UIManager.scheduleIn = schedule

    -- the strip is there at once, empty and saying it is loading, then filled in place; with no
    -- ranking (or after failing) the placeholder goes away
    local Api = require("hardcover/lib/hardcover_api")
    local held
    local real_async = Api.getSimilarBooksAsync
    Api.getSimilarBooksAsync = function(_, _, _, _, callback) held = callback end -- (book, limit, user, callback)
    fixtures.similar_ids = { 9, 4, 7, 2 }
    details = manager:showBookDetail(book_id)
    emu:pump()
    assert(held, "the ranking was not asked for")
    assert(details.similar_carousel and details.similar_card.loading, "no placeholder while loading")
    emu:expectText("Similar to The Lathe of Heaven")
    emu:expectText("Loading")
    assert(#details.similar_carousel.targets == 0, "an empty cover can be tapped")
    emu:shot("similar_loading")
    local entries = {}
    for _, idx in ipairs(fixtures.similar_ids) do
      local e = require("hardcover/lib/shelf").normalizeEntry({ book = fixtures.shelf_books[idx] })
      e.user_book_id = nil
      entries[#entries + 1] = e
    end
    held(entries)
    emu:pump()
    assert(details.similar_card and not details.similar_card.loading and #details.similar_carousel.targets == 4,
      "the books did not replace the placeholder")
    emu:closeAll()
    -- no ranking: the placeholder goes
    details = manager:showBookDetail(book_id)
    emu:pump()
    held({})
    emu:pump()
    assert(details.similar_card == nil and details.similar_carousel == nil, "the placeholder stayed with no ranking")
    emu:closeAll()
    Api.getSimilarBooksAsync = real_async

    -- offline: no request
    local NetworkManager = require("ui/network/manager")
    local was, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end
    local before = calls_named("getSimilarBooks")
    local cleared
    manager:loadSimilar({ setSimilar = function() cleared = true end }, book_id)
    assert(cleared, "the placeholder stayed after the connection dropped")
    NetworkManager.isConnected, NetworkManager.getConnectionState = was, was_state
    assert(calls_named("getSimilarBooks") == before, "asked for similar books while offline")
    emu:closeAll()
  end,
}
