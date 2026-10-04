-- Charts for an e-ink page: columns, a histogram with a marker, horizontal bars, a donut with
-- its legend, and a row of key figures. Drawn straight onto the screen buffer from the
-- arithmetic in hardcover/lib/charts.lua.
--
-- What the drawing follows (it is a chart for a mono panel, and for any library):
--   * Black and a few greys that stay apart on the panel, never a light tint that washes out;
--     the biggest or the chosen mark is the darkest.
--   * Thin marks: columns at most a finger wide with a rounded top, a 2px gap between slices of
--     a ring, hairline gridlines that recede behind the data.
--   * Labels are sparing: the peak and the chosen column, the scale on the left, a few ticks
--     along the bottom. Text is always black or dark grey, never a grey of its own.
--   * Nothing is cut off: a label that does not fit is shortened with an ellipsis or dropped.
--   * Each widget has a fixed height, so a page built from them does not move when data arrives.
--
-- They are plain widgets (paintTo), so they scroll with the page they are in.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")

local Charts = require("hardcover/lib/charts")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local ChartWidgets = {}

local function px(n) return Theme.px(n) end

local function grey(level) return Blitbuffer.Color8(level) end
local WHITE = Blitbuffer.COLOR_WHITE
local BLACK = Blitbuffer.COLOR_BLACK
local GRIDLINE = 0xD8

-- a widget that paints with a function: draw(bb, x, y, w, h)
local Canvas = Widget:extend { width = 0, height = 0, draw = nil, on_free = nil }

function Canvas:init()
  self.dimen = Geom:new { x = 0, y = 0, w = self.width, h = self.height }
end

function Canvas:getSize()
  return Geom:new { w = self.width, h = self.height }
end

function Canvas:paintTo(bb, x, y)
  self.dimen.x, self.dimen.y = x, y
  if self.draw then self.draw(bb, x, y, self.width, self.height) end
end

function Canvas:free()
  if self.on_free then self.on_free() end
end

local function text(str, size, opts)
  opts = opts or {}
  return TextWidget:new {
    text = tostring(str),
    face = Theme.face(size or "label"),
    bold = opts.bold,
    max_width = opts.width,
    fgcolor = opts.grey and Theme.DARK_GREY or Theme.BLACK,
  }
end

-- draw text at x (its left, or centred on x, or right-aligned to x), top at y
local function put(bb, tw, x, y, align)
  local w = tw:getSize().w
  if align == "center" then x = x - math.floor(w / 2) elseif align == "right" then x = x - w end
  tw:paintTo(bb, x, y)
end

-- A column with a rounded top and a square base: the rounded rectangle runs on below the
-- baseline and the base row is painted over in the surface colour.
local function column(bb, x, base_y, w, h, level)
  local r = math.min(px(4), math.floor(w / 2))
  if h <= 2 * r then
    bb:paintRect(x, base_y - h, w, h, grey(level))
    return
  end
  bb:paintRoundedRect(x, base_y - h, w, h + r, grey(level), r)
  bb:paintRect(x, base_y, w, r + 1, WHITE)
end

--
-- A column chart.
--   width, height     the size of the whole chart, labels included
--   values            one number per column
--   labels            { [index] = "Jan" } along the bottom (the ones that fit are drawn)
--   highlight         the column to stand out (it, and the tallest, get their value drawn)
--   emphasis          true: every other column is a mid grey so the highlight is the story
--   marker            { at = 4.28, text = "avg 4.3" }: a pointer above the columns at a position
--                     in column units (1 = the first column's centre)
--   max               force the top of the scale (charts that are compared share one)
--   value_text        function(value) -> string for the drawn values (default: with commas)
--
function ChartWidgets.columns(opts)
  local values = opts.values or {}
  local width, height = opts.width, opts.height
  local small = "label"
  local sample = text("0", small)
  local text_h = sample:getSize().h
  local top_pad = text_h + px(6) -- room for the value on top of the tallest column
  local bottom = text_h + px(10) -- the labels under the baseline
  local plot_h = math.max(px(40), height - top_pad - bottom)

  -- the scale's labels set the left margin
  local biggest = 0
  for _, v in ipairs(values) do if (tonumber(v) or 0) > biggest then biggest = tonumber(v) end end
  local scale_top = Charts.niceScale(opts.max or biggest)
  local axis_w = text(Charts.number(scale_top), small):getSize().w + px(8)
  local plot_w = width - axis_w
  local cols, top, ticks = Charts.columns(values, plot_w, plot_h, { max_col = px(30), gap = px(4), max = opts.max })

  local function show(v) return opts.value_text and opts.value_text(v) or Charts.number(v) end
  local peak, peak_v = nil, 0
  for i, c in ipairs(cols) do if c.value > peak_v then peak, peak_v = i, c.value end end

  -- which labels along the bottom fit: every k-th, always the highlighted one
  local widest = 0
  for _, label in pairs(opts.labels or {}) do
    widest = math.max(widest, text(label, small):getSize().w)
  end
  local per = #cols > 0 and plot_w / #cols or plot_w
  local every = math.max(1, math.ceil((widest + px(8)) / math.max(1, per)))

  local cache = {}
  local function tw(str)
    cache[str] = cache[str] or text(str, small)
    return cache[str]
  end
  local grey_text = {}
  local function dim(str)
    grey_text[str] = grey_text[str] or text(str, small, { grey = true })
    return grey_text[str]
  end

  return Canvas:new {
    width = width, height = height,
    draw = function(bb, x, y)
      local base_y = y + top_pad + plot_h
      local plot_x = x + axis_w

      -- gridlines and the scale: recessive, behind the data
      for _, t in ipairs(ticks) do
        if t.value > 0 then
          bb:paintRect(plot_x, base_y - t.y, plot_w, math.max(1, Theme.line.hair), grey(GRIDLINE))
        end
        local label = dim(Charts.number(t.value))
        put(bb, label, x + axis_w - px(6), base_y - t.y - math.floor(label:getSize().h / 2), "right")
      end

      for i, c in ipairs(cols) do
        local level = 0x00
        if opts.emphasis and opts.highlight and i ~= opts.highlight then level = 0x77 end
        if c.h > 0 then column(bb, plot_x + c.x, base_y, c.w, c.h, level) end
        if c.value > 0 and (i == peak or i == opts.highlight) then
          local label = tw(show(c.value))
          put(bb, label, plot_x + c.x + math.floor(c.w / 2), base_y - c.h - label:getSize().h - px(3), "center")
        end
      end

      bb:paintRect(plot_x, base_y, plot_w, Theme.line.firm, BLACK)

      for i, label in pairs(opts.labels or {}) do
        local c = cols[i]
        if c and ((i - 1) % every == 0 or i == opts.highlight) then
          put(bb, dim(label), plot_x + c.x + math.floor(c.w / 2), base_y + px(6), "center")
        end
      end

      -- a pointer at a position along the columns, with its words
      if opts.marker and cols[1] then
        local first, last = cols[1], cols[#cols]
        local step = #cols > 1 and (last.x - first.x) / (#cols - 1) or 0
        local mx = plot_x + first.x + math.floor(first.w / 2) + math.floor((opts.marker.at - 1) * step)
        local tip = base_y - plot_h - px(2)
        for row = 0, px(5) do
          bb:paintRect(mx - (px(5) - row), tip - px(6) + row, 2 * (px(5) - row) + 1, 1, BLACK)
        end
        if opts.marker.text then
          local label = tw(opts.marker.text)
          local lx = mx + px(10)
          if lx + label:getSize().w > x + width then lx = mx - px(10) - label:getSize().w end
          put(bb, label, lx, tip - px(6) - 2)
        end
      end
    end,
  }
end

--
-- Horizontal bars, one row each: the name on the left (cut to fit), the bar, the number at its
-- tip. `rows` are { label, value, text } (`text` is what is written at the tip, default the
-- value). The longest bar is black, the rest dark grey.
--
function ChartWidgets.bars(opts)
  local rows = opts.rows or {}
  local width = opts.width
  local sample = text("Ag", "small")
  local row_h = math.max(sample:getSize().h, px(18)) + px(10)
  local bar_h = math.min(px(16), row_h - px(10))
  local label_w = math.floor(width * (opts.label_fraction or 0.38))
  local value_w = text(Charts.number(1000000), "small"):getSize().w
  local bar_room = width - label_w - value_w - px(14)
  local values = {}
  for i, row in ipairs(rows) do values[i] = row.value end
  local lengths = Charts.bars(values, bar_room, px(3))

  local labels, tips = {}, {}
  for i, row in ipairs(rows) do
    labels[i] = text(row.label or "", "small", { width = label_w - px(8) })
    tips[i] = text(row.text or Charts.number(row.value), "small", { bold = true })
  end

  return Canvas:new {
    width = width, height = math.max(1, #rows) * row_h,
    draw = function(bb, x, y)
      for i = 1, #rows do
        local top = y + (i - 1) * row_h
        local mid = top + math.floor(row_h / 2)
        put(bb, labels[i], x, mid - math.floor(labels[i]:getSize().h / 2))
        local len = lengths[i]
        local bx = x + label_w
        local level = i == 1 and 0x00 or 0x55
        if len > 0 then
          local r = math.min(px(4), math.floor(bar_h / 2))
          bb:paintRoundedRect(bx - r, mid - math.floor(bar_h / 2), len + r, bar_h, grey(level), r)
          bb:paintRect(bx - r, mid - math.floor(bar_h / 2), r, bar_h, WHITE)
        end
        put(bb, tips[i], bx + len + px(8), mid - math.floor(tips[i]:getSize().h / 2))
      end
    end,
  }
end

--
-- A donut with its legend beside it (or under it when the page is narrow).
--   slices      from Charts.slices (biggest first, Other last)
--   center      { top = "612", bottom = "books" } written in the hole
-- The legend lists each slice: a swatch in the slice's grey, its name, its share.
--
function ChartWidgets.donut(opts)
  local slices = Charts.arcs(opts.slices or {})
  local width = opts.width
  local wide = width >= px(520)
  local d = wide and math.min(math.floor(width * 0.42), px(260)) or math.min(width, px(240))
  local outer = d / 2
  local inner = outer * 0.58
  local gap = px(3)

  -- the ring is drawn once into its own buffer: working out every pixel of it on each repaint
  -- would make the page stutter as it scrolls
  local ring
  local function build()
    ring = Blitbuffer.new(d, d, Screen.bb and Screen.bb:getType())
    ring:fill(WHITE)
    local cx, cy = d / 2, d / 2
    for row = 0, d - 1 do
      local dy = row + 0.5 - cy
      local run_from, run_index
      for col = 0, d do
        local index = col < d and Charts.sliceAtGap(slices, col + 0.5 - cx, dy, inner, outer, gap) or nil
        if index ~= run_index then
          if run_index then ring:paintRect(run_from, row, col - run_from, 1, grey(Charts.shade(run_index))) end
          run_from, run_index = col, index
        end
      end
    end
  end

  local hole_top = opts.center and opts.center.top and text(opts.center.top, "display", { bold = true })
  local hole_bottom = opts.center and opts.center.bottom and text(opts.center.bottom, "small", { grey = true })

  local donut = Canvas:new {
    width = d, height = d,
    draw = function(bb, x, y)
      if #slices == 0 then return end
      if not ring then build() end
      bb:blitFrom(ring, x, y, 0, 0, d, d)
      if hole_top then
        local th = hole_top:getSize().h + (hole_bottom and hole_bottom:getSize().h or 0)
        put(bb, hole_top, x + d / 2, y + math.floor((d - th) / 2), "center")
        if hole_bottom then
          put(bb, hole_bottom, x + d / 2, y + math.floor((d - th) / 2) + hole_top:getSize().h, "center")
        end
      end
    end,
    on_free = function() if ring then ring:free(); ring = nil end end,
  }

  -- the legend
  local legend_w = wide and (width - d - Theme.space.l) or width
  local line_h = math.max(text("Ag", "small"):getSize().h, px(18)) + px(10)
  local swatch = px(16)
  local names, shares = {}, {}
  for i, s in ipairs(slices) do
    shares[i] = text(string.format("%d%%", s.percent), "small", { bold = true })
    names[i] = text(s.label or "", "small", { width = legend_w - swatch - shares[i]:getSize().w - px(24) })
  end
  local legend = Canvas:new {
    width = legend_w, height = math.max(1, #slices) * line_h,
    draw = function(bb, x, y)
      for i, s in ipairs(slices) do
        local top = y + (i - 1) * line_h
        local mid = top + math.floor(line_h / 2)
        bb:paintRect(x, mid - math.floor(swatch / 2), swatch, swatch, grey(Charts.shade(i)))
        -- the lightest swatches get a hairline so they are not lost against the paper
        if Charts.shade(i) >= 0x99 then bb:paintBorder(x, mid - math.floor(swatch / 2), swatch, swatch, 1, BLACK, 0) end
        put(bb, names[i], x + swatch + px(10), mid - math.floor(names[i]:getSize().h / 2))
        put(bb, shares[i], x + legend_w, mid - math.floor(shares[i]:getSize().h / 2), "right")
      end
    end,
  }

  if wide then
    -- the legend is centred beside the ring
    local pad = math.max(0, math.floor((d - legend.height) / 2))
    return HorizontalGroup:new {
      align = "top",
      donut,
      Theme.hspan(Theme.space.l),
      VerticalGroup:new { align = "left", Theme.span(pad), legend },
    }
  end
  return VerticalGroup:new {
    align = "center",
    donut,
    Theme.span("m"),
    legend,
  }
end

--
-- A row of key figures (up to three across, more wrap): the number big and bold, what it
-- counts under it. `tiles` are { value, label }.
--
function ChartWidgets.kpis(opts)
  local tiles = opts.tiles or {}
  local per_row = math.min(opts.per_row or 3, math.max(1, #tiles))
  local gap = Theme.space.m
  local w = math.floor((opts.width - (per_row - 1) * gap) / per_row)
  local h = px(opts.height or 88)
  local group = VerticalGroup:new { align = "left" }
  for i = 1, #tiles, per_row do
    local row = HorizontalGroup:new {}
    for j = i, math.min(i + per_row - 1, #tiles) do
      if j > i then table.insert(row, Theme.hspan(gap)) end
      local tile = tiles[j]
      local inner = w - 2 * Theme.line.firm - Theme.space.m
      table.insert(row, Theme.box(w, h, VerticalGroup:new {
        align = "center",
        text(tile.value, "display", { bold = true, width = inner }),
        text(tile.label, "small", { grey = true, width = inner }),
      }, { radius = 10 }))
    end
    table.insert(group, row)
    if i + per_row <= #tiles then table.insert(group, Theme.span("m")) end
  end
  return group
end

ChartWidgets.Canvas = Canvas

return ChartWidgets
