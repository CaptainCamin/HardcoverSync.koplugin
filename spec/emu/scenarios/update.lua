--[[--
Updates, from the settings screen: "Check for updates" asks GitHub, says when a
newer release exists (with its notes), and the row remembers it afterwards.
GitHub is stubbed here; the install itself is covered by spec/updater_harness.lua.
]]

local fixtures = require("fixtures")

return {
  name = "update",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })

    local Github = require("hardcover/lib/github")
    local answer
    Github.latestReleaseAsync = function(_, cb) cb(answer) end

    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
    local menu = HardcoverMenu:new({
      settings = settings,
      enabled = true,
      sync_queue = { pendingCount = function() return 0 end, hasPending = function() return false end },
      auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
               statusText = function() return "Signed in" end },
    })
    local function find(text_prefix)
      for _, item in ipairs(menu:getHomeSettingsItems()) do
        local text = item.text or (item.text_func and item.text_func())
        if text and text:find(text_prefix, 1, true) == 1 then return item, text end
      end
    end

    local item = assert(find("Check for updates"), "no update row")
    assert(find("Check for updates automatically"), "no automatic-check tick")

    answer = nil
    item.callback({ updateItems = function() end })
    emu:pump()
    emu:expectText("Couldn't reach GitHub")
    emu:closeAll()

    answer = { tag = "v99.0.0", version = "99.0.0", notes = "Everything is better.", zip_url = "https://example/x.zip" }
    item.callback({ updateItems = function() end })
    emu:pump()
    emu:expectText("Version 99.0.0 is available")
    emu:expectText("Everything is better.")
    emu:shot("update")
    emu:closeAll()

    local _, text = find("Update available")
    assert(text == "Update available: v99.0.0", tostring(text))

    answer = { tag = "v0.0.1" }
    find("Update available").callback({ updateItems = function() end })
    emu:pump()
    emu:expectText("is up to date")
    emu:closeAll()
    assert(find("Check for updates"), "the row did not go back after an up-to-date answer")
  end,
}
