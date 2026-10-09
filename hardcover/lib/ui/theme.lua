-- The plugin's visual language, in one place.
--
-- Designed for e-ink, so the rules are these. Every visual signal has ONE meaning:
--
--   * BORDER: you can tap it. A control (a button, a tile, a row) has a 2px black border
--     and one corner radius, Theme.controlRadius; a chip (Theme.pill) is a full pill.
--     Anything that is only information has no border and square corners. A list is the
--     exception: its rows are not boxed (a hairline separates them), and the cue at a row's
--     end (Theme.switch, Theme.radio, Theme.chevron or an icon) says what tapping does; a row
--     with no cue is an action and its label is bold. A cover's 1px frame is the edge of a
--     picture, not a border.
--   * FILL: black with white text = active now: on, selected, or the one main action (at
--     most one per group). Grey fill with a grey border and grey text = unavailable (a
--     disabled control, Theme.button). Nothing else is grey-filled but the empty track of a
--     progress bar, which is not a control. Static information has no fill at all.
--   * CHEVRON: this opens another screen, list or picker (Theme.chevron). It goes on a row,
--     a chip or a heading; a button or tile does not carry one, its border already says tap.
--   * HATCH: the page behind a popup is unavailable (Theme.hatchRect). Never a fill.
--   * FONT: serif = the name of a thing (a title, a heading, a big figure: Theme.serif);
--     bold sans = the label on a control; regular sans = everything else, dark grey when it
--     is quieter. Hierarchy comes from size and weight, not colour.
--   * SHADOW: none. A popup is in front because the page behind it is hatched.
--   * Text is only ever black or DARK_GREY (never lighter: mid greys wash out and ghost on
--     the panel), on white or on WASH.
--   * Structure comes from white space and thin rules, not boxes around everything.
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

--
-- Shape. A CONTROL (anything you can tap: a button, a tile, a row, the search field) has a
-- border and ONE corner radius, Theme.controlRadius; a CHIP you can tap (Theme.pill) is a
-- full pill; everything else (covers, bars, rules) is square with no border. No other radius
-- is used anywhere.
--
function Theme.controlRadius(w, h)
  return math.min(px(12), math.floor(math.min(w, h) / 2))
end

--
-- The tonal scale: the only shades the plugin uses. Lightest to darkest:
--   white   the page, and every control that is available
--   wash    the fill of a control that is unavailable (and nothing else)
--   mid     the empty track of a progress bar
--   ink2    quieter text and the border of an unavailable control (DARK_GREY)
--   black   text, borders, and the fill of what is active
-- Text goes on white or wash only.
--
-- (the spec harnesses stand in for Blitbuffer without Color8)
local function grey(v) return Blitbuffer.Color8 and Blitbuffer.Color8(v) or v end

Theme.tone = {
  white = Blitbuffer.COLOR_WHITE,
  wash = grey(0xDD),
  mid = grey(0xCC),
  ink2 = Theme.DARK_GREY,
  black = Blitbuffer.COLOR_BLACK,
}
Theme.WASH = Theme.tone.wash
Theme.MID = Theme.tone.mid

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

--
-- The serif face for titles and headings (KOReader ships Noto Serif, so it needs no
-- bundling). Falls back to the UI face where it is not installed. The file is a real
-- bold, so do not also ask the widget for bold.
--
function Theme.serif(size_name)
  local size = Theme.type[size_name] or size_name
  local ok, face = pcall(Font.getFace, Font, "NotoSerif-Bold.ttf", size)
  if ok and face then return face, false end
  return Theme.face(size_name), true
end

--
-- Hatching: diagonal black lines at 25% opacity, crisp on e-ink where a grey would ghost.
-- Used only to push what is behind a popup back: paint it over the page the popup
-- covers, once (the lines add up if painted twice over the same pixels).
--
function Theme.hatchRect(bb, x, y, w, h)
  if w > 0 and h > 0 and bb.hatchRect then
    bb:hatchRect(x, y, w, h, math.max(1, px(2)), Blitbuffer.COLOR_BLACK, 0.25)
  end
end

--
-- A progress bar: no outline, a solid black fill over a light grey track, square at both
-- ends. It is information, so it never looks like a control; when it is tappable (it sets
-- the page) the line under it carries a chevron. A tick (opts.ticks, as ProgressWidget)
-- is a black notch drawn taller than the bar. opts: width, height, percentage, ticks, last.
--
function Theme.progress(opts)
  local ProgressWidget = require("ui/widget/progresswidget")
  local bar = ProgressWidget:new {
    width = opts.width,
    height = opts.height,
    percentage = opts.percentage,
    ticks = opts.ticks,
    last = opts.last,
    bordersize = 0,
    margin_h = 0,
    margin_v = 0,
  }
  function bar:paintTo(bb, x, y)
    local w, h = self.width, self.height
    self.dimen = Geom:new { x = x, y = y, w = w, h = h }
    local done = math.floor(w * math.max(0, math.min(1, self.percentage or 0)))
    bb:paintRect(x, y, w, h, Theme.MID)
    if done > 0 then bb:paintRect(x, y, done, h, Theme.BLACK) end
    if self.ticks and self.last and self.last > 0 then
      local notch = math.max(2, px(3))
      for _, t in ipairs(self.ticks) do
        bb:paintRect(x + math.floor(w * t / self.last) - math.floor(notch / 2), y - px(3), notch, h + px(6), Theme.BLACK)
      end
    end
  end
  return bar
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
-- The mark that says "this opens something": a chevron at the end of a tappable row or
-- heading. Always this icon, never a typed "›".
--
function Theme.chevron(size)
  return Theme.icon("chevron-right", size or px(24))
end

--
-- One line of text in the family's type: `size` a Theme.type name (default "body"), opts
-- { bold, serif, grey, width } (width is the most it may take; longer text is cut with an
-- ellipsis). `serif` is for the name of a thing (a title, a heading, a figure) and is already
-- bold; `bold` (sans) is for the label on a control.
--
function Theme.text(str, size, opts)
  opts = opts or {}
  local face, bold = Theme.face(size or "body"), opts.bold
  if opts.serif then face, bold = Theme.serif(size or "body") end
  return TextWidget:new {
    text = tostring(str),
    face = face,
    bold = bold,
    max_width = opts.width,
    fgcolor = opts.grey and Theme.DARK_GREY or Theme.BLACK,
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
-- A section heading: the words in bold with a firm rule beneath, so sections
-- read as chapters, with the room above to separate it from what came before.
-- `right` (a widget) is placed at the far end of the heading line (a count, a
-- small button).
--
function Theme.sectionHeader(text, width, right)
  -- a long heading is cut short (with an ellipsis) rather than pushing what is at the
  -- end of the line past the edge
  local room = right and math.max(0, width - right:getSize().w - Theme.space.m) or width
  local face, bold = Theme.serif("title")
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
      face = (Theme.serif("display")),
      bold = select(2, Theme.serif("display")),
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
-- A small tappable pill: the status you can change, a series that opens its search. It
-- has a border, so it is only for things that can be tapped; wrap it in a TapRow (or
-- Theme.touchable). `chevron` marks one that opens a list or picker; `filled` is the
-- selected/active look (black with white text).
--
function Theme.pill(text, opts)
  opts = opts or {}
  local filled = opts.filled
  local fg = filled and Theme.WHITE or Theme.BLACK
  local face = Theme.face(opts.size or "small")
  local word = TextWidget:new {
    text = text,
    face = face,
    bold = true,
    max_width = opts.max_width,
    fgcolor = fg,
  }
  local content = word
  if opts.chevron then
    content = HorizontalGroup:new {
      align = "center",
      word,
      HorizontalSpan:new { width = Theme.space.xs },
      Theme.icon("chevron-right", px(16)),
    }
  end
  return FrameContainer:new {
    bordersize = Theme.line.firm,
    color = Theme.BLACK,
    background = filled and Theme.BLACK or Theme.WHITE,
    radius = px(opts.radius or 14),
    padding = px(3),
    padding_left = Theme.space.m,
    padding_right = Theme.space.m,
    margin = 0,
    content,
  }
end

--
-- A pill you can tap, with a tap area of at least TOUCH_MIN tall (the pill itself stays
-- small). Returns a TapRow exactly as wide as the pill.
--
function Theme.tapPill(text, opts, callback, viewport)
  local pill = Theme.pill(text, opts)
  return Theme.touchable(pill, pill:getSize().w, callback, viewport)
end

--
-- A fact, as plain text: no border, no rounded ends, so it cannot be mistaken for
-- something to tap. Regular weight (bold is for the label on a control); `icon` (a bundled
-- icon name) goes before it; `grey` for the quieter look. opts: icon, grey, size (default
-- "small"), max_width.
--
function Theme.label(text, opts)
  opts = opts or {}
  local text_widget = TextWidget:new {
    text = text,
    face = Theme.face(opts.size or "small"),
    max_width = opts.max_width,
    fgcolor = opts.grey and Theme.DARK_GREY or Theme.BLACK,
  }
  if not opts.icon then return text_widget end
  return HorizontalGroup:new {
    align = "center",
    Theme.icon(opts.icon, Theme.px(18)),
    HorizontalSpan:new { width = Theme.space.xs },
    text_widget,
  }
end

--
-- A note on a screen (offline, out of date, nothing here yet): static information, so no
-- fill and no border; its words sit between two hairline rules.
--
function Theme.note(str, width)
  local TextBoxWidget = require("ui/widget/textboxwidget")
  return VerticalGroup:new {
    align = "left",
    Theme.rule(width, false),
    Theme.span("s"),
    TextBoxWidget:new { text = str, face = Theme.face("small"), width = width },
    Theme.span("s"),
    Theme.rule(width, false),
  }
end

--
-- A switch, for an option that is on or off: a small pill, black with the knob at the right
-- when on (active), white with a border and the knob at the left when off. `enabled` false
-- draws it in dark grey (the option is unavailable).
--
function Theme.switch(on, enabled)
  local Widget = require("ui/widget/widget")
  local w, h = px(52), px(30)
  local ink = (enabled == false) and Theme.DARK_GREY or Theme.BLACK
  local switch = Widget:new { dimen = Geom:new { w = w, h = h } }
  function switch:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local r, bs = math.floor(h / 2), Theme.line.firm
    bb:paintRoundedRect(x, y, w, h, ink, r)
    if not on then bb:paintRoundedRect(x + bs, y + bs, w - 2 * bs, h - 2 * bs, Theme.WHITE, r - bs) end
    local knob = r - bs - px(3)
    bb:paintCircle(on and (x + w - r) or (x + r), y + r, knob, on and Theme.WHITE or ink)
  end
  return switch
end

--
-- A radio mark, for one choice of several (the current status): a ring, with a solid centre
-- on the chosen one. A switch is for an option that stands alone; this is for a group where
-- only one is on. `enabled` false draws it in dark grey.
--
function Theme.radio(selected, enabled)
  local Widget = require("ui/widget/widget")
  local d = px(24)
  local ink = (enabled == false) and Theme.DARK_GREY or Theme.BLACK
  local radio = Widget:new { dimen = Geom:new { w = d, h = d } }
  function radio:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local r, bs = math.floor(d / 2), Theme.line.firm
    bb:paintCircle(x + r, y + r, r, ink, bs)
    if selected then bb:paintCircle(x + r, y + r, r - bs - px(3), ink) end
  end
  return radio
end

--
-- A bordered box of exactly w x h, with its child centred in it.
--
-- A FrameContainer paints at its `width`/`height` but REPORTS content plus
-- border to its parent, so a row of "w-wide" frames overflows the margin by
-- the borders and padding. Putting the child in a CenterContainer whose size is
-- the inside of the box makes the reported size the same as the painted one.
-- opts: filled (black with white text), border (px, default firm), round (a control: the
-- shared corner radius), chip (a full pill), wash (grey fill), color (border colour,
-- default black). With neither round nor chip it is square.
--
function Theme.box(w, h, child, opts)
  opts = opts or {}
  local bs = opts.border or Theme.line.firm
  return FrameContainer:new {
    bordersize = bs,
    radius = (opts.chip and math.floor(math.min(w, h) / 2)) or (opts.round and Theme.controlRadius(w, h)) or nil,
    padding = 0,
    margin = 0,
    width = w,
    height = h,
    color = opts.color or Theme.BLACK,
    background = opts.filled and Theme.BLACK or (opts.wash and Theme.WASH or Theme.WHITE),
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
  local size = child:getSize()
  local h = math.max(size.h, Theme.TOUCH_MIN)
  return TapRow:new {
    callback = callback,
    viewport = viewport,
    -- the child is the label: it flashes where it is drawn (LeftContainer centres it
    -- vertically, as the floor below)
    feedback = { x = 0, y = math.floor((h - size.h) / 2), w = size.w, h = size.h },
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
-- opts: filled, chevron, h, size (type name), callback, viewport (see viewport.lua: for buttons
-- inside a scroll area), enabled (false = grey fill, grey border and text, no tap), name.
--
function Theme.button(text, w, opts)
  opts = opts or {}
  local TapRow = require("hardcover/lib/ui/tap_row")
  local enabled = opts.enabled ~= false
  -- an unavailable button is grey, never black: black means active
  local filled = opts.filled and enabled
  -- a chevron says "opens a picker" (a button showing its current value); it is black, so it
  -- only goes on an available, unfilled button
  local chevron = (opts.chevron and enabled and not filled) and Theme.icon("chevron-right", px(18)) or nil
  local label = TextWidget:new {
    text = text,
    face = Theme.face(opts.size or "small"),
    bold = true,
    max_width = w - 2 * Theme.line.firm - Theme.space.s - (chevron and (chevron:getSize().w + Theme.space.xs) or 0),
    fgcolor = (filled and Theme.WHITE) or (enabled and Theme.BLACK or Theme.DARK_GREY),
  }
  local content = label
  if chevron then
    content = HorizontalGroup:new { align = "center", label, Theme.hspan("xs"), chevron }
  end
  local box = Theme.box(w, opts.h or Theme.BUTTON_H, content,
    { filled = filled, round = true, wash = not enabled, color = (not enabled) and Theme.DARK_GREY or nil })
  local tap = TapRow:new {
    callback = enabled and opts.callback or nil,
    viewport = opts.viewport,
    feedback = true, -- the whole button is its label
    box,
  }
  tap.label = label
  tap.text = text -- what the button says (also how a test finds it)
  tap.width = w
  return tap
end

--
-- The title bar every screen shares: the title centred, the close X at the right,
-- and no rule under it (the first section heading of the page draws the firm rule).
-- At the left, a screen opened from another has a Back arrow (`back_callback`: leave
-- this screen, the one beneath shows again); the root screen has its own icon there
-- instead (`left_icon` / `left_callback`, Home's settings).
-- The X always quits the plugin, from any screen (see quit.lua).
--
function Theme.titleBar(opts)
  local Quit = require("hardcover/lib/ui/quit")
  local face = Theme.serif("title")
  local left_icon, left_callback = opts.left_icon, opts.left_callback
  if opts.back_callback then
    left_icon, left_callback = "back.top", opts.back_callback
  end
  return TitleBar:new {
    title_face = face,
    width = opts.width or Screen:getWidth(),
    fullscreen = true,
    align = "center",
    title = opts.title,
    left_icon = left_icon,
    left_icon_tap_callback = left_callback,
    with_bottom_line = false,
    close_callback = function() Quit.run() end,
    show_parent = opts.show_parent,
  }
end

return Theme
