-- Pixel drawing the components share: a widget painted by a function, strokes, a tick, chevrons, the
-- small line icons, and the raster used for inactive things. Pure black on white; nothing here
-- uses a grey (the rule the MMD appendix sets for state: a fill, a check or a dotted line, never grey).

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")

local Theme = require("hardcover/lib/ui/theme")

local px = Theme.px
local BLACK = Blitbuffer.COLOR_BLACK

local Draw = {}

local function round(n) return math.floor(n + 0.5) end
Draw.round = round

-- A widget of w x h whose pixels are painted by fn(bb, x, y, w, h). Its position is recorded when it
-- paints, like any widget's, so a tap range can read it.
function Draw.drawn(w, h, fn)
  local widget = Widget:new { dimen = Geom:new { w = w, h = h } }
  function widget:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    fn(bb, x, y, w, h)
  end
  return widget
end

-- A line from (x1, y1) to (x2, y2), `t` thick, round-ended when thick enough to show it.
function Draw.stroke(bb, x1, y1, x2, y2, t, color)
  color = color or BLACK
  local dx, dy = x2 - x1, y2 - y1
  local n = math.max(math.abs(dx), math.abs(dy), 1)
  local r = math.floor(t / 2)
  for i = 0, n do
    local x = round(x1 + dx * i / n)
    local y = round(y1 + dy * i / n)
    if t >= 3 then
      bb:paintCircle(x, y, r, color)
    else
      bb:paintRect(x - r, y - r, t, t, color)
    end
  end
end

-- A dotted horizontal run `w` long and `t` thick: `on` black then `off` white, repeated.
function Draw.dottedH(bb, x, y, w, t, on, off)
  local i = 0
  while i < w do
    bb:paintRect(x + i, y, math.min(on, w - i), t, BLACK)
    i = i + on + off
  end
end

-- A dotted rounded outline: how an unavailable control is shown without grey.
function Draw.dottedBorder(bb, x, y, w, h, r, t, on, off)
  on, off = on or px(2), off or px(2)
  local x0, y0 = x + t / 2, y + t / 2
  local w2, h2 = w - t, h - t
  local rr = math.max(0, math.min(r - t / 2, w2 / 2, h2 / 2))
  local pts = {}
  local function add(a, b) pts[#pts + 1] = { a, b } end
  local function arc(cx, cy, a0, a1)
    local steps = math.max(1, math.floor(rr * math.abs(a1 - a0)))
    for i = 1, steps - 1 do
      local a = a0 + (a1 - a0) * i / steps
      add(cx + rr * math.cos(a), cy + rr * math.sin(a))
    end
  end
  for xx = x0 + rr, x0 + w2 - rr do add(xx, y0) end
  arc(x0 + w2 - rr, y0 + rr, -math.pi / 2, 0)
  for yy = y0 + rr, y0 + h2 - rr do add(x0 + w2, yy) end
  arc(x0 + w2 - rr, y0 + h2 - rr, 0, math.pi / 2)
  for xx = x0 + w2 - rr, x0 + rr, -1 do add(xx, y0 + h2) end
  arc(x0 + rr, y0 + h2 - rr, math.pi / 2, math.pi)
  for yy = y0 + h2 - rr, y0 + rr, -1 do add(x0, yy) end
  arc(x0 + rr, y0 + rr, math.pi, 3 * math.pi / 2)
  local period = on + off
  local count = math.max(1, round(#pts / period))
  local p = #pts / count
  local on_len = p * on / period
  for i, pt in ipairs(pts) do
    if ((i - 1) % p) < on_len then
      bb:paintRect(round(pt[1] - t / 2), round(pt[2] - t / 2), t, t, BLACK)
    end
  end
end

-- The "inactive" raster: single black pixels on a grid of twice the hairline, white between.
function Draw.raster(bb, x, y, w, h)
  local cell = Theme.line.hair
  local pitch = 2 * cell
  for yy = 0, h - 1, pitch do
    for xx = 0, w - 1, pitch do
      bb:paintRect(x + xx, y + yy, math.min(cell, w - xx), math.min(cell, h - yy), BLACK)
    end
  end
end

-- A tick inside a `size` square.
function Draw.paintCheck(bb, x, y, size, t, color)
  local a = { x + size * 0.08, y + size * 0.55 }
  local b = { x + size * 0.38, y + size * 0.85 }
  local c = { x + size * 0.92, y + size * 0.15 }
  Draw.stroke(bb, a[1], a[2], b[1], b[2], t, color)
  Draw.stroke(bb, b[1], b[2], c[1], c[2], t, color)
end

function Draw.check(size, t, color)
  return Draw.drawn(size, size, function(bb, x, y)
    Draw.paintCheck(bb, x, y, size, t or Theme.line.firm, color or BLACK)
  end)
end

-- A chevron in a w x h box pointing `dir` (right, up or down).
function Draw.paintChevron(bb, x, y, w, h, dir, t, color)
  color = color or BLACK
  local m = math.floor(t / 2) + 1
  if dir == "right" then
    Draw.stroke(bb, x + m, y + m, x + w - m, y + h / 2, t, color)
    Draw.stroke(bb, x + w - m, y + h / 2, x + m, y + h - m, t, color)
  elseif dir == "up" then
    Draw.stroke(bb, x + m, y + h - m, x + w / 2, y + m, t, color)
    Draw.stroke(bb, x + w / 2, y + m, x + w - m, y + h - m, t, color)
  else
    Draw.stroke(bb, x + m, y + m, x + w / 2, y + h - m, t, color)
    Draw.stroke(bb, x + w / 2, y + h - m, x + w - m, y + m, t, color)
  end
end

function Draw.chevron(dir, t)
  local w, h = px(10), px(18)
  if dir ~= "right" then w, h = px(18), px(10) end
  return Draw.drawn(w, h, function(bb, x, y) Draw.paintChevron(bb, x, y, w, h, dir, t or px(2.5), BLACK) end)
end

-- The line icons the bars use, drawn in a square `s`.
local ICONS = {}
function ICONS.back(bb, x, y, s, t)
  Draw.stroke(bb, x + s * 0.88, y + s * 0.5, x + s * 0.12, y + s * 0.5, t)
  Draw.stroke(bb, x + s * 0.45, y + s * 0.15, x + s * 0.1, y + s * 0.5, t)
  Draw.stroke(bb, x + s * 0.45, y + s * 0.85, x + s * 0.1, y + s * 0.5, t)
end
function ICONS.close(bb, x, y, s, t)
  Draw.stroke(bb, x + s * 0.2, y + s * 0.2, x + s * 0.8, y + s * 0.8, t)
  Draw.stroke(bb, x + s * 0.8, y + s * 0.2, x + s * 0.2, y + s * 0.8, t)
end
function ICONS.search(bb, x, y, s, t)
  bb:paintCircle(x + round(s * 0.42), y + round(s * 0.42), round(s * 0.3), BLACK, t)
  Draw.stroke(bb, x + s * 0.64, y + s * 0.64, x + s * 0.9, y + s * 0.9, t)
end
function ICONS.sort(bb, x, y, s, t)
  Draw.stroke(bb, x + s * 0.12, y + s * 0.26, x + s * 0.88, y + s * 0.26, t)
  Draw.stroke(bb, x + s * 0.26, y + s * 0.5, x + s * 0.74, y + s * 0.5, t)
  Draw.stroke(bb, x + s * 0.4, y + s * 0.74, x + s * 0.6, y + s * 0.74, t)
end
function ICONS.info(bb, x, y, s, t)
  bb:paintCircle(x + round(s / 2), y + round(s / 2), round(s * 0.45), BLACK, t)
  bb:paintRect(x + round(s / 2) - 1, y + round(s * 0.42), math.max(2, t), round(s * 0.28), BLACK)
  bb:paintRect(x + round(s / 2) - 1, y + round(s * 0.26), math.max(2, t), math.max(2, t), BLACK)
end
Draw.ICONS = ICONS

-- A named icon at `size` (default 28). The touch area is the caller's business.
function Draw.icon(name, size)
  size = size or px(28)
  local paint = ICONS[name]
  return Draw.drawn(size, size, function(bb, x, y) paint(bb, x, y, size, px(2.5)) end)
end

return Draw
