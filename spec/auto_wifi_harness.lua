-- AutoWifi: wifi the plugin switched on is switched off later, not the moment its work starts,
-- and not at all when more work asks for it meanwhile.
--
-- Run with:  lua spec/auto_wifi_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local net = { wifi_on = false, off_calls = 0 }
local scheduled = {}
local now = 0

package.preload["device"] = function() return { hasWifiRestore = function() return true end } end
package.preload["logger"] = function() return { dbg = function() end, info = function() end, warn = function() end, err = function() end } end
package.preload["ui/network/manager"] = function()
  return {
    isWifiOn = function() return net.wifi_on end,
    pending_connection = false,
    restoreWifiAsync = function() end,
    scheduleConnectivityCheck = function(_, cb) cb() end,
    turnOffWifi = function(_, cb) net.off_calls = net.off_calls + 1; net.wifi_on = false; if cb then cb() end end,
  }
end
package.preload["ui/uimanager"] = function()
  return {
    scheduleIn = function(_, delay, fn) scheduled[#scheduled + 1] = { at = now + delay, fn = fn } end,
    unschedule = function(_, fn)
      for i = #scheduled, 1, -1 do if scheduled[i].fn == fn then table.remove(scheduled, i) end end
    end,
  }
end
_G.G_reader_settings = {
  isTrue = function() return false end, nilOrFalse = function() return true end,
  saveSetting = function() end, readSetting = function() return nil end,
}

local AutoWifi = require("hardcover/lib/auto_wifi")
local function advance(seconds)
  now = now + seconds
  for i = #scheduled, 1, -1 do
    if scheduled[i] and scheduled[i].at <= now then local t = table.remove(scheduled, i); t.fn() end
  end
end
local function fresh()
  net = { wifi_on = false, off_calls = 0 }
  scheduled, now = {}, 0
  return AutoWifi:new { settings = { readSetting = function() return true end } } -- ENABLE_WIFI on
end

check("wifi switched on for the work is not switched off while that work starts", function()
  local wifi = fresh()
  local called
  wifi:withWifi(function(enabled) called = enabled end)
  assert(called == true, "the callback did not run")
  assert(net.off_calls == 0, "wifi was cut the moment the callback returned")
  assert(#scheduled == 1, "no switch-off was scheduled")
end)

check("it is switched off after the delay", function()
  local wifi = fresh()
  wifi:withWifi(function() end)
  advance(5)
  assert(net.off_calls == 0, "switched off too early")
  advance(20)
  assert(net.off_calls == 1, "never switched off")
end)

check("more work asking for wifi meanwhile cancels the switch-off", function()
  local wifi = fresh()
  wifi:withWifi(function() end)
  net.wifi_on = true -- it is up now
  local ran
  wifi:withWifi(function(enabled) ran = enabled end)
  assert(ran == false, "wifi was already on")
  advance(60)
  assert(net.off_calls == 0, "wifi was cut under the second piece of work")
end)

check("wifi that was already on is never scheduled off", function()
  local wifi = fresh()
  net.wifi_on = true
  wifi:withWifi(function() end)
  assert(#scheduled == 0 and net.off_calls == 0)
end)

r.finish()
