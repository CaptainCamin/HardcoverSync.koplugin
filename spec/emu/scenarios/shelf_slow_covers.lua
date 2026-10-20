--[[--
Paging a list while its covers are still downloading.

The covers are not on the device and every download is slow (the real loader, in a real
subprocess, as on a device). A tap on the list's scroll control must turn the page at once,
not wait for the covers: a download that can be cancelled by a tap covers the screen with a
widget that takes the tap, so paging used to need about one tap per cover.
]]

local fixtures = require("fixtures")

return {
  name = "shelf_slow_covers",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })

    -- no cover is on the device, and each download takes a while (in its own subprocess)
    for _, dir in ipairs({ "/cache/hardcover_covers", "/cache/hardcover_covers_offline" }) do
      os.execute("rm -rf '" .. emu.DataStorage:getDataDir() .. dir .. "'")
    end
    package.loaded["hardcover/vendor/url_content"] = function()
      os.execute("sleep 6")
      return false, "slow"
    end
    package.loaded["hardcover/lib/ui/image_loader"] = nil
    local loader = require("hardcover/lib/ui/image_loader")
    loader.isOnline = function() return true end

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local HARDCOVER = require("hardcover/lib/constants/hardcover")
    local manager = DialogManager:new { settings = settings }
    manager:showShelf(HARDCOVER.STATUS.TO_READ, "Want to Read")
    emu:pump()

    local dialog = manager.shelf_dialog
    assert(dialog and dialog.pages > 1, "the shelf needs more than one page")
    assert(dialog.page == 1)

    -- a download in flight must not put a widget over the list: it would take the taps meant for
    -- the list (and a screen-wide one is left behind for each page that is turned away from)
    local function traps()
      local n = 0
      for _, w in ipairs(emu.UIManager._window_stack) do
        if w.widget.modal and w.widget ~= dialog then n = n + 1 end
      end
      return n
    end

    -- let the first downloads start
    for _ = 1, 20 do emu:pump(); os.execute("sleep 0.1") end
    assert(traps() == 0, "a cover download covers the list with a widget that takes its taps")

    local W, H = emu.Screen:getWidth(), emu.Screen:getHeight()
    for page = 2, math.min(dialog.pages, 3) do
      emu:screenNodes()
      emu:tap(W - 10, H - 20) -- the down triangle
      emu:pump()
      assert(dialog.page == page, "one tap did not turn to page " .. page .. " while covers were loading: page "
        .. tostring(dialog.page))
      for _ = 1, 10 do emu:pump(); os.execute("sleep 0.1") end
      assert(traps() == 0, "page " .. page .. " left a widget over the list")
    end
    emu:closeAll()
  end,
}
