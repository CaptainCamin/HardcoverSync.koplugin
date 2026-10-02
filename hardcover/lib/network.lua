-- Are we online? One answer for the screens and the API, so they cannot disagree.
--
-- NetworkManager:isConnected() asks the device afresh each time, and on some
-- e-readers it says "no" for a moment even with wifi on and joined: right after
-- the device wakes, or while the connection settles. A screen that believed it
-- showed "Offline" at once, and the API refused to send anything. KOReader also
-- keeps what it last learned about the connection (it is told when wifi comes
-- up and goes down); when the live check says no but that record says wifi is on
-- and connected, trust the record. If it is wrong the request simply fails and
-- the screen falls back to its saved copy, which is what offline would have done.

local Network = {}

function Network.connected()
  local NetworkManager = require("ui/network/manager")
  if NetworkManager:isConnected() then
    return true
  end

  local joined = type(NetworkManager.getConnectionState) == "function" and NetworkManager:getConnectionState()
  local wifi_on = type(NetworkManager.getWifiState) ~= "function" or NetworkManager:getWifiState()
  if joined and wifi_on then
    return true
  end
  return false
end

return Network
