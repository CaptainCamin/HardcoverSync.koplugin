-- PROTOTYPE -- throwaway, never merge to main.
--
-- Question: what should a *modular* Home look like?
-- Plan: three structurally different layouts of the same Home modules, on the
-- existing Home screen, switched by a pill at the bottom of the page.
--
--   A  Stack      every module a section with its own heading; "Customize Home"
--                 lets you move/hide modules (in memory only)
--   B  Dashboard  a fixed, non-scrolling grid of summary tiles, one per module
--   C  Tabs       a tab strip of module names; one module fills the page
--
-- Turned on by the KOReader setting `hardcover_prototype_home_variant` ("A", "B"
-- or "C"). Unset (the default) means today's Home, untouched. Run it with
-- spec/emu/prototype_modular_home.sh.

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")

local Goals = require("hardcover/lib/goals")
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local Home = require("hardcover/lib/home")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen
local text = Theme.text

local P = {}

P.SETTING = "hardcover_prototype_home_variant"
P.VARIANTS = {
  { key = "A", name = "Stack" },
  { key = "B", name = "Dashboard" },
  { key = "C", name = "Tabs" },
}

-- In-memory module state (no persistence: that is a later question).
P.state = {
  order = { "search", "reading", "shelves", "goal", "discover" },
  hidden = {},
  editing = false, -- A: the move/hide controls are showing
  tab = "reading", -- C: the module on the page
}

P.TITLES = {
  search = "Search",
  reading = "Currently reading",
  shelves = "Shelves",
  goal = "Goal",
  discover = "Discover",
}

function P.current()
  local s = rawget(_G, "G_reader_settings")
  local v = s and s:readSetting(P.SETTING)
  for _, def in ipairs(P.VARIANTS) do
    if def.key == v then return def end
  end
  return nil
end

function P.select(dialog, key)
  G_reader_settings:saveSetting(P.SETTING, key)
  dialog.prototype_variant = key
  dialog:rebuild()
end

function P.step(dialog, delta)
  local cur = P.current() or P.VARIANTS[1]
  local i
  for n, def in ipairs(P.VARIANTS) do if def.key == cur.key then i = n end end
  i = (i - 1 + delta) % #P.VARIANTS + 1
  P.select(dialog, P.VARIANTS[i].key)
end

-- -------------------------------------------------------------------------
-- Data the modules draw (from what HomeDialog already holds)
-- -------------------------------------------------------------------------

local function readingTotal(d, cards)
  local total = #cards
  for _, row in ipairs(d.rows or {}) do
    if row.status_id == HARDCOVER.STATUS.READING and type(row.count) == "number" and row.count >= #cards then
      total = row.count
    end
  end
  return total
end

local function shelfRows(d)
  local rows = {}
  for _, row in ipairs(d.rows or {}) do
    if row.status_id ~= HARDCOVER.STATUS.READING then rows[#rows + 1] = row end
  end
  return rows
end

local function discoverRows(d)
  local rows = {}
  if d.lists_cb then rows[#rows + 1] = { lists = true, title = "More lists", count = d.list_count } end
  if d.for_you_cb then rows[#rows + 1] = { for_you = true, title = "For you" } end
  if d.vibes_cb then rows[#rows + 1] = { vibes = true, title = "Vibes" } end
  if d.stats_cb then rows[#rows + 1] = { stats = true, title = "Stats" } end
  return rows
end

local function currentGoal(d)
  if type(d.goals) ~= "table" or #d.goals == 0 then return nil end
  local today = Goals.today()
  local goal = Goals.pick(d.goals, today)
  if not goal then return nil end
  return goal, Goals.pace(goal, today, Goals.extra(goal, today, d.finished_offline))
end

local function openReading(d)
  if d.select_cb then d.select_cb({ status_id = HARDCOVER.STATUS.READING, title = "Currently Reading" }) end
end

local function tap(widget, cb, viewport)
  return TapRow:new { callback = cb, viewport = viewport, widget }
end

local function bar(w, fraction)
  return ProgressWidget:new { width = w, height = Screen:scaleBySize(10), percentage = fraction }
end

-- -------------------------------------------------------------------------
-- Modules: each fn(d, width, viewport) -> widget body (no heading)
-- -------------------------------------------------------------------------

local Modules = {}

function Modules.search(d, width, viewport)
  local h = Screen:scaleBySize(52)
  local icon = Screen:scaleBySize(26)
  local field = tap(Theme.box(width, h, LeftContainer:new {
    dimen = Geom:new { w = width - 2 * Theme.line.firm, h = h - 2 * Theme.line.firm },
    HorizontalGroup:new {
      align = "center",
      Theme.hspan("m"),
      IconWidget:new { icon = "appbar.search", width = icon, height = icon },
      Theme.hspan("s"),
      text("Search books on Hardcover", "body", { grey = true, width = width - 4 * Theme.space.m }),
    },
  }, { radius = 26 }), function() if d.search_cb then d.search_cb() end end, viewport)
  d.search_button = field
  return field
end

function Modules.reading(d, width, viewport, max)
  local cards = Home.cards(d.entries)
  local col = VerticalGroup:new { align = "left" }
  if #cards == 0 then
    table.insert(col, text("Nothing being read yet.", "small", { grey = true, width = width }))
    return col
  end
  for i = 1, math.min(#cards, max or 3) do
    table.insert(col, d:buildCard(cards[i], width, viewport))
  end
  return col
end

local function tileGrid(d, rows, width, viewport)
  local col = VerticalGroup:new { align = "left" }
  local tw = math.floor((width - Theme.space.m) / 2)
  local th = Screen:scaleBySize(64)
  for i = 1, #rows, 2 do
    local pair = HorizontalGroup:new { d:buildTile(rows[i], tw, th, viewport) }
    if rows[i + 1] then
      table.insert(pair, Theme.hspan("m"))
      table.insert(pair, d:buildTile(rows[i + 1], tw, th, viewport))
    end
    table.insert(col, pair)
    if rows[i + 2] then table.insert(col, Theme.span("m")) end
  end
  return col
end

function Modules.shelves(d, width, viewport)
  return tileGrid(d, shelfRows(d), width, viewport)
end

function Modules.discover(d, width, viewport)
  return tileGrid(d, discoverRows(d), width, viewport)
end

function Modules.goal(d, width, viewport)
  local goal, p = currentGoal(d)
  if not goal then
    return text("No current goal.", "small", { grey = true, width = width })
  end
  local body = VerticalGroup:new {
    align = "left",
    text(goal.name, "body", { bold = true, width = width }),
    Theme.span("xs"),
    HorizontalGroup:new {
      align = "bottom",
      text(string.format("%d", p.progress), "display", { bold = true }),
      Theme.hspan("s"),
      text(string.format("/ %d %s  \194\183  %s", p.target, p.unit, p.status), "body", { width = width }),
    },
    Theme.span("s"),
    require("hardcover/lib/ui/goal_widgets").bar(width, Screen:scaleBySize(14), p),
    Theme.span("xs"),
    text(Goals.leftText(p), "small", { grey = true, width = width }),
  }
  return tap(body, function() if d.goal_cb then d.goal_cb(goal) end end, viewport)
end

-- What a module's heading opens, if anything.
local HEADING_TAP = {
  reading = openReading,
  goal = function(d) if d.goals_cb then d.goals_cb() end end,
}

-- -------------------------------------------------------------------------
-- A: Stack -- sections in a user-chosen order, each with its own heading
-- -------------------------------------------------------------------------

local function moveModule(key, delta)
  local order = P.state.order
  for i, k in ipairs(order) do
    if k == key then
      local j = i + delta
      if j >= 1 and j <= #order then order[i], order[j] = order[j], order[i] end
      return
    end
  end
end

local function smallButton(label, cb, viewport)
  return Theme.button(label, Screen:scaleBySize(74), { h = Screen:scaleBySize(40), size = "label", callback = cb, viewport = viewport })
end

local function stackHeading(d, key, width, viewport)
  local right
  if P.state.editing then
    right = HorizontalGroup:new {
      align = "center",
      smallButton("Up", function() moveModule(key, -1); d:rebuild() end, viewport),
      Theme.hspan("xs"),
      smallButton("Down", function() moveModule(key, 1); d:rebuild() end, viewport),
      Theme.hspan("xs"),
      smallButton("Hide", function() P.state.hidden[key] = true; d:rebuild() end, viewport),
    }
  elseif key == "reading" then
    local cards = Home.cards(d.entries)
    local n = readingTotal(d, cards)
    right = text((n == 1 and "1 book" or string.format("%d books", n)) .. "  \226\128\186", "small", { grey = true })
  elseif HEADING_TAP[key] then
    right = text("\226\128\186", "title", { bold = true })
  end
  local heading = Theme.sectionHeader(P.TITLES[key], width, right)
  if not P.state.editing and HEADING_TAP[key] then
    heading = tap(heading, function() HEADING_TAP[key](d) end, viewport)
    if key == "reading" then d.reading_header = heading end
  end
  return heading
end

local function buildStack(d, width, viewport)
  local column = VerticalGroup:new { align = "left" }
  table.insert(column, Theme.span("m"))
  for _, key in ipairs(P.state.order) do
    if not P.state.hidden[key] then
      if key ~= "search" or P.state.editing then
        table.insert(column, stackHeading(d, key, width, viewport))
        table.insert(column, Theme.span("m"))
      end
      table.insert(column, Modules[key](d, width, viewport))
      table.insert(column, Theme.span("l"))
    end
  end
  if P.state.editing then
    local hidden = {}
    for _, key in ipairs(P.state.order) do if P.state.hidden[key] then hidden[#hidden + 1] = key end end
    if #hidden > 0 then
      table.insert(column, Theme.sectionHeader("Hidden", width))
      table.insert(column, Theme.span("m"))
      for _, key in ipairs(hidden) do
        table.insert(column, Theme.button("Show " .. P.TITLES[key], width, {
          viewport = viewport,
          callback = function() P.state.hidden[key] = nil; d:rebuild() end,
        }))
        table.insert(column, Theme.span("s"))
      end
      table.insert(column, Theme.span("m"))
    end
  end
  table.insert(column, Theme.button(P.state.editing and "Done" or "Customize Home", width, {
    filled = P.state.editing,
    viewport = viewport,
    callback = function() P.state.editing = not P.state.editing; d:rebuild() end,
  }))
  d.customize_button = column[#column]
  table.insert(column, Theme.span("xl"))
  table.insert(column, Theme.span("xl")) -- room for the switcher pill
  column:resetLayout()
  return column
end

-- -------------------------------------------------------------------------
-- B: Dashboard -- a fixed grid of summary tiles, never scrolls
-- -------------------------------------------------------------------------

local function dashTile(w, h, title, body, cb, viewport)
  local inner = VerticalGroup:new {
    align = "left",
    text(title, "small", { bold = true, grey = true, width = w - 2 * Theme.space.m }),
    Theme.span("s"),
    body,
  }
  -- a frame reports content + padding + border, so the content is held to the
  -- inside of the tile (top-left) and the tile is exactly w x h
  local edge = Theme.space.m + Theme.line.firm
  local box = FrameContainer:new {
    bordersize = Theme.line.firm,
    radius = Screen:scaleBySize(10),
    padding = Theme.space.m,
    margin = 0,
    color = Theme.BLACK,
    background = Theme.WHITE,
    TopContainer:new { dimen = Geom:new { w = w - 2 * edge, h = h - 2 * edge }, inner },
  }
  return cb and tap(box, cb, viewport) or box
end

local function dashLines(d, rows, w, viewport, inner_h)
  local col = VerticalGroup:new { align = "left" }
  -- plain text lines, each its own tap: the tile is the box
  local lh = math.min(Screen:scaleBySize(38), math.floor(inner_h / math.max(#rows, 1)))
  for _, row in ipairs(rows) do
    local count = Home.countText(row.count)
    local line = HorizontalGroup:new { align = "center" }
    if count ~= "" then
      table.insert(line, text(count, "title", { bold = true }))
      table.insert(line, Theme.hspan("s"))
    end
    table.insert(line, text(row.title .. "  \226\128\186", "body", { width = w }))
    table.insert(col, d:buildTile(row, w, lh, viewport, line))
  end
  return col
end

local function buildDashboard(d, width, viewport)
  local room = (d.proto_room or Screen:getHeight()) - Screen:scaleBySize(80) -- the pill
  local gap = Theme.space.m
  local half = math.floor((width - gap) / 2)
  local inner_w = width - 2 * Theme.space.m - 2 * Theme.line.firm
  local inner_half = half - 2 * Theme.space.m - 2 * Theme.line.firm

  -- row heights: hero 40%, then two rows sharing the rest
  local hero_h = math.floor(room * 0.32)
  local row_h = math.floor((room - hero_h - 3 * gap - Theme.space.m) / 2)

  -- hero: the book you are reading now, big
  local cards = Home.cards(d.entries)
  local hero_body
  local hero_cb
  if cards[1] then
    local c = cards[1]
    local ch = hero_h - 2 * (Theme.space.m + Theme.line.firm) - Screen:scaleBySize(44)
    local cw = math.floor(ch / 1.5)
    local tw = inner_w - cw - Theme.space.l
    local info = VerticalGroup:new {
      align = "left",
      TextBoxWidget:new { text = c.title, face = Theme.face("display"), bold = true, width = tw },
      text(c.author or "", "body", { grey = true, width = tw }),
      Theme.span("m"),
    }
    if c.fraction then
      table.insert(info, bar(tw, c.fraction))
      table.insert(info, Theme.span("xs"))
      table.insert(info, text(string.format("%d%%  \194\183  %s", math.floor(c.fraction * 100 + 0.5), c.progress_text or ""), "small", { width = tw }))
    end
    local more = readingTotal(d, cards) - 1
    if more > 0 then
      table.insert(info, Theme.span("s"))
      table.insert(info, text(string.format("+ %d more being read \226\128\186", more), "small", { bold = true, width = tw }))
    end
    hero_body = HorizontalGroup:new { align = "top", d:coverCell(c, cw, ch), Theme.hspan("l"), info }
    hero_cb = function() if d.open_book_cb then d.open_book_cb(c.book_id) end end
  else
    hero_body = text("Nothing being read yet.", "body", { grey = true, width = inner_w })
    hero_cb = function() openReading(d) end
  end
  local hero = dashTile(width, hero_h, "NOW READING", hero_body, hero_cb, viewport)
  d.reading_header = hero

  -- goal tile
  local goal, p = currentGoal(d)
  local goal_body
  if goal then
    goal_body = VerticalGroup:new {
      align = "left",
      HorizontalGroup:new {
        align = "bottom",
        text(string.format("%d", p.progress), "display", { bold = true }),
        text(string.format(" / %d %s", p.target, p.unit), "title", { grey = true }),
      },
      Theme.span("xs"),
      require("hardcover/lib/ui/goal_widgets").bar(inner_half, Screen:scaleBySize(12), p),
      Theme.span("s"),
      text(p.status, "small", { bold = true, width = inner_half }),
      text(Goals.leftText(p), "small", { grey = true, width = inner_half }),
    }
  else
    goal_body = text("No current goal", "small", { grey = true })
  end
  local goal_tile = dashTile(half, row_h, "GOAL", goal_body,
    function() if goal and d.goal_cb then d.goal_cb(goal) elseif d.goals_cb then d.goals_cb() end end, viewport)

  -- search tile
  local icon = Screen:scaleBySize(56)
  local search_tile = dashTile(half, row_h, "SEARCH", CenterContainer:new {
    dimen = Geom:new { w = inner_half, h = row_h - 2 * Theme.space.m - Theme.space.l - Theme.type.small * 2 },
    VerticalGroup:new {
      align = "center",
      IconWidget:new { icon = "appbar.search", width = icon, height = icon },
      Theme.span("s"),
      text("Find a book", "body", { grey = true }),
    },
  }, function() if d.search_cb then d.search_cb() end end, viewport)
  d.search_button = search_tile

  -- shelves and discover: each line its own tap
  local lines_h = row_h - 2 * (Theme.space.m + Theme.line.firm) - Screen:scaleBySize(44)
  local shelves_tile = dashTile(half, row_h, "SHELVES", dashLines(d, shelfRows(d), inner_half, viewport, lines_h), nil, viewport)
  local discover_tile = dashTile(half, row_h, "DISCOVER", dashLines(d, discoverRows(d), inner_half, viewport, lines_h), nil, viewport)

  local column = VerticalGroup:new {
    align = "left",
    Theme.span("m"),
    hero,
    Theme.span(gap),
    HorizontalGroup:new { goal_tile, Theme.hspan(gap), search_tile },
    Theme.span(gap),
    HorizontalGroup:new { shelves_tile, Theme.hspan(gap), discover_tile },
  }
  column:resetLayout()
  return column
end

-- -------------------------------------------------------------------------
-- C: Tabs -- one module per page, picked from a strip
-- -------------------------------------------------------------------------

local TABS = { "reading", "shelves", "goal", "discover" }
local TAB_LABEL = { reading = "Reading", shelves = "Shelves", goal = "Goal", discover = "Discover" }

local function buildTabs(d, width, viewport)
  local strip = HorizontalGroup:new { align = "center" }
  local icon = Screen:scaleBySize(30)
  local search_w = Screen:scaleBySize(54)
  local tab_w = math.floor((width - search_w - Theme.space.s * #TABS) / #TABS)
  d.proto_tabs = {}
  for _, key in ipairs(TABS) do
    local on = P.state.tab == key
    local t = Theme.button(TAB_LABEL[key], tab_w, {
      filled = on, h = Screen:scaleBySize(48), radius = 24, viewport = viewport,
      callback = function() P.state.tab = key; d:rebuild() end,
    })
    d.proto_tabs[key] = t
    table.insert(strip, t)
    table.insert(strip, Theme.hspan("s"))
  end
  local search = tap(Theme.box(search_w, Screen:scaleBySize(48),
    IconWidget:new { icon = "appbar.search", width = icon, height = icon }, { radius = 24 }),
    function() if d.search_cb then d.search_cb() end end, viewport)
  d.search_button = search
  table.insert(strip, search)

  local key = P.state.tab
  local page = VerticalGroup:new { align = "left" }
  if key == "reading" then
    local cards = Home.cards(d.entries)
    local n = readingTotal(d, cards)
    local heading = tap(Theme.sectionHeader(string.format("Reading %d", n), width,
      text("Open shelf \226\128\186", "small", { grey = true })), function() openReading(d) end, viewport)
    d.reading_header = heading
    table.insert(page, heading)
    table.insert(page, Theme.span("m"))
    table.insert(page, Modules.reading(d, width, viewport, 5))
  elseif key == "shelves" then
    table.insert(page, Theme.sectionHeader("Your shelves", width))
    table.insert(page, Theme.span("m"))
    -- full-width rows rather than tiles: there is room
    for _, row in ipairs(shelfRows(d)) do
      table.insert(page, d:buildTile(row, width, Screen:scaleBySize(80), viewport))
      table.insert(page, Theme.span("m"))
    end
  elseif key == "goal" then
    local more = text("All goals \226\128\186", "small", { grey = true })
    table.insert(page, tap(Theme.sectionHeader("Goal", width, more),
      function() if d.goals_cb then d.goals_cb() end end, viewport))
    table.insert(page, Theme.span("l"))
    table.insert(page, Modules.goal(d, width, viewport))
  elseif key == "discover" then
    table.insert(page, Theme.sectionHeader("Discover", width))
    table.insert(page, Theme.span("m"))
    for _, row in ipairs(discoverRows(d)) do
      table.insert(page, d:buildTile(row, width, Screen:scaleBySize(80), viewport))
      table.insert(page, Theme.span("m"))
    end
  end

  local column = VerticalGroup:new {
    align = "left",
    Theme.span("m"),
    strip,
    Theme.span("l"),
    page,
    Theme.span("xl"),
    Theme.span("xl"),
  }
  column:resetLayout()
  return column
end

local BUILDERS = { A = buildStack, B = buildDashboard, C = buildTabs }

function P.buildColumn(d, width, viewport)
  d.reading_header = nil
  return BUILDERS[d.prototype_variant](d, width, viewport)
end

-- -------------------------------------------------------------------------
-- The switcher pill: ‹  B · Dashboard  ›, plus the module state under it
-- -------------------------------------------------------------------------

function P.stateLine(key)
  if key == "A" then
    local shown, hidden = {}, {}
    for _, k in ipairs(P.state.order) do
      if P.state.hidden[k] then hidden[#hidden + 1] = k else shown[#shown + 1] = k end
    end
    return "order: " .. table.concat(shown, ", ") .. (#hidden > 0 and ("  |  hidden: " .. table.concat(hidden, ", ")) or "")
      .. (P.state.editing and "  |  editing" or "")
  elseif key == "B" then
    return "fixed grid, no scroll"
  else
    return "tab: " .. P.state.tab
  end
end

function P.wrap(d, frame)
  local def = P.current()
  local sw, sh = Screen:getWidth(), Screen:getHeight()
  local white = Blitbuffer.COLOR_WHITE
  local function label(s, size, bold)
    return TextWidget:new { text = s, face = Theme.face(size), bold = bold, fgcolor = white }
  end
  local arrow_w = Screen:scaleBySize(70)
  local mid_w = Screen:scaleBySize(380)
  local h = Screen:scaleBySize(64)
  local function cell(w, child)
    return CenterContainer:new { dimen = Geom:new { w = w, h = h }, child }
  end
  local prev = TapRow:new { callback = function() P.step(d, -1) end, cell(arrow_w, label("\226\128\185", "display", true)) }
  local nxt = TapRow:new { callback = function() P.step(d, 1) end, cell(arrow_w, label("\226\128\186", "display", true)) }
  local mid = cell(mid_w, VerticalGroup:new {
    align = "center",
    label(string.format("PROTOTYPE  %s \194\183 %s", def.key, def.name), "small", true),
    TextWidget:new { text = P.stateLine(def.key), face = Theme.face("label"), fgcolor = white, max_width = mid_w },
  })
  local pill = FrameContainer:new {
    bordersize = 0,
    radius = Screen:scaleBySize(32),
    background = Blitbuffer.COLOR_BLACK,
    padding = 0,
    margin = 0,
    HorizontalGroup:new { align = "center", prev, mid, nxt },
  }
  d.proto_prev, d.proto_next = prev, nxt
  local group = OverlapGroup:new {
    dimen = Geom:new { w = sw, h = sh },
    frame,
    BottomContainer:new {
      dimen = Geom:new { w = sw, h = sh - Screen:scaleBySize(16) },
      CenterContainer:new { dimen = Geom:new { w = sw, h = h }, pill },
    },
  }
  -- the pill is drawn last (on top), so it gets taps first
  function group:propagateEvent(event)
    for i = #self, 1, -1 do
      if self[i]:handleEvent(event) then return true end
    end
    return false
  end
  return group
end

return P
