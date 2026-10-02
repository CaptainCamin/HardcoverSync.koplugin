--[[--
PROTOTYPES for the goals feature (not production code): three ways to show reading
goals, each built from the plugin's own theme, with fixture goals and a fixed "today"
(2026-10-02). Pace is worked out on the device from the saved goal and the date, so
every screen here works offline; the offline variant shows the saved-copy note and a
book finished offline.

Screens: goals_a_home (a goal card on Home), goals_b_cards (a Goals screen of cards),
goals_c_hero (one big goal and a pace comparison), goals_d_offline (B, offline).
]]

local fixtures = require("fixtures")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Theme = require("hardcover/lib/ui/theme")
local TapRow = require("hardcover/lib/ui/tap_row")

local Screen = Device.screen

-- ---------------------------------------------------------------- fixture data
local TODAY = { y = 2026, m = 10, d = 2 }
local function days(y, m, d) return math.floor(os.time { year = y, month = m, day = d, hour = 12 } / 86400) end
local function date(s) local y, m, d = s:match("(%d+)-(%d+)-(%d+)"); return days(tonumber(y), tonumber(m), tonumber(d)) end

local GOALS = {
  { name = "2026 Reading Goal", metric = "book", goal = 70, progress = 46, start = "2026-01-01", finish = "2027-01-01" },
  { name = "October pages", metric = "page", goal = 3000, progress = 150, start = "2026-10-01", finish = "2026-11-01" },
  { name = "2026 Reading Goal", metric = "book", goal = 30, progress = 46, start = "2026-01-01", finish = "2027-01-01" },
  { name = "Summer 2026", metric = "book", goal = 10, progress = 6, start = "2026-06-01", finish = "2026-09-01" },
  { name = "2025 Reading Goal", metric = "book", goal = 100, progress = 77, start = "2025-01-01", finish = "2026-01-01" },
}

-- everything a screen needs, from the goal and today: the same arithmetic offline
local function pace(g, extra)
  local today = days(TODAY.y, TODAY.m, TODAY.d)
  local from, to = date(g.start), date(g.finish)
  local total, elapsed = to - from, math.min(math.max(today - from, 0), to - from)
  local progress = g.progress + (extra or 0)
  local expected = g.goal * elapsed / total
  local left = math.max(to - today, 0)
  local out = {
    progress = progress, goal = g.goal, fraction = math.min(1, progress / g.goal),
    pace_fraction = math.min(1, expected / g.goal), days_left = left,
    unit = g.metric == "page" and "pages" or "books",
    done = progress >= g.goal, over = left == 0,
  }
  local delta = progress - expected
  out.delta = delta
  if out.done then out.status = "Done"
  elseif out.over then out.status = string.format("Ended %d short", g.goal - progress)
  elseif delta >= 1 then out.status = string.format("%d ahead of pace", math.floor(delta))
  elseif delta <= -1 then out.status = string.format("%d behind pace", math.floor(-delta))
  else out.status = "On pace" end
  local remaining = g.goal - progress
  if not out.done and left > 0 then out.rate = string.format("%.1f %s a week to finish", remaining / (left / 7), out.unit) end
  return out
end

-- ----------------------------------------------------------------- widgets
local function text(str, size, opts)
  opts = opts or {}
  return TextWidget:new { text = str, face = Theme.face(size), bold = opts.bold, max_width = opts.width,
    fgcolor = opts.grey and Theme.DARK_GREY or Theme.BLACK }
end

-- a bar with a tick where you should be by today
local function bar(width, h, p)
  return ProgressWidget:new { width = width, height = h, percentage = p.fraction,
    ticks = (not (p.over or p.done)) and { math.floor(p.pace_fraction * 1000) } or nil, last = 1000 }
end

local function when(s) return s end

local function card(g, width, opts)
  opts = opts or {}
  local p = pace(g, opts.extra)
  local g_ = VerticalGroup:new { align = "left" }
  table.insert(g_, Theme.rule(width, false))
  table.insert(g_, Theme.span("m"))
  local head = HorizontalGroup:new { align = "center", text(g.name, "title", { bold = true, width = width }) }
  table.insert(g_, head)
  table.insert(g_, Theme.span("xs"))
  local fig = HorizontalGroup:new { align = "bottom",
    text(tostring(p.progress), "display", { bold = true }), Theme.hspan("s"),
    text(string.format("/ %d %s", p.goal, p.unit), "body", { grey = true }) }
  if opts.extra and opts.extra > 0 then
    table.insert(fig, Theme.hspan("m"))
    table.insert(fig, Theme.pill(string.format("+%d finished offline", opts.extra), { size = "small" }))
  end
  table.insert(g_, fig)
  table.insert(g_, Theme.span("s"))
  table.insert(g_, bar(width, Screen:scaleBySize(16), p))
  table.insert(g_, Theme.span("s"))
  local line = p.status
  if not p.done and not p.over then line = line .. string.format("  \194\183  %d days left", p.days_left) end
  table.insert(g_, text(line, "small", { bold = true, width = width }))
  if p.rate then table.insert(g_, text(p.rate, "small", { grey = true, width = width })) end
  table.insert(g_, Theme.span("m"))
  return g_
end

local Screen_ = InputContainer:extend { name = "goals_proto" }
function Screen_:init()
  self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
  self.key_events.Close = { { "Back" } }
  local bar_ = Theme.titleBar { title = self.title, close_callback = function() UIManager:close(self) end, show_parent = self }
  local M = Theme.margin
  self[1] = FrameContainer:new { width = self.dimen.w, height = self.dimen.h, background = Blitbuffer.COLOR_WHITE,
    bordersize = 0, padding = 0, margin = 0,
    VerticalGroup:new { align = "left", bar_, HorizontalGroup:new { Theme.hspan(M), self.body(self.dimen.w - 2 * M) } } }
end
function Screen_:onCloseWidget() UIManager:setDirty(nil, "ui") end

local function show(title, body) UIManager:show(Screen_:new { title = title, body = body }) end

local function section(title, width, right)
  return Theme.sectionHeader(title, width, right)
end

local function past_row(g, width)
  local p = pace(g)
  local right = text(string.format("%d / %d", p.progress, p.goal), "title", { bold = true })
  local name = text(g.name, "body", { bold = true, width = width - right:getSize().w - Theme.space.l })
  local gap = math.max(0, width - name:getSize().w - right:getSize().w)
  return VerticalGroup:new { align = "left", Theme.rule(width, false), Theme.span("s"),
    HorizontalGroup:new { align = "center", name, Theme.hspan(gap), right },
    text(p.done and "Reached" or p.status, "small", { grey = true }), Theme.span("s") }
end

return {
  name = "goals_proto",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    for _, id in ipairs({ 101, 102 }) do fixtures.seed_cover("https://covers.hardcover.app/fixture/" .. id .. ".jpg") end
    fixtures.install({ settings = settings })

    -- A: a goal card on Home, under the Library tiles; tapping opens the Goals screen
    local LuaSettings = require("luasettings")
    local ShelfCache = require("hardcover/lib/shelf_cache")
    local path = emu.DataStorage:getSettingsDir() .. "/hardcovershelf_cache_goals.lua"
    os.remove(path)
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings,
      shelf_cache = ShelfCache:new { path = path, open = function(p) return LuaSettings:open(p) end } }
    manager:showHome()
    emu:pump()
    local home = manager.home_dialog
    home.list_count = 5
    home.goal_card_fn = function(width)
      local g = GOALS[1]
      local p = pace(g)
      local out = VerticalGroup:new { align = "left" }
      local more = text("\226\128\186", "title", { bold = true })
      table.insert(out, Theme.sectionHeader("Goal", width, more))
      table.insert(out, Theme.span("s"))
      table.insert(out, TapRow:new { callback = function() end, VerticalGroup:new { align = "left",
        text(g.name, "body", { bold = true, width = width }),
        Theme.span("xs"),
        HorizontalGroup:new { align = "bottom", text(tostring(p.progress), "display", { bold = true }), Theme.hspan("s"),
          text(string.format("/ %d books  \194\183  %s", p.goal, p.status), "body", { width = width }) },
        Theme.span("s"), bar(width, Screen:scaleBySize(14), p), Theme.span("xs"),
        text(string.format("%d days left  \194\183  the tick marks where you should be today", p.days_left), "small", { grey = true, width = width }) } })
      return out
    end
    home:rebuild()
    emu:pump()
    emu:shot("goals_a_home")
    emu:closeAll()

    -- B: the Goals screen as cards: current goals first, past ones as plain rows
    show("Goals", function(width)
      local c = VerticalGroup:new { align = "left" }
      table.insert(c, Theme.span("m"))
      table.insert(c, section("Current", width, text("3", "small", { grey = true })))
      table.insert(c, Theme.span("s"))
      for i = 1, 3 do table.insert(c, card(GOALS[i], width)) end
      table.insert(c, Theme.span("m"))
      table.insert(c, section("Past goals", width, text("2", "small", { grey = true })))
      table.insert(c, Theme.span("s"))
      table.insert(c, past_row(GOALS[4], width))
      table.insert(c, past_row(GOALS[5], width))
      return c
    end)
    emu:pump()
    emu:shot("goals_b_cards")
    emu:closeAll()

    -- C: one goal, big: the number, you against pace, what it takes to finish
    show("2026 Reading Goal", function(width)
      local g = GOALS[1]
      local p = pace(g)
      local c = VerticalGroup:new { align = "left" }
      table.insert(c, Theme.span("l"))
      table.insert(c, HorizontalGroup:new { align = "bottom", text(tostring(p.progress), "display", { bold = true }),
        Theme.hspan("m"), text(string.format("of %d books", p.goal), "title", { grey = true }) })
      table.insert(c, Theme.span("s"))
      table.insert(c, Theme.pill(p.status, { filled = true, size = "body" }))
      table.insert(c, Theme.span("l"))
      table.insert(c, section("You, and where you should be", width))
      table.insert(c, Theme.span("m"))
      table.insert(c, text("You", "small", { bold = true }))
      table.insert(c, ProgressWidget:new { width = width, height = Screen:scaleBySize(20), percentage = p.fraction })
      table.insert(c, Theme.span("m"))
      table.insert(c, text("Pace for today", "small", { bold = true }))
      table.insert(c, ProgressWidget:new { width = width, height = Screen:scaleBySize(20), percentage = p.pace_fraction })
      table.insert(c, Theme.span("l"))
      table.insert(c, section("To finish", width))
      table.insert(c, Theme.span("m"))
      table.insert(c, text(string.format("%d left in %d days", p.goal - p.progress, p.days_left), "title", { bold = true, width = width }))
      table.insert(c, text(p.rate, "body", { grey = true, width = width }))
      table.insert(c, Theme.span("l"))
      table.insert(c, section("Other goals", width, text("2", "small", { grey = true })))
      table.insert(c, Theme.span("s"))
      for _, i in ipairs({ 2, 3 }) do
        local o = pace(GOALS[i])
        local right = text(string.format("%d / %d", o.progress, o.goal), "title", { bold = true })
        local name = text(GOALS[i].name, "body", { bold = true, width = width - right:getSize().w - Theme.space.l })
        table.insert(c, VerticalGroup:new { align = "left", Theme.rule(width, false), Theme.span("s"),
          HorizontalGroup:new { align = "center", name, Theme.hspan(math.max(0, width - name:getSize().w - right:getSize().w)), right },
          text(o.status, "small", { grey = true }), Theme.span("s") })
      end
      return c
    end)
    emu:pump()
    emu:shot("goals_c_hero")
    emu:closeAll()

    -- D: B again with no connection: saved copy, a book finished offline
    show("Goals", function(width)
      local c = VerticalGroup:new { align = "left" }
      table.insert(c, Theme.span("m"))
      table.insert(c, FrameContainer:new { bordersize = Theme.line.hair, color = Theme.DARK_GREY, padding = Theme.space.s,
        margin = 0, radius = Theme.px(8), background = Blitbuffer.COLOR_WHITE,
        TextBoxWidget:new { text = "Offline. Showing your goals as of Oct 1, 9:12 am. A book you finished offline is counted.",
          face = Theme.face("small"), width = width - 2 * Theme.space.s - 4 } })
      table.insert(c, Theme.span("m"))
      table.insert(c, section("Current", width, text("3", "small", { grey = true })))
      table.insert(c, Theme.span("s"))
      table.insert(c, card(GOALS[1], width, { extra = 1 }))
      table.insert(c, card(GOALS[2], width))
      table.insert(c, card(GOALS[3], width))
      return c
    end)
    emu:pump()
    emu:shot("goals_d_offline")
    emu:closeAll()
  end,
}
