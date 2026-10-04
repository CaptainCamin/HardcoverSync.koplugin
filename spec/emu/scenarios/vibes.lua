--[[--
Vibes, from Home: the tile, the index (Hardcover's own, then yours, each with covers), a
vibe opening in the shelf screen in its ranking, a sign-in without the permission getting
the way to fix it, and the failed and offline cases.

Screens: vibes, vibes_list, vibes_scope.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

local function top() return UIManager:getTopmostVisibleWidget() end

return {
  name = "vibes",

  run = function(emu)
    local SETTING = require("hardcover/lib/constants/settings")
    local settings = fixtures.real_settings(emu)
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    settings:updateSetting(SETTING.SHOW_FOR_YOU, true)
    for _, b in ipairs(fixtures.shelf_books) do
      local image = b.cached_image
      if image and image.url then fixtures.seed_cover(image.url, b.book_id % 3 + 1) end
    end
    fixtures.install({ settings = settings })
    fixtures.vibes_rows = {
      { id = 1342, title = "Top Picks", vibe_type = 3, privacy_setting_id = 3, cached_book_ids = { 9, 4, 7, 2, 1, 3 } },
      { id = 1343, title = "Recommendations", vibe_type = 1, privacy_setting_id = 3, cached_book_ids = { 5, 6, 8 } },
      { id = 1340, title = "For Red Rising Withdrawl", vibe_type = 0, privacy_setting_id = 3, cached_book_ids = { 10, 11 } },
    }

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings }

    -- the tile on Home
    manager:showHome()
    emu:pump()
    local tile
    for _, t in ipairs(manager.home_dialog.tiles) do if t.key == "vibes" then tile = t.tile end end
    assert(tile, "no Vibes tile on Home")
    emu:closeAll()

    -- the index
    manager:showVibes()
    for _ = 1, 5 do emu:pump() end
    for _, expected in ipairs({ "Vibes", "From Hardcover", "Top Picks", "6 books \194\183 ranked \194\183 by Hardcover",
      "Recommendations", "Made by you", "For Red Rising Withdrawl", "2 books \194\183 ranked \194\183 private" }) do
      emu:expectText(expected)
    end
    emu:shot("vibes")

    -- a vibe opens in its ranking
    manager:showVibe(manager.vibes_dialog and require("hardcover/lib/vibes").normalize(fixtures.vibes_rows)[1])
    for _ = 1, 5 do emu:pump() end
    local list = top()
    assert(list and list.entries and #list.entries == 6, "the vibe did not open: " .. tostring(list and list.name))
    assert(list.title == "Top Picks")
    for i, idx in ipairs({ 9, 4, 7, 2, 1, 3 }) do
      assert(list.entries[i].book_id == fixtures.shelf_books[idx].book_id, "book " .. i .. " is not in the vibe's order")
    end
    emu:expectText("Hyperion")
    emu:shot("vibes_list")
    emu:closeAll()

    -- a sign-in without the permission is told how to fix it, and nothing is asked
    fixtures.vibes_scope_error = true
    manager:showVibes()
    for _ = 1, 5 do emu:pump() end
    emu:expectText("Sign out and back in")
    emu:shot("vibes_scope")
    emu:closeAll()
    fixtures.vibes_scope_error = nil

    -- none yet
    local saved = fixtures.vibes_rows
    fixtures.vibes_rows = {}
    manager:showVibes()
    for _ = 1, 5 do emu:pump() end
    emu:expectText("No vibes yet")
    emu:closeAll()
    fixtures.vibes_rows = saved

    -- offline: a message and no request
    local NetworkManager = require("ui/network/manager")
    local was, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end
    local asked = 0
    for _, c in ipairs(fixtures.calls) do if c.name == "getVibes" then asked = asked + 1 end end
    manager:showVibes()
    emu:pump()
    NetworkManager.isConnected, NetworkManager.getConnectionState = was, was_state
    emu:expectText("internet connection")
    local now = 0
    for _, c in ipairs(fixtures.calls) do if c.name == "getVibes" then now = now + 1 end end
    assert(now == asked, "asked for vibes while offline")
    emu:closeAll()
  end,
}
