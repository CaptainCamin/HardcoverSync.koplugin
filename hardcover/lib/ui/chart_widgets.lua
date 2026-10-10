-- Charts for an e-ink page: columns, a histogram with a marker, horizontal bars (black, or stepping
-- from black to light), a donut with its legend, a line for a running total, a strip of ticks for a
-- spread, and a row of key figures. Drawn straight onto the screen buffer from the
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
local OverlapGroup = require("ui/widget/overlapgroup")
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

-- (the charts' own small type is the default; Lato like the rest of the page, Black where bold)
local function text(str, size, opts)
  opts = opts or {}
  return Theme.mmdText(str, opts.bold and "strong" or "text", Theme.type[size or "label"] or size,
    { width = opts.width, secondary = opts.grey })
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
  local grey_text, strong_text = {}, {}
  local function dim(str)
    grey_text[str] = grey_text[str] or text(str, small, { grey = true })
    return grey_text[str]
  end
  local function strong(str)
    strong_text[str] = strong_text[str] or text(str, small, { bold = true })
    return strong_text[str]
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

      -- where the marker points (its position and words), worked out first: a dashed line
      -- runs behind the columns and no value is written over its words
      local marker
      if opts.marker and cols[1] then
        local first, last = cols[1], cols[#cols]
        local step = #cols > 1 and (last.x - first.x) / (#cols - 1) or 0
        local mx = plot_x + first.x + math.floor(first.w / 2) + math.floor((opts.marker.at - 1) * step)
        local tip = base_y - plot_h - px(2)
        marker = { x = mx, tip = tip }
        if opts.marker.text then
          local label = tw(opts.marker.text)
          local lx = mx + px(10)
          if lx + label:getSize().w > x + width then lx = mx - px(10) - label:getSize().w end
          marker.label, marker.lx = label, lx
        end
        local dash = px(6)
        for yy = tip, base_y - dash, 2 * dash do
          bb:paintRect(mx, yy, math.max(1, Theme.line.hair), dash, grey(0x88))
        end
      end

      for i, c in ipairs(cols) do
        local level = 0x00
        if opts.emphasis and opts.highlight and i ~= opts.highlight then level = 0x77 end
        if c.h > 0 then column(bb, plot_x + c.x, base_y, c.w, c.h, level) end
        if c.value > 0 and (i == peak or i == opts.highlight) then
          local label = (i == opts.highlight and opts.emphasis) and strong(show(c.value)) or tw(show(c.value))
          local cx = plot_x + c.x + math.floor(c.w / 2)
          local clash = marker and marker.label
            and cx + math.floor(label:getSize().w / 2) + px(4) > marker.lx
            and cx - math.floor(label:getSize().w / 2) - px(4) < marker.lx + marker.label:getSize().w
          if not clash then
            put(bb, label, cx, base_y - c.h - label:getSize().h - px(3), "center")
          end
        end
      end

      bb:paintRect(plot_x, base_y, plot_w, Theme.line.firm, BLACK)

      for i, label in pairs(opts.labels or {}) do
        local c = cols[i]
        if c and ((i - 1) % every == 0 or i == opts.highlight) then
          -- the chosen column's label is Black and bold, the others quiet
          put(bb, i == opts.highlight and opts.emphasis and strong(label) or dim(label),
            plot_x + c.x + math.floor(c.w / 2), base_y + px(6), "center")
        end
      end

      -- the pointer and its words, over everything
      if marker then
        for row = 0, px(5) do
          bb:paintRect(marker.x - (px(5) - row), marker.tip - px(6) + row, 2 * (px(5) - row) + 1, 1, BLACK)
        end
        if marker.label then put(bb, marker.label, marker.lx, marker.tip - px(6) - 2) end
      end
    end,
  }
end

--
-- Horizontal bars, one row each: the name on the left (cut to fit), the bar, the number at its
-- tip. `rows` are { label, value, text } (`text` is what is written at the tip, default the
-- value). The longest bar is black, the rest dark grey; with `tonal` each row is a step lighter than
-- the one above (rows biggest first), the lightest edged with a hairline so it is not lost on the
-- paper, and the figure at the tip stays black so the value never depends on the grey.
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
        local level = opts.tonal and Charts.ramp(i) or (i == 1 and 0x00 or 0x55)
        if len > 0 then
          local r = math.min(px(4), math.floor(bar_h / 2))
          local top = mid - math.floor(bar_h / 2)
          if opts.tonal and level >= 0x99 then
            -- the hairline edge: a black bar with the grey inset in it
            bb:paintRoundedRect(bx - r, top, len + r, bar_h, BLACK, r)
            bb:paintRoundedRect(bx - r + Theme.line.hair, top + Theme.line.hair, len + r - 2 * Theme.line.hair,
              bar_h - 2 * Theme.line.hair, grey(level), math.max(0, r - Theme.line.hair))
          else
            bb:paintRoundedRect(bx - r, top, len + r, bar_h, grey(level), r)
          end
          bb:paintRect(bx - r, top, r, bar_h, WHITE)
        end
        put(bb, tips[i], bx + len + px(8), mid - math.floor(tips[i]:getSize().h / 2))
      end
    end,
  }
end

--
-- A donut with its legend beside it (or under it when the page is narrow).
--   slices      from Charts.slices (biggest first, Other last)
--   center      { top = "38%", bottom = "Fantasy" } written in the hole
-- Each slice steps one grey lighter than the one before (Charts.ramp, Other the lightest), a gap of
-- paper between slices; the legend lists a swatch in the slice's grey, its name and its share in
-- black, so no figure depends on the grey.
--
function ChartWidgets.donut(opts)
  local slices = Charts.arcs(opts.slices or {})
  local width = opts.width
  local wide = width >= px(520)
  local d = wide and math.min(math.floor(width * 0.42), px(260)) or math.min(width, px(240))
  local outer = d / 2
  local inner = outer * 0.58
  local gap = px(3)
  local function level(i) return Charts.ramp(i) end

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
          if run_index then ring:paintRect(run_from, row, col - run_from, 1, grey(level(run_index))) end
          run_from, run_index = col, index
        end
      end
    end
  end

  local hole_w = math.floor(inner * 2 - px(16))
  local hole_top = opts.center and opts.center.top and Theme.mmdText(opts.center.top, "strong", 32, { width = hole_w })
  local hole_bottom = opts.center and opts.center.bottom and text(opts.center.bottom, "small", { grey = true, width = hole_w })

  local donut = Canvas:new {
    width = d, height = d,
    draw = function(bb, x, y)
      if #slices == 0 then return end
      if not ring then build() end
      bb:blitFrom(ring, x, y, 0, 0, d, d)
      if hole_top then
        local th = hole_top:getSize().h + (hole_bottom and hole_bottom:getSize().h or 0)
        local top = y + math.floor((d - th) / 2)
        put(bb, hole_top, x + d / 2, top, "center")
        if hole_bottom then put(bb, hole_bottom, x + d / 2, top + hole_top:getSize().h, "center") end
      end
    end,
    on_free = function() if ring then ring:free(); ring = nil end end,
  }

  -- the legend
  local legend_w = wide and (width - d - Theme.space.l) or width
  local line_h = math.max(text("Ag", "small"):getSize().h, px(18)) + px(14)
  local swatch = px(18)
  local names, shares = {}, {}
  for i, s in ipairs(slices) do
    -- a sliver under one percent is still on the list
    shares[i] = text(s.percent == 0 and "<1%" or string.format("%d%%", s.percent), "small", { bold = true })
    names[i] = text(s.label or "", "small", { width = legend_w - swatch - shares[i]:getSize().w - px(24) })
  end
  local legend = Canvas:new {
    width = legend_w, height = math.max(1, #slices) * line_h,
    draw = function(bb, x, y)
      for i = 1, #slices do
        local mid = y + (i - 1) * line_h + math.floor(line_h / 2)
        local sy = mid - math.floor(swatch / 2)
        bb:paintRoundedRect(x, sy, swatch, swatch, grey(level(i)), px(3))
        -- the lightest swatches get a hairline so they are not lost against the paper
        if level(i) >= 0x99 then bb:paintBorder(x, sy, swatch, swatch, Theme.line.hair, BLACK, px(3)) end
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
  return VerticalGroup:new { align = "center", donut, Theme.span("m"), legend }
end

--
-- A line for a running total (books so far this year). One point per month along twelve slots, so a
-- year not yet over stops where it has got to; the end point is a big dot with its figure.
--   width, height     the whole chart, labels included
--   values            the running total, one per month so far
--   slots             how many months the axis runs (12)
--   labels            { [index] = "J" } along the bottom
--
function ChartWidgets.line(opts)
  local values = opts.values or {}
  local width, height = opts.width, opts.height
  local slots = opts.slots or math.max(#values, 1)
  local small = "label"
  local text_h = text("0", small):getSize().h
  local top_pad = text_h + px(10)
  local bottom = text_h + px(10)
  local plot_h = math.max(px(40), height - top_pad - bottom)
  local scale_top, step = Charts.niceScale(values[#values] or 0)
  local axis_w = text(Charts.number(scale_top), small):getSize().w + px(8)
  local plot_w = width - axis_w
  local slot = plot_w / slots
  local function px_x(i) return math.floor((i - 0.5) * slot) end
  local function px_y(v) return math.floor(v / scale_top * plot_h + 0.5) end

  local widest = 0
  for _, label in pairs(opts.labels or {}) do widest = math.max(widest, text(label, small):getSize().w) end
  local every = math.max(1, math.ceil((widest + px(8)) / math.max(1, slot)))
  local dim = {}
  local function quiet(str)
    dim[str] = dim[str] or text(str, small, { grey = true })
    return dim[str]
  end
  local last_label = #values > 0 and text(Charts.number(values[#values]), small, { bold = true }) or nil
  local thick = px(3)

  return Canvas:new {
    width = width, height = height,
    draw = function(bb, x, y)
      local base_y = y + top_pad + plot_h
      local plot_x = x + axis_w
      for v = 0, scale_top, step do
        if v > 0 then bb:paintRect(plot_x, base_y - px_y(v), plot_w, math.max(1, Theme.line.hair), grey(GRIDLINE)) end
        local label = quiet(Charts.number(v))
        put(bb, label, x + axis_w - px(6), base_y - px_y(v) - math.floor(label:getSize().h / 2), "right")
      end
      bb:paintRect(plot_x, base_y, plot_w, Theme.line.firm, BLACK)

      -- the line: every pixel column filled from one point's height to the next, so a steep month has no holes
      for i = 2, #values do
        local x0, x1 = px_x(i - 1), px_x(i)
        local y0, y1 = px_y(values[i - 1]), px_y(values[i])
        for xx = x0, x1 do
          local t = (xx - x0) / math.max(1, x1 - x0)
          local from = y0 + (y1 - y0) * t
          local to = y0 + (y1 - y0) * math.min(1, (xx + 1 - x0) / math.max(1, x1 - x0))
          local lo, hi = math.min(from, to), math.max(from, to)
          bb:paintRect(plot_x + xx, base_y - math.floor(hi + 0.5) - math.floor(thick / 2), 1,
            math.floor(hi - lo + 0.5) + thick, BLACK)
        end
      end
      for i = 1, #values do
        local last = i == #values
        local cx, cy = plot_x + px_x(i), base_y - px_y(values[i])
        local r = last and px(7) or px(4)
        bb:paintCircle(cx, cy, r, BLACK)
        if not last then bb:paintCircle(cx, cy, math.max(1, r - px(2)), WHITE) end
      end
      if last_label then
        local cx, cy = plot_x + px_x(#values), base_y - px_y(values[#values])
        local lx = math.min(cx, x + width - math.floor(last_label:getSize().w / 2))
        put(bb, last_label, lx, cy - px(7) - last_label:getSize().h - px(3), "center")
      end

      for i, label in pairs(opts.labels or {}) do
        if (i - 1) % every == 0 or i == #values then
          put(bb, quiet(label), plot_x + px_x(i), base_y + px(6), "center")
        end
      end
    end,
  }
end

--
-- How long things run, as a range: a line from the shortest to the biggest, a thick black bar over
-- the stretch where half of them lie (the middle half), a pointer for the average above it and the
-- two ends written under. Fixed height, whatever the number of values.
--   values            the numbers (any order)
--   average           where the pointer goes
--   unit              what is written after an end figure ("pages")
--
function ChartWidgets.spread(opts)
  local values = opts.values or {}
  local width = opts.width
  local pad = px(6)
  local strip_w = width - 2 * pad
  local _, lo, hi, avg_at = Charts.positions(values, strip_w, opts.average)
  local quarter = Charts.quartiles(values)
  local small = "label"
  local text_h = text("0", small):getSize().h
  local bar_h = px(18)
  local pointer_h = px(10)
  local top_pad = text_h + pointer_h + px(10)
  local height = top_pad + bar_h + px(10) + text_h

  local function end_label(v, bold)
    return text(Charts.number(v) .. (opts.unit and (" " .. opts.unit) or ""), small, { bold = bold })
  end
  local avg_label = opts.average and text(string.format(opts.average_text or "avg %s", Charts.number(opts.average)), small) or nil
  local lo_label = lo and end_label(lo, true) or nil
  local hi_label = hi and hi ~= lo and end_label(hi, true) or nil

  return Canvas:new {
    width = width, height = height,
    draw = function(bb, x, y)
      if not lo or not quarter then return end
      local mid = y + top_pad + math.floor(bar_h / 2)
      local function at(v) return x + pad + Charts.positions({ lo, hi, v }, strip_w)[3] end
      -- the whole range as a line with an upright at each end
      local line = Theme.line.firm
      bb:paintRect(x + pad, mid - math.floor(line / 2), strip_w, line, BLACK)
      for _, ex in ipairs({ x + pad, x + pad + strip_w - line }) do
        bb:paintRect(ex, mid - math.floor(bar_h / 2), line, bar_h, BLACK)
      end
      -- the middle half
      local from, to = at(quarter[1]), at(quarter[3])
      local r = math.floor(bar_h / 2)
      if to - from < 2 * r then to = from + 2 * r end
      bb:paintRoundedRect(from, mid - r, to - from, bar_h, BLACK, r)
      -- the average, a pointer onto the bar with its words
      if avg_at then
        local mx = x + pad + avg_at
        local tip = y + top_pad - px(3)
        for row = 0, pointer_h - 1 do
          bb:paintRect(mx - (pointer_h - 1 - row), tip - pointer_h + row, 2 * (pointer_h - 1 - row) + 1, 1, BLACK)
        end
        local lx = math.max(x, math.min(mx - math.floor(avg_label:getSize().w / 2), x + width - avg_label:getSize().w))
        avg_label:paintTo(bb, lx, tip - pointer_h - avg_label:getSize().h - px(2))
      end
      lo_label:paintTo(bb, x, y + top_pad + bar_h + px(10))
      if hi_label then hi_label:paintTo(bb, x + width - hi_label:getSize().w, y + top_pad + bar_h + px(10)) end
    end,
  }
end

--
-- A row of key figures (mock 8): the number big and Black, what it counts under it in secondary text,
-- split by dotted rules. No boxes; the next section's own rule closes the row. `tiles` are { value, label }; up to
-- three across, more wrap.
--
function ChartWidgets.kpis(opts)
  local tiles = opts.tiles or {}
  local per_row = math.min(opts.per_row or 3, math.max(1, #tiles))
  local w = math.floor(opts.width / per_row)
  local pad = Theme.px(14)
  local group = VerticalGroup:new { align = "left" }
  for i = 1, #tiles, per_row do
    local row = HorizontalGroup:new { align = "top" }
    local row_h
    for j = i, math.min(i + per_row - 1, #tiles) do
      local first = j == i
      local tile = tiles[j]
      local cell_w = (j == i + per_row - 1 or j == #tiles) and (opts.width - (j - i) * w) or w
      local inner = cell_w - (first and 0 or pad)
      local figure = VerticalGroup:new {
        align = "left",
        Theme.mmdText(tile.value, "strong", 32, { width = inner }),
        Theme.mmdText(tile.label, "text", 18, { secondary = true, width = inner }),
      }
      row_h = row_h or (figure:getSize().h + Theme.space.m)
      local cell = Canvas:new { width = cell_w, height = row_h, draw = function(bb, x, y)
        if not first then
          local t = Theme.line.hair
          for yy = 0, row_h - t, t * 3 do bb:paintRect(x, y + yy, t, t, BLACK) end
        end
      end }
      table.insert(row, OverlapGroup:new {
        dimen = Geom:new { w = cell_w, h = row_h },
        cell,
        HorizontalGroup:new { Theme.hspan(first and 0 or pad), figure },
      })
    end
    table.insert(group, Theme.span("s"))
    table.insert(group, row)
  end
  return group
end

--
-- Labels as small pills, flowing onto as many lines as the width needs.
--
function ChartWidgets.pills(opts)
  local width = opts.width
  local gap = Theme.space.s
  local group = VerticalGroup:new { align = "left" }
  local row, used = nil, 0
  for _, label in ipairs(opts.labels or {}) do
    local pill = Theme.pill(label, { size = "small", max_width = width - Theme.space.l * 2 })
    local w = pill:getSize().w
    if not row or used + gap + w > width then
      if row then table.insert(group, Theme.span("xs")) end
      row = HorizontalGroup:new { align = "center" }
      table.insert(group, row)
      used = 0
    end
    if used > 0 then table.insert(row, Theme.hspan(gap)); used = used + gap end
    table.insert(row, pill)
    used = used + w
  end
  return group
end

ChartWidgets.Canvas = Canvas

return ChartWidgets
