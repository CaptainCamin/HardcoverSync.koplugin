--[[--
"Readers also liked" on a book's details: a strip of covers (Hardcover's ranking, in its
order) that arrives after the screen is up, a tap opening that book, a book with no
ranking or a failed answer showing nothing (the screen carries on), and the offline
case (no request at all).

Screens: similar_strip, similar_none, similar_offline.
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
    for _, expected in ipairs({ "Readers also liked", "4 books" }) do emu:expectText(expected) end
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
