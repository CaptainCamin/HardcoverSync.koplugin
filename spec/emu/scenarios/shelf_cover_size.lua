--[[--
A shelf's covers fill their row whatever size the cover was uploaded at.

The list scaled each picture by the size Hardcover reports for the cover as uploaded
(cached_image.width/height), but the picture it draws is the image service's, a fixed
240x360 whatever was uploaded. A cover uploaded at 1400x2100 came out a twentieth of
the row; one uploaded at 100x150 came out twice as tall as the row, over the rows
below. The fixture covers (240x360) are given those upload sizes here.

Screen: shelf_cover_size.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

-- What Hardcover reports for each row's cover as uploaded: much larger than the
-- picture that arrives, much smaller, and the same.
local UPLOADED = { { 1400, 2100 }, { 100, 150 }, { 240, 360 } }

return {
  name = "shelf_cover_size",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    local saved = {}
    for i, b in ipairs(fixtures.shelf_books) do
      local image = b.cached_image
      if image and image.url then
        saved[i] = { image.width, image.height }
        local size = UPLOADED[(i - 1) % #UPLOADED + 1]
        image.width, image.height = size[1], size[2]
        fixtures.seed_cover(image.url, 1)
      end
    end
    settings:updateSetting(require("hardcover/lib/constants/settings").SHELF_SORT, nil)
    settings:updateSetting(require("hardcover/lib/constants/settings").COMPATIBILITY_MODE, false)
    fixtures.install({ settings = settings })

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local HARDCOVER = require("hardcover/lib/constants/hardcover")
    local manager = DialogManager:new { settings = settings }
    manager:showShelf(HARDCOVER.STATUS.TO_READ, "Want to Read")
    for _ = 1, 20 do emu:pump() end

    local dialog = manager.shelf_dialog
    assert(dialog and UIManager:isWidgetShown(dialog), "the shelf was not shown")

    -- every row that drew a picture: its frame is the row's height (a 2:3 cover in a
    -- square box is as tall as the box), never a sliver and never taller
    local checked = 0
    for _, row in ipairs(dialog.menu.item_group) do
      if row._has_cover_image and row.cover_frame and row.dimen then
        checked = checked + 1
        local frame_h, row_h = row.cover_frame:getSize().h, row.dimen.h
        assert(frame_h <= row_h,
          string.format("row %q: the cover (%d px) is taller than its row (%d px)",
            tostring(row.entry and row.entry.text), frame_h, row_h))
        assert(frame_h >= row_h * 0.9,
          string.format("row %q: the cover (%d px) is far shorter than its row (%d px)",
            tostring(row.entry and row.entry.text), frame_h, row_h))
      end
    end
    assert(checked >= #UPLOADED, "only " .. checked .. " rows drew a cover")
    emu:shot("shelf_cover_size")

    for i, size in pairs(saved) do
      local image = fixtures.shelf_books[i].cached_image
      image.width, image.height = size[1], size[2]
    end
    emu:closeAll()
  end,
}
