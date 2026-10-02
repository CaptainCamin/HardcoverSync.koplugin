-- Proves a menu item always reaches its dialog.
--
-- The bug this pins: every dialog-opening item in the plugin menu ran its
-- show inside an AutoWifi callback. AutoWifi has paths that never invoke that
-- callback -- airplane mode returns immediately, and withWifi's
-- restore-wifi branch only calls back from a connectivity check that may never
-- fire. On those paths the dialog is never shown at all: the user taps the
-- menu item and nothing happens.
--
-- On e-ink that reads as "the screen never updates". A power cycle rebuilds
-- the UI from scratch, which is why the correct screen could appear afterwards
-- and made this look like a repaint problem rather than a callback that never
-- ran.
--
-- Run with:  lua spec/menu_wiring_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local results = { passed = 0, failed = 0 }

local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    results.passed = results.passed + 1
    print("  [ok  ] " .. name)
  else
    results.failed = results.failed + 1
    print("  [FAIL] " .. name .. "\n         " .. tostring(err))
  end
end

-- ---------------------------------------------------------------- AutoWifi

-- The conditions each test wants to simulate. NetworkMgr and G_reader_settings
-- are read through these.
local net = { wifi_on = true, airplane = false, pending = false }
local wifi_restorable = true

package.preload["device"] = function()
  return {
    screen = {
      scaleBySize = function(_, n) return n end,
      getWidth = function() return 1080 end,
      getHeight = function() return 1440 end,
      getSize = function() return { x = 0, y = 0, w = 1080, h = 1440 } end,
    },
    hasWifiRestore = function() return wifi_restorable end,
  }
end

package.preload["ui/network/manager"] = function()
  return {
    isWifiOn = function() return net.wifi_on end,
    isConnected = function() return net.wifi_on end,
    isOnline = function() return net.wifi_on end,
    pending_connection = net.pending,
    runWhenOnline = function(_, fn) fn() end,
    promptWifiOn = function(_, cb) if cb then cb() end end,
    turnOnWifiAndWaitForConnection = function(_, cb) if cb then cb() end end,
    toggleWifiOff = function() end,
    turnOffWifi = function(_, cb) if cb then cb() end end,
    restoreWifiAsync = function() end,
    scheduleConnectivityCheck = function(_, cb) if cb then cb() end end,
  }
end

package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end

_G.G_reader_settings = {
  isTrue = function(_, key) return key == "airplanemode" and net.airplane or false end,
  nilOrFalse = function(_, key) return not (key == "airplanemode" and net.airplane) end,
  saveSetting = function() end,
  readSetting = function() return nil end,
}

local AutoWifi = require("hardcover/lib/auto_wifi")

local function newWifi()
  return AutoWifi:new {
    settings = {
      readSetting = function() return false end,   -- ENABLE_WIFI off
    },
  }
end

-- Run wifiPrompt and report whether the callback was reached.
local function promptFires(wifi)
  local fired = false
  wifi:wifiPrompt(function() fired = true end)
  return fired
end

print("\n== a wifi prompt must always reach its callback ==")

check("the callback runs when wifi is already on", function()
  net = { wifi_on = true, airplane = false, pending = false }
  if not promptFires(newWifi()) then
    error("callback did not run with wifi on")
  end
end)

check("the callback runs in airplane mode", function()
  -- This is the silent no-op. Airplane mode means wifi is off and cannot be
  -- turned on without the user choosing to, so the plugin must still show its
  -- dialog -- the user can then decide what to do about the connection.
  net = { wifi_on = false, airplane = true, pending = false }
  if not promptFires(newWifi()) then
    error("callback never ran in airplane mode, so the dialog would never open")
  end
end)

check("withWifi reaches its callback in airplane mode too", function()
  net = { wifi_on = false, airplane = true, pending = false }
  local fired = false
  newWifi():withWifi(function() fired = true end)
  if not fired then
    error("withWifi's callback never ran in airplane mode")
  end
end)

check("withWifi reaches its callback when a connection is pending", function()
  -- pending_connection means a join is in flight. Waiting for it is reasonable;
  -- never calling back is not.
  net = { wifi_on = false, airplane = false, pending = true }
  local fired = false
  newWifi():withWifi(function() fired = true end)
  if not fired then
    error("withWifi's callback never ran while a connection was pending")
  end
end)

check("withWifi reaches its callback when the device cannot restore wifi", function()
  net = { wifi_on = false, airplane = false, pending = false }
  wifi_restorable = false
  local fired = false
  newWifi():withWifi(function() fired = true end)
  wifi_restorable = true
  if not fired then
    error("withWifi's callback never ran on a device with no wifi restore")
  end
end)

-- ---------------------------------------------------------------- menu wiring

print("\n== menu items show their dialog unconditionally ==")

-- Read the menu source and assert that no dialog-opening item hides its show
-- behind a deferred callback. This is a source-level check on purpose: the
-- failure mode is a control-flow shape, and a behavioural test would have to
-- fake enough of UIManager to prove it, at which point it is testing the fake.
local f = assert(io.open(PLUGIN .. "/hardcover/lib/ui/hardcover_menu.lua", "r"))
local src = f:read("*a")
f:close()

check("no menu item defers its dialog behind a wifi prompt", function()
  -- A dialog shown from inside an AutoWifi callback is a dialog that may never
  -- appear. Compare zlibrary.koplugin, which shows every dialog directly in the
  -- menu callback.
  -- Only menu-item callbacks matter. withWifiThen deliberately prompts for wifi
  -- after running the action, so a wifiPrompt inside that helper is correct and
  -- must not be flagged.
  -- Ignore the withWifiThen helper's own body: prompting there is the point.
  local body = src:match("function HardcoverMenu:withWifiThen.-\nend\n")
  if not body then
    error("could not find withWifiThen -- the guard needs updating if it was renamed")
  end
  local menu_only = src:gsub(body:gsub("([^%w])", "%%%1"), "")

  local offenders = {}
  local line_no = 0
  for line in (menu_only .. "\n"):gmatch("([^\n]*)\n") do
    line_no = line_no + 1
    if line:match("self%.wifi:wifiPrompt") then
      offenders[#offenders + 1] = line_no
    end
  end
  if #offenders > 0 then
    error("deferred dialog launch at line(s) " .. table.concat(offenders, ", "))
  end
end)

check("the shelves are still reachable, through the Home entry", function()
  -- A guard against "fixing" the wiring by deleting the feature. The two shelf
  -- items moved into the home screen on purpose, so what must still hold is
  -- that the menu opens Home, and that Home opens a shelf.
  if not src:find('text = _("Home")', 1, true) then
    error("the Home menu entry has disappeared")
  end
  if not src:find("showHome", 1, true) then
    error("the Home entry no longer opens the home screen")
  end
  local dm = assert(io.open(PLUGIN .. "/hardcover/lib/ui/dialog_manager.lua", "r")):read("*a")
  if not dm:find("self:showShelf(row.status_id", 1, true) then
    error("the home screen no longer opens a shelf")
  end
end)

print("")
print(string.format("  %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)