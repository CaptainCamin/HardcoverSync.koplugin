--[[--
The scroll control on a long settings page: the track and a dotted up triangle at the top, a tap on
the down triangle steps a whole page (landing on a row edge), the up triangle is solid after that, and
the last page has a dotted down triangle. Taps on the control never reach a row underneath.

Screens: scroll_control_top, scroll_control_mid, scroll_control_end.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

return {
  name = "scroll_control",

  run = function(emu)
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local ticks, items = {}, {}
    for i = 1, 24 do
      ticks[i] = false
      items[i] = {
        text = "Option number " .. i,
        checked_func = function() return ticks[i] end,
        callback = function(menu) ticks[i] = not ticks[i]; if menu then menu:updateItems() end end,
      }
    end
    local SettingsDialog = require("hardcover/lib/ui/settings_dialog")
    local screen = SettingsDialog.show { items = items, title = "Settings" }
    emu:pump()
    assert(screen.scroll, "the page did not scroll: the check needs a page taller than the screen")
    emu:screenNodes() -- paint
    local sc = screen.scroll
    local Device = require("device")
    local W, H = Device.screen:getWidth(), Device.screen:getHeight()
    local control_x = W - 10
    local top_y = sc.dimen.y + 20
    local bottom_y = sc.dimen.y + sc.dimen.h - 20
    emu:shot("scroll_control_top")
    assert(sc:getScrolledOffset().y == 0, "should start at the top")

    -- a tap on the up triangle at the top does nothing
    emu:tap(control_x, top_y)
    emu:pump()
    assert(sc:getScrolledOffset().y == 0, "up at the top moved the page")

    -- down: one page, on a row edge
    emu:tap(control_x, bottom_y)
    emu:pump()
    local first = sc:getScrolledOffset().y
    assert(first > 0, "the down triangle did not scroll")
    emu:screenNodes()
    emu:shot("scroll_control_mid")
    for _, ticked in pairs(ticks) do assert(not ticked, "a tap on the control ticked a row") end

    -- up again goes back to the top
    emu:tap(control_x, top_y)
    emu:pump()
    assert(sc:getScrolledOffset().y == 0, "up did not return to the top")

    -- down until the end
    for _ = 1, 30 do emu:tap(control_x, bottom_y); emu:pump() end
    emu:screenNodes()
    local max = sc._max_scroll_offset_y
    assert(sc:getScrolledOffset().y >= max, "never reached the end: " .. sc:getScrolledOffset().y .. " of " .. max)
    emu:shot("scroll_control_end")
    emu:expectText("Option number 24")
  end,
}
