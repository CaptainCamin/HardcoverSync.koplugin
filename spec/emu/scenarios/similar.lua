--[[--
Books like this, from a book's details screen: the Similar button, the shelf screen it
opens (in Hardcover's ranking, not the shelf's order), a book on it opening its details,
a book with no ranking, a failed answer and the offline case (no request at all).

Screens: similar_button, similar_list, similar_empty, similar_offline.
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

    -- the details of a book have the button
    local book_id = fixtures.shelf_books[1].book_id
    local details = manager:showBookDetail(book_id)
    emu:pump()
    assert(details and details.similar_button, "the details have no Similar button")
    emu:expectText("Similar")
    emu:shot("similar_button")

    -- tapping it opens the ranking, in the ranking's order
    tap_widget(emu, details.similar_button)
    local list = top()
    assert(list and list.entries and #list.entries == 4, "the similar books did not open: " .. tostring(list and list.name))
    assert(list.title:find(fixtures.shelf_books[1].title, 1, true), "the title does not say which book: " .. tostring(list.title))
    for i, idx in ipairs(fixtures.similar_ids) do
      assert(list.entries[i].book_id == fixtures.shelf_books[idx].book_id, "row " .. i .. " is not in ranking order")
    end
    emu:expectText("Hyperion")
    emu:shot("similar_list")
    assert(calls_named("getSimilarBooks") == 1, "requests: " .. calls_named("getSimilarBooks"))

    -- a book on it opens its details; closing comes back to the list
    local hyperion = emu:expectText("Hyperion")
    emu:tapExpecting(hyperion.x + 5, hyperion.y + 5)
    emu:pump()
    local opened = top()
    assert(opened and opened.name == "hardcover_book_detail" and opened ~= details, "a similar book did not open its details")
    UIManager:close(opened)
    emu:pump()
    assert(top() == list, "closing the details did not come back to the list")
    list:onClose()
    emu:pump()
    assert(top() == details, "closing the list did not come back to the details")

    -- a book with no ranking says so
    fixtures.similar_ids = {}
    tap_widget(emu, details.similar_button)
    emu:expectText("no similar books")
    emu:shot("similar_empty")
    top():onClose()
    emu:pump()

    -- a failed answer offers a retry instead of a dead end
    fixtures.similar_fail = true
    tap_widget(emu, details.similar_button)
    emu:expectText("Retry")
    fixtures.similar_fail = nil
    fixtures.similar_ids = { 9 }
    local retry = emu:expectText("Retry")
    emu:tapExpecting(retry.x + 5, retry.y + 5)
    emu:pump()
    emu:expectText("Hyperion")
    top():onClose()
    emu:pump()

    -- offline: a message and no request
    local NetworkManager = require("ui/network/manager")
    local was, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end
    local before = calls_named("getSimilarBooks")
    manager:showSimilar(book_id, details.detail)
    emu:pump()
    NetworkManager.isConnected, NetworkManager.getConnectionState = was, was_state
    emu:expectText("internet connection")
    assert(calls_named("getSimilarBooks") == before, "asked for similar books while offline")
    emu:shot("similar_offline")
    emu:closeAll()
  end,
}
