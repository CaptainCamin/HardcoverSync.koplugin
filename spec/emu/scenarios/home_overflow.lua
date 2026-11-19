--[[--
Home given less room than its card needs (issue #341): the body must stay inside the room it was
given, with the rest reachable through the plugin's visible scroll control, so a shell's nav bar
cannot be pushed off the screen.

Screens: home_overflow.
]]--

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")
local Device = require("device")

local HomeBody = require("hardcover/lib/ui/home_body")

return {
  name = "home_overflow",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })

    local h = math.floor(Device.screen:scaleBySize(150))
    local shell = { isActive = function() return true end }
    local body = HomeBody:new {
      shell = shell, width = Device.screen:getWidth(), height = h,
      entries = fixtures.currently_reading,
      rows = {},
    }
    UIManager:show(body, "full")
    emu:pump()

    assert(body.scroll, "the overflowing Home has no scroll")
    local size = body[1]:getSize()
    assert(size.h <= h, string.format("Home grew to %d in %d of room", size.h, h))
    assert(size.w <= body.dimen.w, "Home grew past the side of the screen")
    emu:shot("home_overflow")

    local before = body.scroll._scroll_offset_y or 0
    emu:press("LPgFwd")
    emu:pump()
    assert((body.scroll._scroll_offset_y or 0) > before, "the scroll control cannot reach the rest of Home")
    emu:closeAll()
  end,
}
