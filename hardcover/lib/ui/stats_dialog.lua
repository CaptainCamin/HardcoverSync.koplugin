-- Your reading, as a page of charts: the numbers that matter up top, then books per month
-- (or per year), how you rate, your genres, who you read most and how long your books run.
-- Period tabs choose all time or one year. Everything is worked out on the device from
-- the saved finished books (see stats.lua), so it reads the same offline; `note` says when
-- what is shown is a saved copy. A page taller than the screen scrolls, one section a block (see
-- components/section.lua).

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local ChartWidgets = require("hardcover/lib/ui/chart_widgets")
local Charts = require("hardcover/lib/charts")
local Hosted = require("hardcover/lib/ui/hosted")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local Section = require("hardcover/lib/ui/components/section")
local Stats = require("hardcover/lib/stats")
local Tabs = require("hardcover/lib/ui/components/tabs")
local Theme = require("hardcover/lib/ui/theme")
local TopBar = require("hardcover/lib/ui/components/top_bar")

local text = Theme.text

local StatsDialog = InputContainer:extend {
  name = "hardcover_stats",
  title = nil,
  rows = nil,        -- Stats rows; nil while loading
  genres = nil,      -- Stats.genres
  complete = true,   -- false when the library is longer than what was loaded
  year = nil,        -- the period: a year, or nil for all time
  note = nil,        -- "Offline. Showing your stats as of ..."
  message = nil,     -- shown instead of the charts
  close_callback = nil,
  -- as a tab of the shell (see hosted.lua): the shell, and the size it gives this body
  shell = nil,
  width = nil,
  height = nil,
}

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

function StatsDialog:init()
  self.title = self.title or _("Stats")
  local w, h = Hosted.size(self)
  self.dimen = Geom:new { x = 0, y = 0, w = w, h = h }
  if not self.shell then self.key_events.CloseStats = { { "Back" } } end
  self:build()
end

-- "3 books" / "1 book"
local function books(n)
  return n == 1 and _("1 book") or string.format(_("%s books"), Charts.number(n))
end

local function hours(seconds)
  return Charts.decimal(seconds / 3600, seconds >= 36000 and 0 or 1)
end

-- a caption under a chart, inside its block
function StatsDialog:caption(block, str, width)
  table.insert(block, Theme.span("s"))
  table.insert(block, text(str, "small", { grey = true, width = width }))
end

-- one line: a label on the left, the figure on the right
local function fact(label, value, width)
  local right = Theme.mmdText(value, "strong", 18)
  local left = Theme.mmdText(label, "text", 18, { width = width - right:getSize().w - Theme.space.l })
  return HorizontalGroup:new { align = "center", left, Theme.hspan(math.max(0, width - left:getSize().w - right:getSize().w)), right }
end

-- A month's first letter (the characters of a translation can be more than one byte)
local function initial(name)
  return name:match("^[%z\1-\127\194-\244][\128-\191]*") or name
end

-- All time | the two latest years | Earlier (the rest, through the picker). A year chosen from the
-- rest shows in the third tab.
function StatsDialog:buildTabs(width)
  if self.message or not self.rows or #self.rows == 0 then return nil end
  local years = Stats.years(self.rows)
  if #years == 0 then return nil end
  local function pick(year)
    return function()
      if self.year == year then return end
      self.year = year
      self:rebuild()
    end
  end
  local tabs = { { label = _("All time"), active = self.year == nil, callback = pick(nil) } }
  for i = 1, math.min(#years, 2) do
    tabs[#tabs + 1] = { label = tostring(years[i]), active = self.year == years[i], callback = pick(years[i]) }
  end
  if #years > 2 then
    local older = self.year ~= nil and self.year ~= years[1] and self.year ~= years[2]
    tabs[#tabs + 1] = {
      label = older and tostring(self.year) or _("Earlier"), active = older,
      callback = function() self:choosePeriod() end,
    }
  end
  return Tabs.new { width = width, tabs = tabs }
end

function StatsDialog:choosePeriod()
  local years = Stats.years(self.rows or {})
  if #years == 0 then return end
  local Picker = require("hardcover/lib/ui/picker")
  local picker
  local function pick(year)
    return function()
      UIManager:close(picker)
      self.year = year
      self:rebuild()
    end
  end
  local rows = { { text = _("All time"), current = self.year == nil, callback = pick(nil) } }
  for _i, y in ipairs(years) do
    rows[#rows + 1] = { text = tostring(y), current = self.year == y, callback = pick(y) }
  end
  picker = Picker.new { title = _("Period"), rows = rows }
  UIManager:show(picker)
end

function StatsDialog:buildContent(width)
  local content = VerticalGroup:new { align = "left" }
  table.insert(content, Theme.span("m"))

  if self.note then
    table.insert(content, FrameContainer:new {
      bordersize = Theme.line.hair, color = Theme.DARK_GREY, radius = Theme.px(8),
      padding = Theme.space.s, margin = 0, background = Blitbuffer.COLOR_WHITE,
      TextBoxWidget:new { text = self.note, face = Theme.face("small"), width = width - 2 * Theme.space.s - 2 * Theme.line.hair },
    })
    table.insert(content, Theme.span("m"))
  end

  if self.message or not self.rows then
    table.insert(content, text(self.message or _("Loading your stats\226\128\166"), "body", { grey = true, width = width }))
    return content
  end

  local s = Stats.compute(self.rows, { year = self.year })

  if s.books == 0 then
    local empty = #self.rows == 0 and _("No finished books yet. Mark a book as read and your stats will grow here.")
      or string.format(_("No books finished in %s."), tostring(self.year))
    table.insert(content, text(empty, "body", { grey = true, width = width }))
    return content
  end

  -- Every section is one block carrying its own spacing, so a page step lands on a section's edge.
  local function block(title, right)
    return Section.new(title, width, { right = right and text(right, "small", { grey = true }) })
  end
  local function add(b)
    table.insert(b, Theme.span("m"))
    table.insert(content, b)
  end

  -- the headline numbers
  local tiles = { { value = Charts.number(s.books), label = s.books == 1 and _("book") or _("books") } }
  if s.pages > 0 then
    tiles[#tiles + 1] = { value = Charts.number(s.pages), label = _("pages") }
  elseif s.audio_seconds > 0 then
    tiles[#tiles + 1] = { value = hours(s.audio_seconds), label = _("hours listened") }
  end
  if s.ratings.average then
    tiles[#tiles + 1] = { value = string.format("%.1f", s.ratings.average), label = _("avg rating") }
  end
  local head = VerticalGroup:new { align = "left", ChartWidgets.kpis { width = width, tiles = tiles, per_row = #tiles } }
  if not self.complete then
    self:caption(head, string.format(_("Your library is large: these are your first %s finished books."), Charts.number(#self.rows)), width)
  end
  add(head)

  -- when
  if self.year then
    local b = block(_("Books per month"), books(s.books))
    local labels = {}
    for i, name in ipairs(MONTHS) do labels[i] = initial(_(name)) end
    table.insert(b, ChartWidgets.columns {
      width = width, height = Theme.px(210), values = s.months, labels = labels,
      highlight = s.best_month and s.best_month.month or nil, emphasis = true,
    })
    if s.month_unknown > 0 then
      self:caption(b, string.format(_("%s finished in an unknown month."), books(s.month_unknown)), width)
    end
    add(b)
  else
    local values, labels = {}, {}
    for i, y in ipairs(s.by_year) do values[i] = y.count; labels[i] = tostring(y.year) end
    if #values > 0 then
      local b = block(_("Books per year"), books(s.books - s.undated))
      table.insert(b, ChartWidgets.columns {
        width = width, height = Theme.px(210), values = values, labels = labels,
        highlight = #values, emphasis = #values > 1,
      })
      if s.undated > 0 then
        self:caption(b, string.format(_("%s have no finish date, so they are not on this chart."), books(s.undated)), width)
      end
      add(b)
    end
  end

  -- how you rate
  if s.ratings.rated > 0 then
    local b = block(_("Your ratings"))
    table.insert(b, ChartWidgets.columns {
      width = width, height = Theme.px(190), values = s.ratings.counts,
      labels = { "0.5", "1", "1.5", "2", "2.5", "3", "3.5", "4", "4.5", "5" },
      marker = { at = s.ratings.average * 2, text = string.format(_("avg %s"), string.format("%.1f", s.ratings.average)) },
    })
    self:caption(b, string.format(_("%s rated out of %s."), books(s.ratings.rated), books(s.books)), width)
    add(b)
  end

  -- genres: Hardcover counts these over the whole library, so only the all-time view has them
  if not self.year and self.genres and #self.genres > 0 then
    local slices = Charts.slices(self.genres, 5, _("Other"))
    local b = block(_("Genres"))
    local rows = {}
    for i, g in ipairs(slices) do rows[i] = { label = g.label, value = g.value, text = string.format("%d%%", g.percent) } end
    table.insert(b, ChartWidgets.bars { width = width, rows = rows, tonal = true, label_fraction = 0.3 })
    self:caption(b, _("Across your whole library, as Hardcover counts them."), width)
    add(b)
  end

  -- who
  if #s.authors > 0 then
    local b = block(_("Most read authors"))
    local rows = {}
    for i, a in ipairs(s.authors) do rows[i] = { label = a.name, value = a.count, text = tostring(a.count) } end
    table.insert(b, ChartWidgets.bars { width = width, rows = rows })
    add(b)
  end

  -- how long
  if s.pages_books > 0 then
    local b = block(_("Book length"), s.average_pages and string.format(_("avg %s pages"), Charts.number(s.average_pages)) or nil)
    local rows = {}
    for i, l in ipairs(s.lengths) do rows[i] = { label = _(l.label), value = l.count, text = tostring(l.count) } end
    table.insert(b, ChartWidgets.bars { width = width, rows = rows, label_fraction = 0.3 })
    table.insert(b, Theme.span("m"))
    if s.longest then
      table.insert(b, fact(_("Longest"), string.format(_("%s pages"), Charts.number(s.longest.pages)), width))
      if s.longest.title then table.insert(b, text(s.longest.title, "small", { grey = true, width = width })) end
      table.insert(b, Theme.span("s"))
    end
    if s.shortest and s.shortest.pages ~= (s.longest and s.longest.pages) then
      table.insert(b, fact(_("Shortest"), string.format(_("%s pages"), Charts.number(s.shortest.pages)), width))
      if s.shortest.title then table.insert(b, text(s.shortest.title, "small", { grey = true, width = width })) end
    end
    add(b)
  end

  -- listening
  if s.audio_books > 0 then
    local b = block(_("Listening"))
    table.insert(b, fact(_("Audiobooks finished"), Charts.number(s.audio_books), width))
    table.insert(b, Theme.span("s"))
    table.insert(b, fact(_("Hours listened"), hours(s.audio_seconds), width))
    add(b)
  end
  return content
end

function StatsDialog:build()
  local screen_w, screen_h = Hosted.size(self)
  local M = Theme.margin
  -- on its own it has a top bar with a back arrow; in the shell the shell has the bar
  local head = VerticalGroup:new { align = "left" }
  local bar
  if not self.shell then
    bar = TopBar.new { width = screen_w, title = self.title, on_back = function() self:onClose() end }
    table.insert(head, bar)
  end
  self.tabs = self:buildTabs(screen_w)
  if self.tabs then table.insert(head, self.tabs) end
  local room = screen_h - head:getSize().h

  local width = screen_w - 2 * M
  local content = self:buildContent(width)
  local body
  self.scroll = nil
  if content:getSize().h + Theme.space.m > room then
    local gutter = ScrollControl.gutter()
    width = screen_w - 2 * M - gutter
    self.scroll = ScrollableContainer:new {
      dimen = Geom:new { x = 0, y = 0, w = screen_w, h = room },
      show_parent = Hosted.window(self),
    }
    local scroll = self.scroll
    content = self:buildContent(width)
    scroll[1] = HorizontalGroup:new { Theme.hspan(M), content }
    body = ScrollControl.wrap(scroll, content)
  else
    body = HorizontalGroup:new { Theme.hspan(M), content }
  end

  self.title_bar = bar
  self.close_button = bar and bar.back_button or nil
  self.frame = FrameContainer:new {
    width = screen_w, height = screen_h, background = Blitbuffer.COLOR_WHITE,
    bordersize = 0, padding = 0, margin = 0,
    VerticalGroup:new { align = "left", head, body },
  }
  self[1] = self.frame
end

function StatsDialog:rebuild()
  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil
  self:build()
  Hosted.dirty(self)
end

-- fresh (or saved) books have arrived
function StatsDialog:setStats(stats, note)
  self.rows, self.genres, self.complete = stats.rows, stats.genres, stats.complete ~= false
  self.note, self.message = note, nil
  -- a chosen year that is no longer there (a saved copy replaced) falls back to all time
  if self.year then
    local found = false
    for _i, y in ipairs(Stats.years(self.rows)) do if y == self.year then found = true end end
    if not found then self.year = nil end
  end
  self:rebuild()
end

function StatsDialog:setMessage(message, note)
  self.message, self.note = message, note
  self:rebuild()
end

function StatsDialog:onCloseWidget()
  if not self.shell then UIManager:setDirty(nil, "ui") end
end

function StatsDialog:onCloseStats()
  return self:onClose()
end

function StatsDialog:onClose()
  if self.shell then return true end -- the shell leaves, not a tab
  UIManager:close(self)
  if self.close_callback then self.close_callback() end
  return true
end

return StatsDialog
