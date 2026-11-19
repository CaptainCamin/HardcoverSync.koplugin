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
    assert(body.layout.note, "the scrollable Home dropped the sync box")
    emu:shot("home_overflow")

    -- The down and up triangles are the visible control, distinct from the container's page keys.
    emu:screenNodes()
    local control_x = Device.screen:getWidth() - 10
    local top_y = body.scroll.dimen.y + 20
    local bottom_y = body.scroll.dimen.y + h - 20
    emu:tap(control_x, bottom_y)
    emu:pump()
    assert(body.scroll:getScrolledOffset().y > 0, "the down triangle did not scroll")
    emu:tap(control_x, top_y)
    emu:pump()
    assert(body.scroll:getScrolledOffset().y == 0, "the up triangle did not return to the top")

    -- Page keys still scroll the same container.
    local before = body.scroll:getScrolledOffset().y
    emu:press("LPgFwd")
    emu:pump()
    assert(body.scroll:getScrolledOffset().y > before, "the page keys cannot scroll Home")
    emu:closeAll()
  end,
}
