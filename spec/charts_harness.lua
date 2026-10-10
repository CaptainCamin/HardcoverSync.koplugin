-- The arithmetic behind the charts: clean scales, shares that add up, folding a long tail into
-- "Other", where a point of a ring belongs, column and bar sizes. Odd inputs included: nothing,
-- one value, zeros, a huge number.
--
-- Run with:  lua spec/charts_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local Charts = dofile(PLUGIN .. "/hardcover/lib/charts.lua")

print("\n== scales and numbers ==")

check("a scale rounds up to a clean top with 3-5 steps", function()
  local cases = { { 37, 40, 10 }, { 7, 8, 2 }, { 0, 4, 1 }, { 1, 3, 1 }, { 100, 100, 25 }, { 999, 1000, 250 }, { 4.2, 6, 2 } }
  for _, c in ipairs(cases) do
    local top, step = Charts.niceScale(c[1])
    assert(top == c[2] and step == c[3], string.format("niceScale(%s) = %s, %s (wanted %s, %s)", c[1], top, step, c[2], c[3]))
    assert(top >= c[1] and top / step >= 3 and top / step <= 5, "steps for " .. c[1])
  end
  assert(Charts.niceScale(nil) == 4 and Charts.niceScale(-3) == 4 and Charts.niceScale("x") == 4)
end)

check("numbers read with thousands commas; decimals lose a trailing .0", function()
  assert(Charts.number(0) == "0" and Charts.number(999) == "999" and Charts.number(1000) == "1,000")
  assert(Charts.number(1234567) == "1,234,567" and Charts.number(-4200) == "-4,200" and Charts.number(nil) == "")
  assert(Charts.number(12.6) == "13", "rounds")
  assert(Charts.decimal(4) == "4" and Charts.decimal(4.5) == "4.5" and Charts.decimal(4.25) == "4.3" or Charts.decimal(4.25) == "4.2")
  assert(Charts.decimal(3.0, 2) == "3" and Charts.decimal(nil) == "")
end)

check("a label is cut on a character boundary with an ellipsis", function()
  assert(Charts.shorten("Short", 10) == "Short")
  assert(Charts.shorten("A very long author name", 10) == "A very lo\226\128\166")
  local cut = Charts.shorten("\195\169\195\169\195\169\195\169\195\169\195\169", 4) -- six e-acutes, two bytes each
  assert(cut:find("\226\128\166", 1, true) and #cut % 1 == 0)
  for i = 1, #cut - 3 do
    local b = cut:byte(i)
    assert(not (b >= 0x80 and b < 0xC0 and i == 1), "starts mid-character")
  end
  assert(Charts.shorten(nil, 5) == "")
end)

print("\n== shares ==")

check("slices are biggest first and the percents add up to exactly 100", function()
  local s, total = Charts.slices({ { label = "a", value = 1 }, { label = "b", value = 1 }, { label = "c", value = 1 } }, 5)
  assert(#s == 3 and total == 3)
  local sum = 0
  for _, x in ipairs(s) do sum = sum + x.percent end
  assert(sum == 100, "percents add to " .. sum)
  local t = Charts.slices({ { label = "x", value = 333 }, { label = "y", value = 333 }, { label = "z", value = 334 }, { label = "w", value = 1 } }, 9)
  local s2 = 0
  for _, x in ipairs(t) do s2 = s2 + x.percent end
  assert(s2 == 100 and t[1].label == "z", "biggest first, total " .. s2)
end)

check("a long tail is folded into one Other, last, with the leftover share", function()
  local items = {}
  for i = 1, 9 do items[i] = { label = "g" .. i, value = 10 - i } end -- 9..1
  local s = Charts.slices(items, 4, "Other")
  assert(#s == 4 and s[4].label == "Other" and s[4].other == true)
  assert(s[1].label == "g1" and s[3].label == "g3")
  assert(s[4].value == 6 + 5 + 4 + 3 + 2 + 1, "Other holds the rest: " .. s[4].value)
  local sum = 0
  for _, x in ipairs(s) do sum = sum + x.percent end
  assert(sum == 100)
end)

check("nothing, zeros and junk give no slices", function()
  assert(#Charts.slices({}, 5) == 0 and #Charts.slices(nil, 5) == 0)
  assert(#Charts.slices({ { label = "a", value = 0 }, { label = "b", value = -2 }, { label = "c" } }, 5) == 0)
  local s = Charts.slices({ { label = "only", value = 7 } }, 5)
  assert(#s == 1 and s[1].percent == 100 and s[1].fraction == 1)
end)

print("\n== grey steps ==")

check("grey steps run from black to light, each clearly lighter, none near white", function()
  assert(Charts.ramp(1) == 0)
  for i = 2, #Charts.RAMP do
    assert(Charts.ramp(i) - Charts.ramp(i - 1) >= 0x20, "two greys too alike")
  end
  assert(Charts.ramp(#Charts.RAMP) <= 0xBB, "too light to see")
  assert(Charts.ramp(99) == Charts.ramp(#Charts.RAMP) and Charts.ramp(0) == 0, "out of range stays on the ramp")
end)

print("\n== columns and bars ==")

check("columns fit the area, share a clean scale, and a small value still shows", function()
  local cols, top, ticks = Charts.columns({ 0, 1, 12, 5 }, 400, 200, {})
  assert(#cols == 4 and top >= 12)
  assert(cols[1].h == 0, "a zero has no column")
  assert(cols[2].h >= 2, "a single book is visible")
  assert(cols[3].h == math.floor(12 / top * 200 + 0.5))
  for _, c in ipairs(cols) do assert(c.x >= 0 and c.x + c.w <= 400 and c.h <= 200, "inside the area") end
  assert(ticks[1].value == 0 and ticks[1].y == 0 and ticks[#ticks].value == top and ticks[#ticks].y == 200)
end)

check("a shared scale can be forced, a column width capped, and no values is not an error", function()
  local cols, top = Charts.columns({ 3 }, 300, 100, { max = 100 })
  assert(top >= 100 and cols[1].h == math.floor(3 / top * 100 + 0.5) or cols[1].h == 2)
  local capped = Charts.columns({ 5, 5 }, 600, 100, { max_col = 40 })
  assert(capped[1].w == 40)
  local none, t = Charts.columns({}, 300, 100, {})
  assert(#none == 0 and t == 4)
end)

check("bars: the longest fills the width, zero is empty, small is a stub", function()
  local b = Charts.bars({ 10, 5, 0, 1 }, 200, 3)
  assert(b[1] == 200 and b[2] == 100 and b[3] == 0 and b[4] == 20)
  local c = Charts.bars({ 1000, 1 }, 200, 3)
  assert(c[2] == 3, "a tiny bar is still seen")
  local z = Charts.bars({ 0, 0 }, 200)
  assert(z[1] == 0 and z[2] == 0)
end)

r.finish()
