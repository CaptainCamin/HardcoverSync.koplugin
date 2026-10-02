-- One answer to "are we online?" for the screens and the API.
--
-- Run with:  lua spec/network_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local results = { passed = 0, failed = 0 }
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then results.passed = results.passed + 1 print("  [ok  ] " .. name)
  else results.failed = results.failed + 1 print("  [FAIL] " .. name .. "\n         " .. tostring(err)) end
end
local function eq(a, b, label)
  if a ~= b then error((label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local nm
-- require caches the first table it gets, so hand out one that looks at the
-- current stub
package.preload["ui/network/manager"] = function()
  return setmetatable({}, { __index = function(_, k) return nm[k] end })
end
local Network = require("hardcover/lib/network")

print("\n== online check ==")

check("a live yes is a yes", function()
  nm = { isConnected = function() return true end }
  eq(Network.connected(), true)
end)

check("a live no with nothing else to go on is a no", function()
  nm = { isConnected = function() return false end }
  eq(Network.connected(), false)
end)

check("a live no while KOReader's own record says wifi is on and joined is a yes", function()
  -- right after wake, the device check lags behind
  nm = { isConnected = function() return false end,
    getConnectionState = function() return true end, getWifiState = function() return true end }
  eq(Network.connected(), true)
end)

check("wifi switched off is offline whatever the record says", function()
  nm = { isConnected = function() return false end,
    getConnectionState = function() return true end, getWifiState = function() return false end }
  eq(Network.connected(), false)
end)

check("not joined is offline", function()
  nm = { isConnected = function() return false end,
    getConnectionState = function() return false end, getWifiState = function() return true end }
  eq(Network.connected(), false)
end)

print("")
print(string.format("  %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
