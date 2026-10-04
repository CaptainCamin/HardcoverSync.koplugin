-- The arithmetic of the plugin's charts, as plain data.
--
-- No KOReader requires, so it runs under stock Lua in the spec suite: the widgets
-- (ui/chart_widgets.lua) only draw what this works out. Designed for an e-ink panel and for
-- any library, large or small: scales that round to clean numbers, a tail of small slices
-- folded into "Other", shares that add up to 100, grey levels that stay apart on a mono panel.

local Charts = {}

--
-- A clean top for an axis and the step between its ticks: 0..max in about four steps, each a
-- 1, 2 or 5 times a power of ten. A max of 0 (nothing to plot) still gives a usable 0..4.
--   niceScale(37)  -> 40, 10      niceScale(7) -> 8, 2      niceScale(0) -> 4, 1
-- (counts: the step is a whole number)
--
function Charts.niceScale(max)
  max = tonumber(max) or 0
  if max <= 0 then return 4, 1 end
  local rough = max / 4
  local power = 10 ^ math.floor(math.log(rough) / math.log(10))
  local frac = rough / power
  local nice = frac <= 1 and 1 or frac <= 2 and 2 or frac <= 2.5 and 2.5 or frac <= 5 and 5 or 10
  -- these are counts (books, pages): whole steps, never a tick at 0.5
  local step = math.max(1, math.ceil(nice * power - 1e-9))
  local top = math.ceil(max / step) * step
  -- at least three steps, so a small count still has a scale to read it against
  if top / step < 3 then top = step * 3 end
  return top, step
end

-- 12345 -> "12,345"
function Charts.number(n)
  n = tonumber(n)
  if not n then return "" end
  local sign = n < 0 and "-" or ""
  local digits = tostring(math.floor(math.abs(n) + 0.5))
  local out = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return sign .. out
end

-- 4.5 -> "4.5", 4 -> "4" (a rating or an average without a trailing .0)
function Charts.decimal(n, places)
  n = tonumber(n)
  if not n then return "" end
  local text = string.format("%." .. (places or 1) .. "f", n)
  return (text:gsub("%.?0+$", ""))
end

-- a label cut to `max` characters with an ellipsis, on a UTF-8 boundary
function Charts.shorten(text, max)
  text = tostring(text or "")
  if #text <= max then return text end
  local cut = max - 1
  -- do not stop in the middle of a multi-byte character
  while cut > 0 do
    local byte = text:byte(cut + 1)
    if not byte or byte < 0x80 or byte >= 0xC0 then break end
    cut = cut - 1
  end
  return text:sub(1, cut):gsub("%s+$", "") .. "\226\128\166"
end

--
-- Shares for a pie or a stacked bar. `items` are { label, value }; the biggest `max` keep their
-- own slice, the rest are folded into one "Other" (named by `other_label`). Zero and negative
-- values are dropped. Each slice gets `fraction` (0..1) and `percent`, a whole number: the
-- percents add up to exactly 100 (largest remainders), so a chart never says 99% or 101%.
-- Returns the slices, biggest first with Other last, and the total.
--
function Charts.slices(items, max, other_label)
  local list, total = {}, 0
  for _, item in ipairs(type(items) == "table" and items or {}) do
    local v = tonumber(item.value)
    if v and v > 0 then
      list[#list + 1] = { label = item.label, value = v, key = item.key }
      total = total + v
    end
  end
  table.sort(list, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return tostring(a.label) < tostring(b.label)
  end)
  if total == 0 then return {}, 0 end

  max = max or 5
  if #list > max then
    local rest = 0
    for i = max, #list do rest = rest + list[i].value end
    for i = #list, max, -1 do list[i] = nil end
    list[max] = { label = other_label or "Other", value = rest, other = true }
  end

  -- percents by largest remainder
  local floor_sum = 0
  for _, s in ipairs(list) do
    s.fraction = s.value / total
    s.percent = math.floor(s.fraction * 100)
    s.remainder = s.fraction * 100 - s.percent
    floor_sum = floor_sum + s.percent
  end
  local order = {}
  for i = 1, #list do order[i] = i end
  table.sort(order, function(a, b)
    if list[a].remainder ~= list[b].remainder then return list[a].remainder > list[b].remainder end
    return a < b
  end)
  for k = 1, 100 - floor_sum do
    local s = list[order[(k - 1) % #list + 1]]
    s.percent = s.percent + 1
  end
  for _, s in ipairs(list) do s.remainder = nil end
  return list, total
end

--
-- Where each slice of a ring starts and ends, as fractions of a turn from 12 o'clock clockwise
-- (0..1). Adds `from` and `to` to each slice.
--
function Charts.arcs(slices)
  local at = 0
  for _, s in ipairs(slices) do
    s.from, s.to = at, at + s.fraction
    at = s.to
  end
  return slices
end

-- Which slice a point belongs to: (dx, dy) from the ring's centre, y down. nil outside the ring
-- (`inner` and `outer` are radii) or past the last slice.
function Charts.sliceAt(slices, dx, dy, inner, outer)
  local d2 = dx * dx + dy * dy
  if d2 > outer * outer or d2 < inner * inner then return nil end
  -- a turn from 12 o'clock, clockwise: atan2(dx, -dy)
  local turn = math.atan2(dx, -dy) / (2 * math.pi)
  if turn < 0 then turn = turn + 1 end
  for i, s in ipairs(slices) do
    if turn >= s.from and turn < s.to then return i end
  end
  return #slices > 0 and #slices or nil
end

-- Like sliceAt, but a thin gap (`gap` px wide, in the surface colour) is left where two slices
-- meet: nil for a pixel within gap/2 of a slice's edge. `outer` is used as the ring's mid radius
-- to turn the angle into a length. Only between slices: a single slice is a whole ring.
function Charts.sliceAtGap(slices, dx, dy, inner, outer, gap)
  local index = Charts.sliceAt(slices, dx, dy, inner, outer)
  if not index or #slices < 2 or not gap or gap <= 0 then return index end
  local turn = math.atan2(dx, -dy) / (2 * math.pi)
  if turn < 0 then turn = turn + 1 end
  local s = slices[index]
  local r = math.sqrt(dx * dx + dy * dy)
  local edge = math.min(math.abs(turn - s.from), math.abs(s.to - turn)) * 2 * math.pi * r
  -- the first slice also meets the last across 12 o'clock
  if index == 1 then edge = math.min(edge, (1 - slices[#slices].to + turn) * 2 * math.pi * r) end
  if index == #slices then edge = math.min(edge, (1 - turn + slices[1].from) * 2 * math.pi * r) end
  if edge < gap / 2 then return nil end
  return index
end

--
-- Grey levels (0 black .. 255 white) for `n` slices, far enough apart to tell on a mono panel
-- and none so light that it washes out against white paper. The first is the darkest: the
-- biggest slice is the headline. A folded "Other" takes the lightest.
--
local LEVELS = { 0x00, 0x66, 0x33, 0x99, 0xBB }
function Charts.shade(i)
  return LEVELS[((i or 1) - 1) % #LEVELS + 1]
end
Charts.LEVELS = LEVELS

--
-- Columns for a column chart in an area `w` x `h`: one per value, with a gap between, a
-- scale rounded to clean numbers and the height each column reaches. `max` forces the top of
-- the scale (a shared scale for charts that are compared). Each column: { x, w, h, value }
-- measured from the area's left and its baseline (up). Columns are at most `max_col` wide.
--
function Charts.columns(values, w, h, opts)
  opts = opts or {}
  local n = #values
  local biggest = 0
  for _, v in ipairs(values) do if (tonumber(v) or 0) > biggest then biggest = tonumber(v) end end
  local top, step = Charts.niceScale(opts.max or biggest)
  local gap = opts.gap or 2
  local slot = n > 0 and w / n or w
  local col_w = math.max(1, math.min(opts.max_col or slot, math.floor(slot - gap)))
  local cols = {}
  for i, v in ipairs(values) do
    local value = tonumber(v) or 0
    cols[i] = {
      x = math.floor((i - 1) * slot + (slot - col_w) / 2),
      w = col_w,
      -- a value of 0 has no column; any other value shows at least a 2px stub
      h = value <= 0 and 0 or math.max(2, math.floor(value / top * h + 0.5)),
      value = value,
    }
  end
  local ticks = {}
  for v = 0, top, step do ticks[#ticks + 1] = { value = v, y = math.floor(v / top * h + 0.5) } end
  return cols, top, ticks
end

--
-- The widths of the bars of a bar chart whose longest fills `w`. A bar of 0 is 0 wide; any
-- other is at least `min` (a thin stub, so a small count is still seen).
--
function Charts.bars(values, w, min)
  local max = 0
  for _, v in ipairs(values) do if (tonumber(v) or 0) > max then max = tonumber(v) end end
  local out = {}
  for i, v in ipairs(values) do
    local value = tonumber(v) or 0
    out[i] = (value <= 0 or max == 0) and 0 or math.max(min or 2, math.floor(value / max * w + 0.5))
  end
  return out
end

return Charts
