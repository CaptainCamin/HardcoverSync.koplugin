--[[--
The chart widgets (columns, histogram with a marker, bars, tonal bars for genres, KPI strip) drawn on a page,
in the data shapes a reader's library can take: plenty, a single value, nothing, long labels.

Screens: charts_a, charts_b, charts_donut, charts_donut_odd, charts_line_range, charts_c.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen

return {
  name = "charts",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })

    local Charts = require("hardcover/lib/charts")
    local CW = require("hardcover/lib/ui/chart_widgets")
    local Theme = require("hardcover/lib/ui/theme")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Blitbuffer = require("ffi/blitbuffer")

    local W = Screen:getWidth() - 2 * Theme.space.l
    local function page(name, parts)
      local group = VerticalGroup:new { align = "left" }
      for _, p in ipairs(parts) do
        table.insert(group, p)
        table.insert(group, Theme.span("l"))
      end
      local frame = FrameContainer:new { background = Blitbuffer.COLOR_WHITE, bordersize = 0,
        padding = Theme.space.l, group }
      UIManager:show(frame)
      emu:pump()
      emu:shot(name)
      UIManager:close(frame)
      emu:pump()
    end

    local function genre_rows(slices)
      local rows = {}
      for i, g in ipairs(slices) do rows[i] = { label = g.label, value = g.value, text = string.format("%d%%", g.percent) } end
      return rows
    end

    local months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
    page("charts_a", {
      CW.kpis { width = W, tiles = { { value = "47", label = "books" }, { value = "14,820", label = "pages" },
        { value = "4.1", label = "avg rating" } } },
      CW.columns { width = W, height = Theme.px(200), values = { 3, 5, 2, 6, 9, 4, 1, 0, 5, 7, 2, 3 },
        labels = months, highlight = 5, emphasis = true },
      CW.columns { width = W, height = Theme.px(170), values = { 1, 0, 2, 5, 11, 20, 7, 9, 3, 1 },
        labels = { "0.5", "1", "1.5", "2", "2.5", "3", "3.5", "4", "4.5", "5" },
        marker = { at = 7.2, text = "avg 3.7" } },
    })

    local slices = Charts.slices({ { label = "Fantasy", value = 120 }, { label = "Science fiction", value = 70 },
      { label = "Mystery & thriller", value = 40 }, { label = "Romance", value = 22 }, { label = "Nonfiction", value = 9 },
      { label = "History", value = 5 }, { label = "Poetry", value = 2 } }, 5, "Other")
    page("charts_b", {
      CW.bars { width = W, tonal = true, label_fraction = 0.3, rows = genre_rows(slices) },
      CW.bars { width = W, rows = { { label = "Brandon Sanderson", value = 14 }, { label = "Ursula K. Le Guin", value = 9 },
        { label = "A very long author name that will not fit on one line", value = 6 }, { label = "Becky Chambers", value = 3, text = "3" } } },
    })

    -- the donut: the common case, then a ring too narrow for its legend beside it
    page("charts_donut", {
      CW.donut { width = W, slices = slices, center = { top = string.format("%d%%", slices[1].percent), bottom = slices[1].label } },
      CW.donut { width = Theme.px(300), slices = slices, center = { top = "34%", bottom = "Mystery & thriller" } },
    })
    -- one slice is a whole ring (no gap), a sliver smaller than the gap still shows, nothing draws nothing
    page("charts_donut_odd", {
      CW.donut { width = W, slices = Charts.slices({ { label = "Fantasy", value = 3 } }, 5, "Other"), center = { top = "100%", bottom = "Fantasy" } },
      CW.donut { width = W, slices = Charts.slices({ { label = "Fantasy", value = 500 }, { label = "Poetry", value = 1 } }, 5, "Other") },
      CW.donut { width = W, slices = {} },
    })
    -- the running total and the range
    page("charts_line_range", {
      CW.line { width = W, height = Theme.px(190), values = Charts.cumulative({ 2, 3, 0, 4, 1, 5, 2, 0, 3 }), slots = 12,
        labels = { "J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D" } },
      CW.line { width = W, height = Theme.px(190), values = Charts.cumulative({ 0, 0, 1 }), slots = 12,
        labels = { "J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D" } },
      CW.spread { width = W, values = { 90, 180, 240, 300, 310, 350, 420, 480, 520, 1180 }, average = 407, unit = "pages" },
      CW.spread { width = W, values = { 250, 250 }, average = 250, unit = "pages" },
    })

    page("charts_c", {
      CW.kpis { width = W, tiles = { { value = "1", label = "book" }, { value = "0", label = "pages" } }, per_row = 2 },
      CW.columns { width = W, height = Theme.px(150), values = { 0, 0, 1 }, labels = { "2023", "2024", "2025" } },
      CW.columns { width = W, height = Theme.px(150), values = {}, labels = {} },
      CW.bars { width = W, tonal = true, rows = genre_rows(Charts.slices({ { label = "Fantasy", value = 1 } }, 5, "Other")) },
      CW.bars { width = W, rows = {} },
    })
  end,
}
