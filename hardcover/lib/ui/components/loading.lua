-- Loading (MMD): a small box in the middle of the screen with one line of Black 21 text, the
-- plugin's own (an Overlay, so it closes like any other: message:close()). Not dismissable: a tap
-- on it or outside it does nothing until the answer is in. Static, no spinner.

local Loading = {}

function Loading.show(text)
  local Device = require("device")
  local FrameContainer = require("ui/widget/container/framecontainer")
  local CenterContainer = require("ui/widget/container/centercontainer")
  local Geom = require("ui/geometry")
  local Overlay = require("hardcover/lib/ui/components/overlay")
  local Theme = require("hardcover/lib/ui/theme")
  local w = math.min(Device.screen:getWidth() - 2 * Theme.margin, Theme.px(560))
  local pad = Theme.px(24)
  local label = Theme.mmdText(text, "strong", 21, { width = w - 2 * pad - 2 * Theme.line.firm })
  local box = FrameContainer:new { width = w, bordersize = Theme.line.firm, padding = pad, margin = 0,
    color = Theme.BLACK, background = Theme.WHITE,
    CenterContainer:new { dimen = Geom:new { w = w - 2 * pad - 2 * Theme.line.firm, h = label:getSize().h }, label } }
  -- not dismissable: a tap on it or outside it does nothing until the answer is in
  local overlay = Overlay:new { anchor = "center", box }
  overlay.dismiss = function() end
  return overlay:show()
end

return Loading
