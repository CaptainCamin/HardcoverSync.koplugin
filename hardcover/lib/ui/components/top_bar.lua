-- Top bar (MMD): 67 tall, the last 3 a black rule. A back arrow (touch 48) when you can go back, a
-- left-aligned Black 25 title, and one to three icon actions (touch 48) at the right; 16 at the sides.
-- An icon alone is mistaken for another without colour, so keep to the familiar ones (search, sort,
-- close) and label anything risky.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")

local Draw = require("hardcover/lib/ui/components/draw")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local BLACK = Blitbuffer.COLOR_BLACK

local TopBar = {}

local function touch(icon_name, callback)
  local size = Theme.mmd.top_bar.icon
  local cell = Theme.TOUCH_MIN
  return TapRow:new {
    callback = callback,
    CenterContainer:new { dimen = Geom:new { w = cell, h = cell },
      -- a drawn icon of ours, or one of the plugin's SVGs (settings, plus, ...)
      Draw.ICONS[icon_name] and Draw.icon(icon_name, size) or Theme.icon(icon_name, size) },
  }
end

-- opts { width, title, on_back (shows the back arrow), actions = { { icon, callback } } }
function TopBar.new(opts)
  local m = Theme.mmd.top_bar
  local rule = Theme.mmd.rule.overlay
  local inner_h = m.h - rule

  local left = HorizontalGroup:new { align = "center", Theme.hspan(m.side - Theme.px(8)) }
  if opts.on_back then left[#left + 1] = touch("back", opts.on_back) end
  local right = HorizontalGroup:new { align = "center" }
  for _, action in ipairs(opts.actions or {}) do right[#right + 1] = touch(action.icon, action.callback) end
  right[#right + 1] = Theme.hspan(m.side - Theme.px(8))

  local room = opts.width - left:getSize().w - right:getSize().w - Theme.px(8)
  local title = Theme.mmdText(opts.title, "strong", 25, { width = room })
  local row = HorizontalGroup:new { align = "center",
    left,
    LeftContainer:new { dimen = Geom:new { w = room + Theme.px(8), h = inner_h },
      HorizontalGroup:new { Theme.hspan(opts.on_back and Theme.px(4) or Theme.px(8)), title } },
    right,
  }
  return VerticalGroup:new { align = "left",
    LeftContainer:new { dimen = Geom:new { w = opts.width, h = inner_h }, row },
    Draw.drawn(opts.width, rule, function(bb, x, y, w, h) bb:paintRect(x, y, w, h, BLACK) end),
  }
end

return TopBar
