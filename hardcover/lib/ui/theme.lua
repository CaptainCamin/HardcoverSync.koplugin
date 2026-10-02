-- The plugin's visual language, in one place.
--
-- Designed for e-ink, so the rules are these:
--
--   * Contrast over decoration. Text is black; secondary text is a dark grey
--     (never lighter than DARK_GREY: mid greys wash out on the panel and
--     ghost). No gradients, shadows or tints.
--   * Hierarchy comes from size and weight, not colour. Three type sizes carry
--     a screen: a title, body text, and small labels.
--   * Structure comes from white space and thin rules, not boxes around
--     everything. A border is kept for things you tap, so a bordered thing
--     reads as a button.
--   * One spacing rhythm. Everything is a multiple of Theme.space.s so rows
--     line up from screen to screen.
--   * Big touch targets (at least TOUCH_MIN tall) and few of them.
--   * Redraw as little as possible: nothing animates, and a screen changes
--     its own contents in place rather than being rebuilt.
--
-- All sizes go through Screen:scaleBySize, so the same numbers read right at
-- 167 dpi and at 300.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TitleBar = require("ui/widget/titlebar")

local Screen = Device.screen

-- Screen:scaleBySize, but tolerant of the permissive stand-ins the spec
-- harnesses load this module against (they hand back a table, not a number)
local function px(n)
  local v = Screen:scaleBySize(n)
  return type(v) == "number" and v or n
end

local Theme = {}
Theme.px = px

-- text greys: black for everything that matters, dark grey for secondary text
Theme.BLACK = Blitbuffer.COLOR_BLACK
-- 0x55: KOReader's own COLOR_DARK_GRAY is 0x88, which washes out on the panel
Theme.DARK_GREY = Blitbuffer.COLOR_GRAY_5 or Blitbuffer.COLOR_DARK_GRAY
Theme.WHITE = Blitbuffer.COLOR_WHITE

-- spacing scale (scaled units: the same multiples everywhere)
Theme.space = {
  xs = px(4),
  s = px(8),
  m = px(16),
  l = px(24),
  xl = px(36),
}

-- the page's side margin
Theme.margin = px(20)

-- the smallest thing a finger is asked to hit
Theme.TOUCH_MIN = px(48)

-- line weights: a hairline rule between rows, a firm one under a heading
Theme.line = {
  hair = math.max(1, px(1)),
  firm = math.max(2, px(2)),
}

-- type: sizes in points, all one family so nothing fights
Theme.type = {
  display = 26, -- a book's title
  title = 21, -- section and row titles
  body = 18, -- running text
  small = 15, -- secondary lines, labels
  label = 13, -- the smallest: captions under covers
}

function Theme.face(size_name)
  return Font:getFace("cfont", Theme.type[size_name] or size_name)
end

function Theme.span(name)
  return VerticalSpan:new { width = Theme.space[name] or name }
end

function Theme.hspan(name)
  return HorizontalSpan:new { width = Theme.space[name] or name }
end

--
-- A horizontal rule of the given width. `firm` for a heading underline.
--
function Theme.rule(width, firm)
  return LineWidget:new {
    dimen = Geom:new { w = width, h = firm and Theme.line.firm or Theme.line.hair },
    background = firm and Theme.BLACK or Theme.DARK_GREY,
  }
end

--
-- A section heading: the words in bold with a firm rule beneath, so sections
-- read as chapters, with the room above to separate it from what came before.
-- `right` (a widget) is placed at the far end of the heading line (a count, a
-- small button).
--
function Theme.sectionHeader(text, width, right)
  local title = TextWidget:new {
    text = text,
    face = Theme.face("title"),
    bold = true,
    max_width = width,
    fgcolor = Theme.BLACK,
  }
  local line = HorizontalGroup:new { align = "center", title }
  if right then
    local gap = math.max(0, width - title:getSize().w - right:getSize().w)
    table.insert(line, HorizontalSpan:new { width = gap })
    table.insert(line, right)
  end
  return VerticalGroup:new {
    align = "left",
    line,
    VerticalSpan:new { width = Theme.space.xs },
    Theme.rule(width, true),
  }
end

--
-- A key figure over its label ("129" / "Want to Read"): the number big and
-- bold, the label small beneath. For counts and ratings.
--
function Theme.stat(value, label, width)
  return VerticalGroup:new {
    align = "center",
    TextWidget:new {
      text = tostring(value),
      face = Theme.face("display"),
      bold = true,
      max_width = width,
      fgcolor = Theme.BLACK,
    },
    TextWidget:new {
      text = label,
      face = Theme.face("small"),
      max_width = width,
      fgcolor = Theme.DARK_GREY,
    },
  }
end

--
-- A small rounded label with a border: a status ("Currently Reading"), a
-- series ("Hainish Cycle #4"). Informational, so it is not a button: pass
-- `filled` for the selected/active look (black with white text).
--
function Theme.pill(text, opts)
  opts = opts or {}
  local filled = opts.filled
  return FrameContainer:new {
    bordersize = Theme.line.firm,
    color = Theme.BLACK,
    background = filled and Theme.BLACK or Theme.WHITE,
    radius = px(opts.radius or 14),
    padding = px(3),
    padding_left = Theme.space.m,
    padding_right = Theme.space.m,
    margin = 0,
    TextWidget:new {
      text = text,
      face = Theme.face(opts.size or "small"),
      bold = true,
      max_width = opts.max_width,
      fgcolor = filled and Theme.WHITE or Theme.BLACK,
    },
  }
end

--
-- A bordered box of exactly w x h, with its child centred in it.
--
-- A FrameContainer paints at its `width`/`height` but REPORTS content plus
-- border to its parent, so a row of "w-wide" frames overflows the margin by
-- the borders and padding. Putting the child in a CenterContainer whose size is
-- the inside of the box makes the reported size the same as the painted one.
-- opts: filled (black with white text), border (px, default firm), radius
-- (scaled units).
--
function Theme.box(w, h, child, opts)
  opts = opts or {}
  local bs = opts.border or Theme.line.firm
  return FrameContainer:new {
    bordersize = bs,
    radius = opts.radius and px(opts.radius) or nil,
    padding = 0,
    margin = 0,
    width = w,
    height = h,
    color = Theme.BLACK,
    background = opts.filled and Theme.BLACK or Theme.WHITE,
    CenterContainer:new {
      dimen = Geom:new { w = w - 2 * bs, h = h - 2 * bs },
      child,
    },
  }
end

-- A button's height: comfortably over TOUCH_MIN
Theme.BUTTON_H = px(54)

--
-- The family's button: a bordered, rounded box with bold text, tappable over
-- exactly what it draws. `filled` is the primary action (black, white text).
-- opts: filled, h, size (type name), radius, callback, viewport (see
-- viewport.lua: for buttons inside a scroll area), enabled (false = dark grey
-- text, no tap), name.
--
function Theme.button(text, w, opts)
  opts = opts or {}
  local TapRow = require("hardcover/lib/ui/tap_row")
  local enabled = opts.enabled ~= false
  local label = TextWidget:new {
    text = text,
    face = Theme.face(opts.size or "small"),
    bold = true,
    max_width = w - 2 * Theme.line.firm - Theme.space.s,
    fgcolor = (opts.filled and Theme.WHITE) or (enabled and Theme.BLACK or Theme.DARK_GREY),
  }
  local box = Theme.box(w, opts.h or Theme.BUTTON_H, label,
    { filled = opts.filled, radius = opts.radius or 8 })
  local tap = TapRow:new {
    callback = enabled and opts.callback or nil,
    viewport = opts.viewport,
    box,
  }
  tap.label = label
  tap.text = text -- what the button says (also how a test finds it)
  tap.width = w
  return tap
end

--
-- The title bar every screen shares: the title centred, an optional icon at
-- the left (settings, sort), the close X at the right, and no rule under it
-- (the first section heading of the page draws the firm rule).
--
function Theme.titleBar(opts)
  return TitleBar:new {
    width = opts.width or Screen:getWidth(),
    fullscreen = true,
    align = "center",
    title = opts.title,
    left_icon = opts.left_icon,
    left_icon_tap_callback = opts.left_callback,
    with_bottom_line = false,
    close_callback = opts.close_callback,
    show_parent = opts.show_parent,
  }
end

return Theme
