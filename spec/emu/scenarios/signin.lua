--[[--
The sign-in screen (OAuth device flow): the short code and where to enter it.

Shown with a made-up code and without polling, so nothing is sent to Hardcover.
A real tap on Cancel closes it.
]]

local UIManager = require("ui/uimanager")

return {
  name = "signin",

  run = function(emu)
    local SignInDialog = require("hardcover/lib/ui/signin_dialog")
    local dialog = SignInDialog:new {
      -- never polled: the scenario shows the dialog itself
      auth = {},
      device = {
        verification_uri = "https://hardcover.app/link",
        user_code = "ABCD-1234",
      },
    }
    UIManager:show(dialog)
    emu:pump()

    emu:expectText("Sign in to Hardcover")
    emu:expectText("ABCD-1234") -- a made-up code, never sent anywhere
    emu:expectText("Waiting for approval")
    emu:shot("signin")

    -- the whole instruction has to be on screen, not cut off at an edge
    emu:expectText("https://hardcover.app/link")
    emu:expectText("and enter this code:")
    local W = require("device").screen:getWidth()
    for _, node in ipairs(emu:screenNodes()) do
      if node.x then
        assert(node.x >= 0 and node.x + node.w <= W + 1, "text runs off the screen: " .. node.text)
      end
    end

    -- a real tap on Cancel (the screen closes, so nothing is left to inspect)
    local cancel = emu:expectText("Cancel")
    emu:tap(cancel.x + 5, cancel.y + 5)
    assert(not UIManager:isWidgetShown(dialog), "Cancel did not close the sign-in screen")
  end,
}
