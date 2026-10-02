-- A cover-sized box: a generic book icon until a picture is put in it.
--
-- The box is the same size either way, so a layout does not move when the
-- picture arrives, and a book with no cover (or one that never loads) looks like
-- the others. It does not fetch anything itself: whoever owns it hands over the
-- image bytes with setImage, and calls release() when done so the picture's
-- memory is given back.

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local Size = require("ui/size")

local CoverBox = {}
CoverBox.__index = CoverBox

--
-- opts: width, height (the picture box, inside the frame), border (frame
-- thickness, default thin), padding (extra space inside the frame, so a thicker
-- border on one box does not change its outer size).
--
function CoverBox:new(opts)
  local o = setmetatable(opts or {}, self)
  o.border = o.border or Size.border.thin
  o.padding = o.padding or 0

  local icon_size = math.floor(o.width * 0.5)
  o.frame = FrameContainer:new {
    bordersize = o.border,
    padding = o.padding,
    margin = 0,
    CenterContainer:new {
      dimen = Geom:new { w = o.width, h = o.height },
      IconWidget:new { icon = "book.opened", width = icon_size, height = icon_size },
    },
  }
  return o
end

-- The widget to put in a layout.
function CoverBox:widget()
  return self.frame
end

-- Swap the placeholder for the picture. Returns false if the bytes do not render.
function CoverBox:setImage(content)
  local RenderImage = require("ui/renderimage")
  local bb = RenderImage:renderImageData(content, #content, false, self.width, self.height)
  if not bb then return false end

  self:release()
  self.bb = bb
  -- scale_factor 0 fits the picture inside the box keeping its proportions;
  -- image_disposable is off because this box owns (and frees) the buffer
  self.frame[1] = CenterContainer:new {
    dimen = Geom:new { w = self.width, h = self.height },
    ImageWidget:new {
      image = bb,
      image_disposable = false,
      width = self.width,
      height = self.height,
      scale_factor = 0,
    },
  }
  return true
end

-- Give back the picture's memory.
function CoverBox:release()
  if self.bb and self.bb.free then
    self.bb:free()
  end
  self.bb = nil
end

return CoverBox
