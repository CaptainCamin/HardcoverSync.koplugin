--[[--
What a tap shows: the row that was pressed flashes (its label is inverted) for the moment
before its callback runs, and the covers in that row are never inverted. The lists index
has a cover strip and a name beside it, so it is the case that matters.

Captures the frame as the highlight is drawn (tap_flash.png) beside the same screen before
the tap (tap_before.png), and checks that the highlight was one refresh of the label's
column, not a repaint of the whole row or the page.
]]

local fixtures = require("fixtures")
local perf = require("perf")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen

return {
  name = "tap_feedback",

  run = function(emu)
    local probe = emu.probe
    for _, b in ipairs(fixtures.shelf_books) do
      local image = b.cached_image
      if image and image.url then fixtures.seed_cover(image.url, b.book_id % 3 + 1) end
    end
    for _, id in ipairs({ 101, 102, 103, 106, 109 }) do fixtures.seed_cover(fixtures.cover_url(id), id % 3 + 1) end

    local manager, settings = perf.new_manager(emu, fixtures, "tap_feedback")
    local SETTING = require("hardcover/lib/constants/settings")
    settings:updateSetting(SETTING.COMPATIBILITY_MODE, false)
    fixtures.install({ settings = settings })

    manager:showLists()
    perf.run_loop()
    emu:shot("tap_before")

    -- the first list's name: the label beside its covers
    local target
    for _, node in ipairs(emu:screenNodes()) do
      if node.text == "To Read - SciFi" then target = node end
    end
    assert(target, "the first list's name is not on screen")

    -- capture the frame the highlight is drawn in: forceRePaint is the moment it is
    -- on the screen and the refresh is queued, before the callback runs
    local flash_path = emu.out .. "/tap_flash.png"
    local real_repaint = UIManager.forceRePaint
    local captured = false
    UIManager.forceRePaint = function(um, ...)
      if not captured then
        captured = true
        Screen:shot(flash_path)
      end
      return real_repaint(um, ...)
    end

    probe:reset()
    emu:tapExpecting(target.x + 5, target.y + 5)
    perf.run_loop()
    UIManager.forceRePaint = real_repaint

    assert(captured, "the tap did not flash the row before its callback")
    local snap = probe:snapshot()
    -- the highlight is one fast refresh no wider than the label column (the cover strip
    -- beside it is not refreshed)
    local first = snap.log[1]
    assert(first, "the highlight was not refreshed")
    assert(first.mode == "Fast", "the highlight used a " .. tostring(first.mode) .. " refresh, not fast")
    assert(first.w < Screen:getWidth() * 0.8, string.format("the highlight refreshed %d px wide, not the label column", first.w))
    print(string.format("  flash: %s refresh %dx%d at %d,%d", first.mode, first.w, first.h, first.x, first.y))
    print("  flash: shot " .. flash_path)
  end,
}
