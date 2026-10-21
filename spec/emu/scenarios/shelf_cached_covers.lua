--[[--
Covers already on the device are drawn without holding up input.

KOReader's main loop (UIManager:handleInput) runs its tasks and repaints again and again for as
long as a pass scheduled another task, and reads input only when a pass schedules none. A task per
cover, each scheduled by the one before, therefore held every tap until the last cover of the page
was drawn, and the page did not turn. Here the loop is run by hand, with a pause for each repaint
(an e-ink refresh takes 200 ms or more), and counted: how many passes before it would read input.
]]

local fixtures = require("fixtures")

return {
  name = "shelf_cached_covers",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    for _, b in ipairs(fixtures.shelf_books) do
      local image = b.cached_image
      if image and image.url then fixtures.seed_cover(image.url, b.book_id % 3 + 1) end
    end
    fixtures.install({ settings = settings })

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local HARDCOVER = require("hardcover/lib/constants/hardcover")
    local manager = DialogManager:new { settings = settings }
    manager:showShelf(HARDCOVER.STATUS.TO_READ, "Want to Read")
    local dialog = manager.shelf_dialog
    assert(dialog and dialog.per_page > 4, "the shelf needs several covers on a page")

    local UIManager = emu.UIManager
    local function drawn()
      local n = 0
      for _ in pairs(dialog.covers.bbs) do n = n + 1 end
      return n
    end

    local passes, longest = 0, 0
    for _ = 1, 40 do
      -- one stretch of the main loop: passes until one schedules nothing
      passes = 0
      repeat
        UIManager:_checkTasks()
        os.execute("sleep 0.3") -- the repaint
        passes = passes + 1
      until not UIManager._task_queue_dirty or passes > 30
      longest = math.max(longest, passes)
    end
    assert(drawn() >= dialog.per_page - 2, "only " .. drawn() .. " covers were drawn")
    print(string.format("  longest stretch without reading input: %d passes", longest))
    assert(longest <= 3, longest .. " passes of the main loop in a row without reading input while covers were drawn")
    emu:closeAll()
  end,
}
