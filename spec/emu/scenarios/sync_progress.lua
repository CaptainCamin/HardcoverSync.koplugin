-- The sync progress bar: a toast along the bottom edge while queued changes go out, updated in place
-- as each entry is verified and sent, gone when the flush ends. It never takes the page away.
--
-- Screens: sync_progress_start, sync_progress_verify, sync_progress_send.

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")
local Device = require("device")

return {
  name = "sync_progress",

  run = function(emu)
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local Theme = require("hardcover/lib/ui/theme")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local SyncProgress = require("hardcover/lib/ui/components/sync_progress")

    local SW, SH = Device.screen:getWidth(), Device.screen:getHeight()
    local page = FrameContainer:new { width = SW, height = SH, background = Theme.WHITE,
      bordersize = 0, padding = 0, margin = 0 }
    UIManager:show(page)
    emu:pump()

    local progress = SyncProgress.show { total = 12 }
    emu:pump()
    emu:expectText("Syncing 0 of 12")
    emu:shot("sync_progress_start")

    -- the slow part: Hardcover is asked about the book before anything is sent
    progress:update { phase = "verify", title = "Dune", kind = "page" }
    emu:pump()
    emu:expectText("Verifying page for Dune")
    emu:shot("sync_progress_verify")

    -- each entry sent moves the count and the fill
    progress:update { phase = "send" }
    progress:update { phase = "send" }
    progress:update { phase = "send" }
    emu:pump()
    emu:expectText("Syncing 3 of 12")
    emu:shot("sync_progress_send")

    -- the flush ends: the bar goes, the page is what is left
    progress:close()
    emu:pump()
    assert(UIManager:getTopmostVisibleWidget() == page, "the progress bar stayed after the flush")

    UIManager:close(page)
    emu:pump()
  end,
}
