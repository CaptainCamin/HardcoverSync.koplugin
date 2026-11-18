--[[--
The two last-page switches in Settings (issue #317): "Ask to mark as Read" and "Mark as Read
automatically" are mutually exclusive -- turning one on turns the other off, and they never
show on together.

Screens: settings_last_page_auto, settings_last_page_ask.
]]

local fixtures = require("fixtures")
local Device = require("device")

local ASK = "Ask to mark as Read on the last page"
local AUTO = "Mark as Read automatically on the last page"

return {
  name = "settings_last_page",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    local SETTING = require("hardcover/lib/constants/settings")
    -- the settings file outlives a run: start from the untouched defaults, and leave them so
    settings:updateSetting(SETTING.END_PROMPT, nil)
    settings:updateSetting(SETTING.END_AUTO_MARK, nil)
    fixtures.install({ settings = settings })

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings }
    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
    local menu = HardcoverMenu:new({
      settings = settings,
      enabled = true,
      dialog_manager = manager,
      sync_queue = { pendingCount = function() return 0 end, changeCount = function() return 0 end,
        hasPending = function() return false end },
      auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
        statusText = function() return "Signed in" end },
    })
    manager.settings_items = function() return menu:getHomeSettingsItems() end

    local screen = manager:showSettings()
    emu:pump()

    -- the switch state as the row shows it: "text|checked|dim"
    local function state_of(text)
      for _, t in ipairs(screen.taps) do
        if t.shows:sub(1, #text + 1) == text .. "|" then
          return t.shows:sub(#text + 2):match("^[^|]*") == "true"
        end
      end
      error("no settings row for " .. text)
    end

    local function tap_row(text)
      local W, H = Device.screen:getWidth(), Device.screen:getHeight()
      for _ = 1, 30 do
        emu:screenNodes()
        for _, t in ipairs(screen.taps) do
          if t.shows:sub(1, #text + 1) == text .. "|" then
            local d = t.tap.dimen
            if d and d.x and d.y >= 0 and d.y + d.h <= H then
              emu:tapExpecting(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
              emu:pump()
              return
            end
          end
        end
        emu:tap(W - 10, H - 20) -- the scroll control's down triangle
        emu:pump()
      end
      error("never brought the row on screen: " .. text)
    end

    -- left alone: the question is on (KOReader's own end action), automatic off
    assert(state_of(ASK) == true and state_of(AUTO) == false, "the defaults are not ask-on, auto-off")

    tap_row(AUTO)
    assert(state_of(AUTO) == true and state_of(ASK) == false, "both last-page switches show on")
    emu:shot("settings_last_page_auto")

    tap_row(ASK)
    assert(state_of(ASK) == true and state_of(AUTO) == false, "the question did not turn automatic off")
    emu:shot("settings_last_page_ask")

    tap_row(ASK)
    assert(state_of(ASK) == false and state_of(AUTO) == false, "turning the question off left automatic on")
    settings:updateSetting(SETTING.END_PROMPT, nil)
    settings:updateSetting(SETTING.END_AUTO_MARK, nil)
    emu:closeAll()
  end,
}
