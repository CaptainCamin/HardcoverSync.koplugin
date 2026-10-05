local SETTING = require("hardcover/lib/constants/settings")

local Device = require("device")
local logger = require("logger")

local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

-- How long wifi that this plugin switched on stays up after its work started. The work
-- (a sync, a screen's requests) runs asynchronously after the callback, and switching wifi off
-- the moment the callback returns cut those requests off.
local DISABLE_DELAY = 15

local AutoWifi = {
  connection_pending = false
}
AutoWifi.__index = AutoWifi

function AutoWifi:new(o)
  return setmetatable(o, self)
end

-- Ensure wifi is up, then run the callback.
--
-- As with wifiPrompt, the callback is what opens the dialog, so every branch
-- must reach it. The restore-wifi branch below used to call back only from a
-- connectivity check that may never fire, and simply returned when the device
-- could not restore wifi, when a connection was already pending, or when
-- ENABLE_WIFI was off. In all of those the tapped menu item did nothing at all.
function AutoWifi:withWifi(callback)
  -- more work is starting: wifi we were about to switch off is wanted again
  self:cancelScheduledDisable()

  if NetworkMgr:isWifiOn() then
    callback(false)
    return
  end

  if self.settings:readSetting(SETTING.ENABLE_WIFI)
      and not NetworkMgr.pending_connection
      and Device:hasWifiRestore()
      and G_reader_settings:nilOrFalse("airplanemode") then
    --logger.warn("HARDCOVER enabling wifi")

    local original_on = NetworkMgr.wifi_was_on

    NetworkMgr:restoreWifiAsync()
    NetworkMgr:scheduleConnectivityCheck(function()
      -- restore original "was on" state to prevent wifi being restored automatically after suspend
      NetworkMgr.wifi_was_on = original_on
      G_reader_settings:saveSetting("wifi_was_on", original_on)

      self.connection_pending = false
      --logger.warn("HARDCOVER wifi enabled")

      callback(true)

      -- switched off a while later (not now: the work the callback started is still running),
      -- and not at all if more work asks for wifi meanwhile
      self:scheduleDisable()
    end)

    return
  end

  -- None of the conditions for silently restoring wifi held. Fall through to a
  -- prompt so the user can decide, rather than returning with the dialog
  -- unopened.
  self:wifiPrompt(callback)
end

function AutoWifi:scheduleDisable()
  self:cancelScheduledDisable()
  self.disable_task = function()
    self.disable_task = nil
    self:wifiDisableSilent()
  end
  UIManager:scheduleIn(DISABLE_DELAY, self.disable_task)
end

function AutoWifi:cancelScheduledDisable()
  if self.disable_task then
    UIManager:unschedule(self.disable_task)
    self.disable_task = nil
  end
end

function AutoWifi:wifiDisableSilent()
  NetworkMgr:turnOffWifi(function()
    -- explicitly disable wifi was on
    NetworkMgr.wifi_was_on = false
    G_reader_settings:saveSetting("wifi_was_on", false)
    --logger.warn("HARDCOVER disabling wifi")
  end)
end

-- Prompt to bring wifi up, then run the callback.
--
-- The callback is the only thing that actually opens the dialog the user tapped,
-- so it MUST run on every path. Returning without calling it means the menu item
-- appears dead: the user taps it, nothing happens, and on e-ink the screen just
-- sits there looking stale until something forces a repaint. That is what made
-- this look like a missing-refresh bug rather than a callback that never ran.
function AutoWifi:wifiPrompt(callback)
  if NetworkMgr:isWifiOn() then
    if callback then
      callback(false)
    end

    return
  end

  -- Airplane mode: wifi cannot be turned on without the user choosing to, so
  -- there is nothing to prompt for. Run the callback anyway -- the dialog is
  -- still worth showing, and it can report that it is offline rather than the
  -- menu item looking broken.
  if G_reader_settings:isTrue("airplanemode") then
    if callback then
      callback(false)
    end

    return
  end

  local network_callback = callback and function() callback(true) end or nil

  if self.settings:readSetting(SETTING.ENABLE_WIFI) then
    NetworkMgr:turnOnWifiAndWaitForConnection(network_callback)
  else
    NetworkMgr:promptWifiOn(network_callback)
  end
end

function AutoWifi:wifiDisablePrompt()
  if self.settings:readSetting(SETTING.ENABLE_WIFI) and Device:hasWifiRestore() then
    self:wifiDisableSilent()
  else
    NetworkMgr:toggleWifiOff()
  end
end

return AutoWifi
