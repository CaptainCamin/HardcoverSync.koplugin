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
        expires_in = 900,
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
    emu:expectText("Open this page on any device")
    emu:expectText("Enter this code")
    emu:expectText("Approve the request")
    emu:expectText("Code valid for 15 min")
    local W = require("device").screen:getWidth()
    for _, node in ipairs(emu:screenNodes()) do
      if node.x then
        assert(node.x >= 0 and node.x + node.w <= W + 1, "text runs off the screen: " .. node.text)
      end
    end

    -- the code is big: at least three times the height of the body text
    local code = emu:expectText("ABCD-1234")
    assert(code.h >= 3 * emu:expectText("Approve the request").h / 1.5, "the code is not big")

    -- the waiting bar follows the code's life in steps of a twentieth, and does
    -- not move between them (no redraw for no visible change)
    assert(dialog.wait_bar.percentage == 0, "the bar starts full")
    dialog.started_at = os.time() - 450
    dialog:updateWait()
    assert(math.abs(dialog.wait_bar.percentage - 0.5) < 0.01, "the bar did not move to half: " .. dialog.wait_bar.percentage)
    dialog.started_at = os.time() - 460
    dialog:updateWait()
    assert(math.abs(dialog.wait_bar.percentage - 0.5) < 0.01, "the bar moved inside a step")
    emu:shot("signin_halfway")

    -- a real tap on Cancel (the screen closes, so nothing is left to inspect)
    local cancel = emu:expectText("Cancel")
    emu:tap(cancel.x + 5, cancel.y + 5)
    assert(not UIManager:isWidgetShown(dialog), "Cancel did not close the sign-in screen")
  end,
}
