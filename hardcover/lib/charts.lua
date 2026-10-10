-- The arithmetic of the plugin's charts, as plain data.
--
-- No KOReader requires, so it runs under stock Lua in the spec suite: the widgets
-- (ui/chart_widgets.lua) only draw what this works out. Designed for an e-ink panel and for
-- any library, large or small: scales that round to clean numbers, a tail of small slices
-- folded into "Other", shares that add up to 100, grey steps that stay apart on a mono panel.

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
-- Shares for a ranked set of bars. `items` are { label, value }; the biggest `max` keep their
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
-- Grey levels (0 black .. 255 white) for bars that run from the biggest to the smallest, each a
-- clear step lighter than the one before and none so light that it washes out against white paper.
-- The first is black: the biggest is the headline. Past the last, the lightest repeats.
--
local RAMP = { 0x00, 0x44, 0x77, 0x99, 0xBB }
function Charts.ramp(i)
  return RAMP[math.min(math.max(i or 1, 1), #RAMP)]
end
Charts.RAMP = RAMP

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
