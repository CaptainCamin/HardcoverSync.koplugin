-- Status changes made offline say they are kept until the connection returns.

return {
  name = "status_feedback",

  run = function(emu)
    local NetworkManager = require("ui/network/manager")
    local was_connected = NetworkManager.isConnected
    NetworkManager.isConnected = function() return false end

    local App = require("main")
    local app = setmetatable({}, { __index = App })
    app.markFinished = function() return true end
    assert(app:markFinishedAndSay("/book.epub", "end_chosen"))

    emu:pump()
    emu:expectText("You're offline. Your status is kept and will be sent when you're connected.")
    emu:shot("status_offline_feedback")

    NetworkManager.isConnected = was_connected
    emu:closeAll()
  end,
}
