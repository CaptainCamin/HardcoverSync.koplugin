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
--   Learned from Mudita Mindful Design (docs/e-ink-design.md has the sources, how
--   much to trust them, and the open questions):
--
--   * Every control is visible. Anything that can be tapped, scrolled or held has a
--     control on screen. A swipe or a long press may be a shortcut, never the only
--     way to do something.
--   * Fit in the lines. Rows keep one fixed height and stay put from page to page, so
--     the rules between them are redrawn in the same places. A long page should
--     scroll by whole pages that land on row edges.
--   * State never rests on grey alone. A disabled or off control shows it with a
--     check, a fill or a dotted border, or is left out.
--   * Few big dark areas. Try an outline or a pattern before a solid fill; a fill
--     marks the one primary action or the active choice.
--   * Say what happened. With no animation, acknowledge a tap with visible text
--     ("Saved"). Underline alone does not read as a link: use a box or an icon.
--
--   * Titles in Lato Black, text in Lato Medium (Theme.title, Theme.mmdText); no serif. Buttons are
--     rectangular with an 8 radius (components/button.lua); the older pill buttons are being moved over.
--     Solid black progress bars (Theme.progress). Where a grey is wanted, hatch
--     (Theme.hatch) rather than use a mid grey.
--
--   Owner's direction (2026-10-10, nothing implemented yet): charts may keep tonal
--   greys (polish them rather than swap in patterns); Lato is liked and is the
--   likely typeface; pure-black secondary text is wanted as a beta setting, with
--   DARK_GREY staying the default. Still open: divider weight (dotted or solid),
--   compact button heights, a bottom navigation bar. Known gaps: Theme.hatchRect
--   paints at 40% opacity (grey stripes, and nothing calls it yet), and eight
--   scroll screens have no tap controls for paging.
--
-- All sizes go through Screen:scaleBySize, so the same numbers read right at
-- 167 dpi and at 300.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
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

-- Secondary text: dark grey by default, pure black when the beta setting asks for it. Every
-- grey text site goes through here, so the setting reaches all of them. Called when a widget
-- is built, not once at load, so a change shows on the next screen that opens.
function Theme.secondary()
  return require("hardcover/lib/ui_prefs").pure_black_text and Theme.BLACK or Theme.DARK_GREY
end

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

-- Component metrics from the Mudita Mindful Design appendix (docs/e-ink-design.md), in the
-- diagrams' own px, scaled like everything else. Components read their sizes from here.
Theme.mmd = {
  switch = { w = px(48), h = px(30), knob = px(20), touch = px(56) },
  radio = { size = px(26), dot = px(14), touch = px(48) },
  checkbox = { size = px(28), touch = px(48) },
  tabs = { h = px(50) },
  top_bar = { h = px(67), icon = px(28), side = px(16) },
  nav_bar = { h = px(57), icon = px(18) },
  rule = { overlay = px(3), gap = px(2) }, -- the black rule and white gap on top of anything laid over a page
  row = { pad_x = px(16), pad_y = px(15.5), gap = px(4), icon = px(28), tile = px(48) },
  button = { radius = px(8), border = math.max(2, px(2)) },
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

--
-- MMD type for the components: "text" is Lato Medium and "strong" is Lato Black, sizes in the
-- appendix's design px. Lato is used when it is installed; until then KOReader's UI font stands in,
-- with `strong` as bold. Returns the face and whether the widget still has to ask for bold.
--
local MMD_FONT = { text = "Lato-Medium.ttf", strong = "Lato-Black.ttf" }
local mmd_missing = {} -- fonts KOReader could not load: asked once, since it logs an error each time
function Theme.mmdFace(kind, size)
  local name = MMD_FONT[kind] or MMD_FONT.text
  if not mmd_missing[name] then
    local ok, face = pcall(Font.getFace, Font, name, size)
    if ok and face then return face, false end
    mmd_missing[name] = true
  end
  return Font:getFace("cfont", size), kind == "strong"
end

-- One line of MMD type. opts { width (cut with an ellipsis), secondary, color }.
function Theme.mmdText(str, kind, size, opts)
  opts = opts or {}
  local face, bold = Theme.mmdFace(kind, size)
  return TextWidget:new {
    text = tostring(str),
    face = face,
    bold = bold,
    max_width = opts.width,
    fgcolor = opts.color or (opts.secondary and Theme.secondary() or Theme.BLACK),
  }
end

--
-- The face for titles and headings: Lato Black (MMD's type, the owner's call of 10 Oct 2026: no serif),
-- or KOReader's UI font as bold where Lato is not installed. Returns the face and whether the widget
-- still has to ask for bold. `size_name` is a Theme.type name or a size.
--
function Theme.title(size_name)
  local size = Theme.type[size_name] or size_name
  return Theme.mmdFace("strong", size)
end
-- the old name, for callers not yet renamed
Theme.serif = Theme.title

--
-- Hatching: a grey that stays crisp on e-ink (diagonal black lines at 40% opacity), the
-- same call Zen UI uses. Paint into a blitbuffer directly...
--
function Theme.hatchRect(bb, x, y, w, h)
  if w > 0 and h > 0 and bb.hatchRect then
    bb:hatchRect(x, y, w, h, math.max(1, px(2)), Blitbuffer.COLOR_BLACK, 0.4)
  end
end

--
-- ...or as a widget of a given size, to sit in a layout (a disabled control's fill, a
-- placeholder behind a missing cover).
--
function Theme.hatch(w, h)
  local Widget = require("ui/widget/widget")
  local widget = Widget:new { dimen = Geom:new { w = w, h = h } }
  function widget:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    Theme.hatchRect(bb, x, y, self.dimen.w, self.dimen.h)
  end
  return widget
end

--
-- A progress bar: a pill outline with a solid black fill. KOReader's default fill is a
-- mid grey (0x88), which washes out on the panel. opts: width, height, percentage,
-- ticks, last (as ProgressWidget).
--
function Theme.progress(opts)
  local ProgressWidget = require("ui/widget/progresswidget")
  local h = opts.height
  return ProgressWidget:new {
    width = opts.width,
    height = h,
    percentage = opts.percentage,
    ticks = opts.ticks,
    last = opts.last,
    fillcolor = Theme.BLACK,
    bordercolor = Theme.BLACK,
    bgcolor = Theme.WHITE,
    bordersize = Theme.line.firm,
    radius = type(h) == "number" and math.floor(h / 2) or px(8),
    margin_h = Theme.line.firm,
    margin_v = Theme.line.firm,
  }
end

--
-- An icon bundled with the plugin: pass a name for `<plugin>/icons/<name>.svg`, or a path.
-- (IconWidget given a `file` skips KOReader's own icon lookup, so any SVG or PNG works.)
-- Name an icon KOReader already ships (e.g. "home") through IconWidget directly instead.
--
-- the folder this file was loaded from, up to and including its trailing slash ("" when
-- loaded relative to the working directory)
local plugin_root = (debug.getinfo(1, "S").source or ""):match("^@(.-)hardcover/lib/ui/theme%.lua$") or ""
function Theme.icon(name_or_path, size, opts)
  opts = opts or {}
  local IconWidget = require("ui/widget/iconwidget")
  local file = name_or_path
  if not file:find("/", 1, true) then
    file = plugin_root .. "icons/" .. file .. ".svg"
  end
  return IconWidget:new {
    file = file,
    width = size or Theme.TOUCH_MIN,
    height = size or Theme.TOUCH_MIN,
    alpha = opts.alpha ~= false,
  }
end

--
-- One line of text in the family's type: `size` a Theme.type name (default "body"), opts
-- { bold, grey, width } (width is the most it may take; longer text is cut with an ellipsis).
--
function Theme.text(str, size, opts)
  opts = opts or {}
  return TextWidget:new {
    text = tostring(str),
    face = Theme.face(size or "body"),
    bold = opts.bold,
    max_width = opts.width,
    fgcolor = opts.grey and Theme.secondary() or Theme.BLACK,
  }
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
-- A dotted horizontal rule `width` wide: one hairline of black dots. The
-- divider between list rows; a solid rule is for structure. Built when first drawn, so the module
-- loads without it.
--
function Theme.dottedRule(width)
  local Widget = require("ui/widget/widget")
  local t = Theme.line.hair
  local rule = Widget:new { dimen = Geom:new { w = width, h = t } }
  function rule:getSize() return self.dimen end
  function rule:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    -- dots a hairline across with a gap of two, so it reads as dots and not as a faint solid line
    local pitch = t * 3
    for dx = 0, width - t, pitch do
      bb:paintRect(x + dx, y, t, t, Theme.BLACK)
    end
  end
  return rule
end

--
-- A section heading: the words in bold with a firm rule beneath, so sections
-- read as chapters, with the room above to separate it from what came before.
-- `right` (a widget) is placed at the far end of the heading line (a count, a
-- small button).
--
function Theme.sectionHeader(text, width, right)
  -- a long heading is cut short (with an ellipsis) rather than pushing what is at the
  -- end of the line past the edge
  local room = right and math.max(0, width - right:getSize().w - Theme.space.m) or width
  local face, bold = Theme.title("title")
  local title = TextWidget:new {
    text = text,
    face = face,
    bold = bold,
    max_width = room,
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
      face = (Theme.title("display")),
      bold = select(2, Theme.title("display")),
      max_width = width,
      fgcolor = Theme.BLACK,
    },
    TextWidget:new {
      text = label,
      face = Theme.face("small"),
      max_width = width,
      fgcolor = Theme.secondary(),
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
    radius = opts.round and math.floor(math.min(w, h) / 2) or (opts.radius and px(opts.radius) or nil),
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

--
-- Make a drawn widget (a pill, a line of text) tappable over a cell `w` wide
-- and at least TOUCH_MIN tall, the widget at its left and centred vertically, so
-- a small thing is still easy to hit. `viewport` as for a button.
--
function Theme.touchable(child, w, callback, viewport)
  local TapRow = require("hardcover/lib/ui/tap_row")
  local h = math.max(child:getSize().h, Theme.TOUCH_MIN)
  return TapRow:new {
    callback = callback,
    viewport = viewport,
    LeftContainer:new {
      dimen = Geom:new { w = w, h = h },
      child,
    },
  }
end

-- A button's height: comfortably over TOUCH_MIN
Theme.BUTTON_H = px(54)

--
-- The family's button: a bordered, rounded box with bold text, tappable over
-- exactly what it draws. `filled` is the primary action (black, white text).
-- opts: filled, h, size (type name), radius (default: a full pill), callback, viewport (see
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
    { filled = opts.filled, radius = opts.radius, round = opts.radius == nil })
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
