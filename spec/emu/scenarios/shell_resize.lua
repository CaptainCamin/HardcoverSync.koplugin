--[[--
A panel resized while the shell is up (issue #341): the Home body is rebuilt at the new size instead
of painting the old, wider page into the smaller panel and pushing the nav bar off screen.

Screens: shell_resize.
]]--

local fixtures = require("fixtures")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")

local DialogManager = require("hardcover/lib/ui/dialog_manager")

return {
  name = "shell_resize",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })
    local manager = DialogManager:new { settings = settings }
    local shell = manager:showHome()
    emu:pump()

    -- Simulate a body left behind at the old panel's size.
    local old = shell.bodies.home
    old.width, old.height = 100, 100
    old:rebuild()

    local size = Geom:new { w = Device.screen:getWidth(), h = Device.screen:getHeight() }
    UIManager:broadcastEvent(Event:new("SetDimensions", size))
    emu:pump()

    local home = shell.bodies.home
    assert(home ~= old, "the shell kept the body built for the old panel")
    assert(home.width == size.w, "Home was not rebuilt at the new width")
    assert(home[1]:getSize().h <= home.height + 1, "Home still overflows its body")
    assert(UIManager:getTopmostVisibleWidget() == shell, "the resize left another screen up")
    emu:shot("shell_resize")
    emu:closeAll()
  end,
}
