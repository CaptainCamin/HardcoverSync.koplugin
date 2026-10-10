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

    -- every picture is drawn in the one box of the list's covers, whatever size was uploaded:
    -- the decoded pictures are all that size (the keys end in the box)
    local sizes, checked = {}, 0
    for key in pairs(dialog.covers.bbs) do
      checked = checked + 1
      sizes[key:match("|(%d+x%d+)$")] = true
    end
    local distinct = 0
    for _ in pairs(sizes) do distinct = distinct + 1 end
    assert(checked >= #UPLOADED, "only " .. checked .. " rows drew a cover")
    assert(distinct == 1, "the covers were drawn at " .. distinct .. " different sizes")
    emu:shot("shelf_cover_size")

    for i, size in pairs(saved) do
      local image = fixtures.shelf_books[i].cached_image
      image.width, image.height = size[1], size[2]
    end
    emu:closeAll()
  end,
}
