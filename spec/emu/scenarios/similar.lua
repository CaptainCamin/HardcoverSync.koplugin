--[[--
"Similar to <title>" on a book's details: a strip of covers (Hardcover's ranking, in its
order) that arrives after the screen is up, a tap opening that book, a book with no
ranking or a failed answer showing nothing (the screen carries on), and the offline
case (no request at all).

Screens: similar_strip, similar_none, similar_with_series, similar_with_series_end.
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

    -- no ranking, or a failed answer: no strip, and nothing in its place
    for _, mode in ipairs({ "empty", "failed" }) do
      fixtures.similar_ids = mode == "empty" and {} or { 9 }
      fixtures.similar_fail = mode == "failed" or nil
      details = manager:showBookDetail(book_id)
      emu:pump()
      assert(details.similar_carousel == nil and details.similar_card == nil, "a strip with " .. mode)
      emu:expectText("The Lathe of Heaven")
      if mode == "failed" then emu:shot("similar_none") end
      emu:closeAll()
    end
    fixtures.similar_fail = nil

    -- a request that fails is tried again, twice; if it keeps failing the reader is told
    -- (the 2-second waits are skipped here)
    local schedule = UIManager.scheduleIn
    UIManager.scheduleIn = function(self, delay, fn, ...) if delay == 2 then fn() else schedule(self, delay, fn, ...) end end
    fixtures.similar_fail = true
    fixtures.similar_ids = { 9, 4 }
    details = manager:showBookDetail(book_id)
    emu:pump()
    local asked = calls_named("getSimilarBooks")
    manager:loadSimilar(details, book_id)
    emu:pump()
    assert(calls_named("getSimilarBooks") - asked == 3, "tries: " .. (calls_named("getSimilarBooks") - asked))
    emu:expectText("Couldn't load similar books.")
    assert(details.similar_card == nil)
    -- failing once and then answering: the strip arrives
    fixtures.similar_fail = nil
    emu:closeAll()
    UIManager.scheduleIn = schedule

    -- offline: no request
    local NetworkManager = require("ui/network/manager")
    local was, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end
    local before = calls_named("getSimilarBooks")
    manager:loadSimilar({}, book_id)
    NetworkManager.isConnected, NetworkManager.getConnectionState = was, was_state
    assert(calls_named("getSimilarBooks") == before, "asked for similar books while offline")
    emu:closeAll()
  end,
}
