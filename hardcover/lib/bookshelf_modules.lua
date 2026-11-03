-- Hardcover cards for Bookshelf's micro-modules (a reading goal and your stats).
--
-- The cards ship as a Bookshelf module pack: bookshelf_modules/ at the plugin
-- root holds one spec file per card, and Bookshelf scans every installed plugin
-- for that folder (see its micromodules/README.md). Keeping the specs there
-- instead of writing them into Bookshelf's own module folder means they update
-- with the plugin and are skipped when the plugin is disabled.
--
-- Cards draw only what is already saved on the device (no network on render),
-- so they read the same offline. Open the Goals or Stats screen to refresh them.

local _ = require("gettext")

local Modules = {}

-- ------------------------------------------------------------------ data

local function userId()
  local User = require("hardcover/lib/user")
  local SETTING = require("hardcover/lib/constants/settings")
  local ok, id = pcall(function() return User.settings and User.settings:readSetting(SETTING.USER_ID) end)
  return ok and id or nil
end

local function count(n, unit)
  n = math.floor(n + 0.5)
  if unit == "pages" then return n == 1 and _("1 page") or string.format(_("%d pages"), n) end
  return n == 1 and _("1 book") or string.format(_("%d books"), n)
end

-- The goals running today, with any queued offline finishes folded in. Returns
-- nil and a reason when there is no sign-in or nothing saved yet.
local function currentGoals(shelf_cache, queue, user_id, today)
  if not (shelf_cache and user_id) then return nil, "signed_out" end
  local Goals = require("hardcover/lib/goals")
  local goals = shelf_cache:goals(user_id)
  if not goals then return nil, "no_data" end
  if queue and not queue:isEmpty() then goals = queue:apply(goals, user_id) end
  today = today or Goals.today()
  return Goals.split(goals, today).current, nil, today
end

-- The goal the reader pinned in the card's settings, when it is still running,
-- else the one that ends soonest.
local function pick(current, goal_id)
  if goal_id ~= nil then
    for _, g in ipairs(current) do
      if tostring(g.id) == tostring(goal_id) then return g end
    end
  end
  return current[1]
end

-- The goal's numbers in short form, for the ring card's stat row: the facts the
-- bar card spells out in sentences, small enough that three of them sit side by
-- side. A ring card is read at a glance, so the labels are one or two words.
local function goalStats(p)
  local stats = {}
  local pace
  if p.done then pace = _("Done")
  elseif p.over then pace = _("Ended")
  elseif p.upcoming then pace = _("Not started")
  elseif p.delta >= 1 then pace = string.format(_("%d %s ahead"), math.floor(p.delta), p.unit)
  elseif p.delta <= -1 then pace = string.format(_("%d %s behind"), math.floor(-p.delta), p.unit)
  else pace = _("On pace") end
  stats[#stats + 1] = { label = _("Pace"), value = pace }
  if p.days_left and p.days_left > 0 and not p.done and not p.over then
    stats[#stats + 1] = { label = _("Time left"),
      value = p.days_left == 1 and _("1 day") or string.format(_("%d days"), p.days_left) }
  end
  if p.per_week then
    stats[#stats + 1] = { label = _("Per week"),
      value = p.unit == "pages" and string.format(_("%d pages"), math.ceil(p.per_week))
        or string.format(_("%.1f books"), p.per_week) }
  end
  return stats
end

-- One running goal as a card.
local function goalToCard(goal, today, finished_offline)
  local Goals = require("hardcover/lib/goals")
  local p = Goals.pace(goal, today, Goals.extra(goal, today, finished_offline))
  return {
    heading = goal.name,
    value = string.format("%d", math.floor(p.progress + 0.5)),
    suffix = " / " .. count(p.target, p.unit),
    fraction = p.fraction,
    sub = p.status,
    left = Goals.leftText(p),
    context = p.per_week_text,
    stats = goalStats(p),
  }
end

-- The goals a card can show as a list: the pinned one first when it is still
-- running, then the others soonest-ending first, so `limit` 2 is the pinned
-- goal and whatever ends next. nil and a reason when there is no sign-in, no
-- saved goals or none running.
function Modules.goalCards(shelf_cache, queue, user_id, finished_offline, today, goal_id, limit)
  local current, reason, day = currentGoals(shelf_cache, queue, user_id, today)
  if not current then return nil, reason end
  local first = pick(current, goal_id)
  if not first then return nil, "no_goal" end
  local cards = { goalToCard(first, day, finished_offline) }
  for _, goal in ipairs(current) do
    if #cards >= (limit or 1) then break end
    if goal ~= first then cards[#cards + 1] = goalToCard(goal, day, finished_offline) end
  end
  return cards
end

-- The goal that ends soonest of those running now (or the one pinned by id), as
-- a card.
function Modules.goalCard(shelf_cache, queue, user_id, finished_offline, today, goal_id)
  local cards, reason = Modules.goalCards(shelf_cache, queue, user_id,
    finished_offline, today, goal_id, 1)
  if not cards then return nil, reason end
  return cards[1]
end

-- This year's finished books, from the saved stats.
function Modules.statsCard(shelf_cache, user_id, year)
  if not (shelf_cache and user_id) then return nil, "signed_out" end
  local saved = shelf_cache:stats(user_id)
  if not saved then return nil, "no_data" end
  local Stats = require("hardcover/lib/stats")
  year = year or tonumber(os.date("%Y"))
  local s = Stats.compute(saved.rows, { year = year })
  local sub = {}
  if s.pages > 0 then sub[#sub + 1] = string.format(_("%d pages"), s.pages) end
  if s.ratings.average then sub[#sub + 1] = string.format(_("%.1f average rating"), s.ratings.average) end
  return {
    heading = string.format(_("Finished in %d"), year),
    value = string.format("%d", s.books),
    suffix = " " .. (s.books == 1 and _("book") or _("books")),
    sub = #sub > 0 and table.concat(sub, " \194\183 ") or nil,
    context = s.best_month and string.format(_("Best month: %s (%d)"),
      os.date("%B", os.time { year = year, month = s.best_month.month, day = 1 }), s.best_month.count) or nil,
  }
end

-- The running goals a card can be pinned to, for its settings dialog:
-- { { id =, label = }, ... }, soonest-ending first.
function Modules.goalChoices(shelf_cache, queue, user_id, today)
  local current = currentGoals(shelf_cache, queue, user_id, today)
  local out = {}
  for _, g in ipairs(current or {}) do
    out[#out + 1] = {
      id = g.id,
      label = string.format("%s \194\183 %s", g.name,
        count(g.target, g.metric == "page" and "pages" or "books")),
    }
  end
  return out
end

-- ------------------------------------------------------------------ cards

local function empty(ctx, text)
  local Kit = require("lib/bookshelf_module_kit")
  return Kit.valueCard {
    width = ctx.width, height = ctx.height, scale_pct = ctx.scale,
    heading = "Hardcover", sub = text,
  }
end

local function reasonText(reason)
  if reason == "signed_out" then return _("Sign in to Hardcover Sync.") end
  if reason == "no_goal" then return _("No current goal. Tap to set one.") end
  if reason == "no_books" then return _("No books finished this year yet.") end
  if reason == "no_plugin" then return _("Turn on Hardcover Sync.") end
  return _("Open Hardcover once to load this.")
end

-- Whether a cell is wide enough for a card to lay itself out sideways. The host
-- hands us ctx.shape when it knows the cell; the ratio covers a caller that
-- renders without one (a preview, the harness).
local function wideCell(ctx, w)
  local h = ctx.height
  if ctx.shape then return ctx.shape == "wide" end
  if not h or h <= 0 then return false end
  local Kit = require("lib/bookshelf_module_kit")
  local shape = Kit.shape and Kit.shape(w, h)
  if shape then return shape == "wide" end
  return w >= h * 1.6
end

-- One goal fills the card. A strip carries two, side by side, each with its
-- name, count and bar: the strip is long enough for a second goal, and the pace
-- line would be crowded in half of it.
local function draw(ctx, cards, reason)
  if not cards or #cards == 0 then return empty(ctx, reasonText(reason)) end
  local Kit = require("lib/bookshelf_module_kit")
  local sc = Kit.sc(ctx.scale)
  local w = math.max(50, ctx.width or 50)
  local gap = sc(12)
  -- The card keeps as much as the cell has room for, richest first: heading,
  -- number, bar, pace line, finish rate. A short cell keeps the number, its
  -- target and the bar and lets the words go, so a card can be small without
  -- being clipped -- the host only ever shrinks the whole card, which runs out
  -- of room before it runs out of lines.
  local function card(c, cw, top)
    local bar = c.fraction and Kit.progressBar {
      width = cw, height = sc(6), fraction = c.fraction,
    } or nil
    local function at(level)
      return Kit.valueCard {
        width = cw, height = ctx.height, scale_pct = ctx.scale,
        heading = level >= 3 and c.heading or nil,
        value = c.value,
        suffix = level >= 2 and c.suffix or nil,
        bar = bar, bar_fraction = c.fraction,
        sub = level >= 3 and c.sub or nil,
        context = level >= 4 and c.context or nil,
      }
    end
    -- The host shrinks a card to 60% before it gives up and clips, so a level is
    -- worth keeping only if it fits at that floor. Judged there, not at the
    -- current scale: a card that shortens itself to fit would be grown back by
    -- the host, which drops another line at the bigger type, and so on until
    -- only the number is left.
    local FLOOR = 60
    if not ctx.height then return at(top) end
    -- Words wider than the card would be cut to an ellipsis, so a cell too
    -- narrow for the goal's name gets the number and the bar instead.
    local TextWidget = require("lib/bookshelf_colour_text")
    local function fitsWidth(text, size)
      if not text then return true end
      local probe = TextWidget:new{ text = text, face = Kit.face(size, ctx.scale) }
      local ok, w = pcall(function() return probe:getSize().w end)
      if probe.free then probe:free() end
      return not ok or w <= cw
    end
    local rungs = (top >= 4) and { 4, 3, 1 } or { 3, 1 }
    if not (fitsWidth(c.heading, 15) and fitsWidth(c.sub, 13)) then rungs = { 1 } end
    -- Richest first. The last rung is the number and its bar alone: a target
    -- beside it would be cut to an ellipsis in a cell that small, which reads
    -- worse than no target at all.
    for _, level in ipairs(rungs) do
      local widget = at(level)
      local ok, size = pcall(function() return widget:getSize() end)
      local fits = ok and size and size.h * FLOOR / (ctx.scale or 100) <= ctx.height
      if fits then return widget end
    end
    return at(1)
  end
  -- Two goals need a strip. A 2x1 cell is wide too, but half of it is too
  -- narrow for a goal's name at the size the host grows the card to.
  if #cards > 1 and wideCell(ctx, w) and w >= 2.4 * ctx.height then
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local sep = sc(40)
    local half = math.floor((w - sep) / 2)
    local left, right = card(cards[1], half, 3), card(cards[2], half, 3)
    -- A rule between the goals, so the two halves read as two cards rather than
    -- one column of numbers. It is an unfilled bar: the bars' own track grey,
    -- which keeps the rule and the tracks in step under the shelf's dark theme,
    -- and as tall as the taller half. Its gutter is its own width, not the
    -- single gap a card uses: the rule sits at the card's midpoint, so a
    -- narrower one leaves the right column's first word only a few pixels away.
    local tall = math.max(left:getSize().h, right:getSize().h)
    return HorizontalGroup:new{ align = "top",
      left,
      HorizontalSpan:new{ width = math.floor(sep / 2) },
      Kit.progressBar { width = math.max(1, sc(2)), height = tall, fraction = 0 },
      HorizontalSpan:new{ width = math.ceil(sep / 2) },
      right }
  end
  -- A square cell is handed its whole inner width, so the heading, count and
  -- bar would sit against the frame; a wide or tall cell arrives already inset
  -- by the host. Step in here so every shape has the same breathing room.
  local shape = ctx.shape
  if not shape and ctx.height and ctx.height > 0 then
    shape = Kit.shape and Kit.shape(w, ctx.height)
  end
  local cw = w
  if shape == "square" then cw = math.max(50, w - 2 * Kit.sc(ctx.scale)(8)) end
  return card(cards[1], cw, 4)
end

-- -------------------------------------------------------------- ring card

-- A completion ring, painted row by row: each row of the annulus gives two
-- horizontal spans, and a span is split where the filled arc ends. Angles run
-- clockwise from the top. Only Color.paintRect is used (the card's ink may be a
-- colour), and the track repeats the rule Kit.progressBar uses so a ring card
-- and a bar card on the same shelf look alike.
local function ringWidget(size, thickness, fraction)
  local Kit = require("lib/bookshelf_module_kit")
  local Blitbuffer = require("ffi/blitbuffer")
  local Color = require("lib/bookshelf_color")
  local Widget = require("ui/widget/widget")
  local Geom = require("ui/geometry")

  local FILL = Kit.COLOR_PRIMARY or Blitbuffer.COLOR_BLACK
  local TRACK = Blitbuffer.Color8(0xCC)
  local ok_lum, lum = pcall(function() return FILL:getColor8().a end)
  if ok_lum and type(lum) == "number" then
    local card = (lum > 128) and 0x11 or 0xEE
    TRACK = Blitbuffer.Color8(math.floor(card + (lum - card) / 7 + 0.5))
  end

  -- LuaJIT has math.atan2, 5.3 spells it math.atan(y, x).
  local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
  local c = size / 2
  local r_in = math.max(0, c - thickness)
  local frac = math.max(0, math.min(1, fraction or 0))
  local rects = {}
  for y = 0, size - 1 do
    local dy = y + 0.5 - c
    if math.abs(dy) < c then
      local xo = math.sqrt(c * c - dy * dy)
      local xi = (math.abs(dy) < r_in) and math.sqrt(r_in * r_in - dy * dy) or 0
      local spans = { { c - xo, c - xi }, { c + xi, c + xo } }
      for _, span in ipairs(spans) do
        local run_x, run_w, run_fill
        for x = math.ceil(span[1] - 0.5), math.floor(span[2] - 0.5) do
          local t = atan2(x + 0.5 - c, -dy) / (2 * math.pi)
          if t < 0 then t = t + 1 end
          local fill = t < frac
          if fill ~= run_fill then
            if run_w then rects[#rects + 1] = { run_x, y, run_w, run_fill } end
            run_x, run_w, run_fill = x, 1, fill
          elseif run_w then
            run_w = run_w + 1
          end
        end
        if run_w then rects[#rects + 1] = { run_x, y, run_w, run_fill } end
      end
    end
  end
  for _, r in ipairs(rects) do
    r[4] = r[4] and FILL or TRACK
  end

  local Ring = Widget:extend{}
  function Ring:init() self.dimen = Geom:new{ w = size, h = size } end
  function Ring:getSize() return Geom:new{ w = size, h = size } end
  function Ring:paintTo(bb, x, y)
    for _, r in ipairs(rects) do
      Color.paintRect(bb, x + r[1], y + r[2], r[3], 1, r[4])
    end
  end
  return Ring:new{}
end

-- The goal's numbers as a row of labelled stats, for a wide ring card: the pace,
-- the time left and the weekly rate, each under its own small label, so a strip
-- uses its width for three facts at a glance instead of a paragraph. nil when
-- the row is wider than the column, and the caller falls back to the sentences.
local function statRow(ctx, stats, width)
  local Kit = require("lib/bookshelf_module_kit")
  local TextWidget = require("lib/bookshelf_colour_text")
  local HorizontalGroup = require("ui/widget/horizontalgroup")
  local HorizontalSpan = require("ui/widget/horizontalspan")
  local VerticalGroup = require("ui/widget/verticalgroup")
  local VerticalSpan = require("ui/widget/verticalspan")
  local sc = Kit.sc(ctx.scale)
  local gap = sc(26)
  local row = HorizontalGroup:new{ align = "top" }
  local used = 0
  for i, stat in ipairs(stats) do
    local label = TextWidget:new{ text = stat.label, face = Kit.face(12, ctx.scale),
      fgcolor = Kit.COLOR_MUTED }
    local value = TextWidget:new{ text = stat.value, face = Kit.face(15, ctx.scale),
      fgcolor = Kit.COLOR_PRIMARY }
    local col = math.max(label:getSize().w, value:getSize().w)
    if used + col + (i > 1 and gap or 0) > width then return nil end
    if i > 1 then
      row[#row + 1] = HorizontalSpan:new{ width = gap }
      used = used + gap
    end
    row[#row + 1] = VerticalGroup:new{ align = "left", label,
      VerticalSpan:new{ width = sc(2) }, value }
    used = used + col
  end
  return row
end

-- The card's text, dropping the quietest lines when the cell is too short for
-- all of them. `opts.stats` lays the goal's numbers out as a row of labelled
-- stats, which only a wide column has room for; `opts.extra` adds the goal's
-- remaining time, which a strip has the room for; `opts.value_pts` sets the
-- size of the big number; `opts.brief` keeps it to the name and the count,
-- which is all a small tile can hold.
local function ringText(ctx, card, width, height, opts)
  opts = opts or {}
  local Kit = require("lib/bookshelf_module_kit")
  local TextWidget = require("lib/bookshelf_colour_text")
  local VerticalGroup = require("ui/widget/verticalgroup")
  local VerticalSpan = require("ui/widget/verticalspan")
  local HorizontalGroup = require("ui/widget/horizontalgroup")
  local sc = Kit.sc(ctx.scale)

  local fh, bh = Kit.face(15, ctx.scale, { bold = true })
  local fbig, bbig = Kit.face(opts.value_pts or 20, ctx.scale, { bold = true })
  local num = TextWidget:new{ text = card.value, face = fbig, bold = bbig,
    fgcolor = Kit.COLOR_PRIMARY, max_width = width }
  local value = num
  if card.suffix then
    local suf = TextWidget:new{ text = card.suffix, face = Kit.face(14, ctx.scale),
      fgcolor = Kit.COLOR_PRIMARY, max_width = math.max(10, width - num:getSize().w) }
    local dy = math.max(0, num:getBaseline() - suf:getBaseline())
    value = HorizontalGroup:new{ align = "top", num,
      VerticalGroup:new{ align = "left", VerticalSpan:new{ width = dy }, suf } }
  end

  -- One entry per line: its widget, the space above it, and whether the layout
  -- may drop it when the cell is short. The goal's name is not optional: it is
  -- what tells one card from another on a shelf, so a cell too short for the
  -- rest shrinks the type instead of losing it.
  local lines = {
    { w = TextWidget:new{ text = card.heading, face = fh, bold = bh,
        fgcolor = Kit.COLOR_MUTED, max_width = width } },
    { w = value, gap = sc(2) },
  }
  -- A wide column has room for the goal's numbers as a row of labelled stats,
  -- which reads at a glance. Where the row does not fit, the sentences below say
  -- the same things in more words: where the goal stands and how long is left
  -- share a line where the column fits both, and stay apart where it does not.
  local quiet = Kit.face(13, ctx.scale)
  local stats = (not opts.brief and opts.stats and card.stats)
    and statRow(ctx, card.stats, width) or nil
  local joined
  if not stats and not opts.brief and opts.join and card.sub and card.left then
    local line = TextWidget:new{ text = card.sub .. " \194\183 " .. card.left,
      face = quiet, fgcolor = Kit.COLOR_MUTED }
    if line:getSize().w <= width then joined = line end
  end
  if stats then
    lines[#lines + 1] = { w = stats, gap = sc(6) }
  elseif joined then
    lines[#lines + 1] = { w = joined, gap = sc(4), opt = true }
  elseif not opts.brief then
    if card.sub then
      lines[#lines + 1] = { w = TextWidget:new{ text = card.sub,
        face = quiet, fgcolor = Kit.COLOR_MUTED, max_width = width },
        gap = sc(4), opt = true }
    end
    if opts.extra and card.left then
      lines[#lines + 1] = { w = TextWidget:new{ text = card.left,
        face = quiet, fgcolor = Kit.COLOR_MUTED, max_width = width },
        gap = sc(3), opt = true }
    end
  end
  if not stats and not opts.brief and card.context then
    -- A sentence cut off mid-word reads worse than no sentence, so the context
    -- line is left out when the column is too narrow for all of it.
    local line = TextWidget:new{ text = card.context,
      face = Kit.face(13, ctx.scale, { italic = true }), fgcolor = Kit.COLOR_PRIMARY }
    if line:getSize().w <= width then
      lines[#lines + 1] = { w = line, gap = sc(3), opt = true }
    end
  end

  local function build(drop)
    local g = VerticalGroup:new{ align = "left" }
    for i, line in ipairs(lines) do
      if not (drop and drop[i]) then
        if #g > 0 and line.gap then g[#g + 1] = VerticalSpan:new{ width = line.gap } end
        g[#g + 1] = line.w
      end
    end
    return g
  end

  local g, drop = build(), {}
  if height then
    for i = #lines, 1, -1 do
      if g:getSize().h <= height then break end
      if lines[i].opt then
        drop[i] = true
        g = build(drop)
      end
    end
  end
  return g
end

-- The ring and the percentage in its hole, sized from the ring's inner diameter
-- rather than from a fixed point size: too big and the text spills onto the
-- stroke in a small cell, too small and it is unreadable. Measure without
-- max_width, which would hide the overflow by truncating it, and shrink until
-- it fits the hole in both directions.
local function ringWithPct(ctx, size, fraction)
  local Kit = require("lib/bookshelf_module_kit")
  local sc = Kit.sc(ctx.scale)
  local TextWidget = require("lib/bookshelf_colour_text")
  local OverlapGroup = require("ui/widget/overlapgroup")
  local CenterContainer = require("ui/widget/container/centercontainer")
  local Geom = require("ui/geometry")

  local stroke = math.max(sc(5), math.floor(size / 9 + 0.5))
  local inner = math.max(10, size - 2 * stroke)
  local Screen = require("device").screen
  local px_per_pt = Screen:scaleBySize(100) / 100
  if type(px_per_pt) ~= "number" or px_per_pt <= 0 then px_per_pt = 1 end
  local label = string.format("%d%%", math.floor(fraction * 100 + 0.5))
  local limit = math.floor(inner * 0.72)
  local pct, pts = nil, math.max(8, math.floor(limit / px_per_pt))
  for _ = 1, 5 do
    local probe = TextWidget:new{ text = label,
      face = Kit.face(pts, ctx.scale, { bold = true }), bold = true,
      fgcolor = Kit.COLOR_PRIMARY }
    local s = probe:getSize()
    local worst = math.max(s.w, s.h)
    if worst <= limit then
      pct = TextWidget:new{ text = label,
        face = Kit.face(pts, ctx.scale, { bold = true }), bold = true,
        fgcolor = Kit.COLOR_PRIMARY, max_width = limit }
      break
    end
    if pts <= 8 then break end
    pts = math.max(8, math.floor(pts * limit / worst))
  end

  local ring = OverlapGroup:new{ dimen = Geom:new{ w = size, h = size },
    ringWidget(size, stroke, fraction) }
  if pct then
    ring[#ring + 1] = CenterContainer:new{ dimen = Geom:new{ w = size, h = size }, pct }
  end
  return ring
end

-- The ring card, one goal at a time: a strip sets the ring beside the goal's
-- numbers, laid out as a row of labelled stats so the card's width carries three
-- facts rather than one paragraph. A square or tall cell has room for the name,
-- the count and a ring that fills the rest of it, and no more.
local function ringCard(ctx, cards, reason)
  if not cards or #cards == 0 then return empty(ctx, reasonText(reason)) end
  local Kit = require("lib/bookshelf_module_kit")
  local sc = Kit.sc(ctx.scale)
  local HorizontalGroup = require("ui/widget/horizontalgroup")
  local HorizontalSpan = require("ui/widget/horizontalspan")
  local VerticalGroup = require("ui/widget/verticalgroup")
  local VerticalSpan = require("ui/widget/verticalspan")
  local CenterContainer = require("ui/widget/container/centercontainer")
  local Geom = require("ui/geometry")

  local w = math.max(50, ctx.width or 50)
  local h = ctx.height
  local gap = sc(12)
  local wide = wideCell(ctx, w)

  local card = cards[1]
  local fraction = card.fraction or 0
  if wide then
    -- The ring takes about a third of the width, not half: a ring that fills a
    -- strip leaves its numbers a column too narrow to say anything in.
    local size = math.floor(math.min((h or sc(150)) * 0.94, w * 0.34) + 0.5)
    size = math.max(sc(44), size)
    local col = math.max(60, w - size - gap)
    return HorizontalGroup:new{ align = "center",
      ringWithPct(ctx, size, fraction),
      HorizontalSpan:new{ width = gap },
      VerticalGroup:new{ align = "left",
        ringText(ctx, card, col, h,
          { stats = true, extra = true, join = true, value_pts = 26 }) } }
  end

  -- The ring over the goal's name and count, centred so a tall cell keeps its
  -- card in the middle of the cell. Nothing else: at this size the pace and the
  -- days left would be a crowded line of small type.
  if h then
    local text = ringText(ctx, card, w, nil, { brief = true, value_pts = 22 })
    local size = math.floor(math.min(w * 0.94,
      h - text:getSize().h - gap - sc(4)) + 0.5)
    if size >= sc(44) then
      return CenterContainer:new{ dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new{ align = "center",
          ringWithPct(ctx, size, fraction),
          VerticalSpan:new{ width = gap },
          text } }
    end
    -- A cell too short for a ring and a name takes the ring alone, with the
    -- percentage in its hole. That is what lets the card be one cell wide: at
    -- that size a name would be cut off, and a ring running past the cell's
    -- edge says less than one that fits inside it.
    local tile = math.max(sc(24), math.floor(math.min(w, h) * 0.94 + 0.5))
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h },
      ringWithPct(ctx, tile, fraction) }
  end

  -- No cell height to work from: the ring goes beside the text instead.
  local size = math.max(sc(44), math.floor(math.min(w * 0.9, w * 0.4) + 0.5))
  local col = math.max(60, w - size - gap)
  return HorizontalGroup:new{ align = "center",
    ringWithPct(ctx, size, fraction),
    HorizontalSpan:new{ width = gap },
    VerticalGroup:new{ align = "left", ringText(ctx, card, col, h, { value_pts = 20 }) } }
end

-- Render entry points for the pack specs in bookshelf_modules/. The specs find
-- the plugin instance themselves (Kit.plugin); a nil instance means it is off,
-- and the card says so rather than sitting empty.
local function goalsFor(a, ctx, limit)
  local queue = a.goal_queue
  local offline = a.dialog_manager and a.dialog_manager:finishedOffline() or 0
  local pinned = ctx.config and ctx.config:get("goal")
  return Modules.goalCards(a.shelf_cache, queue, userId(), offline, nil, pinned, limit)
end

function Modules.goalWidget(a, ctx)
  if not a then return draw(ctx, nil, "no_plugin") end
  return draw(ctx, goalsFor(a, ctx, 2))
end

function Modules.goalRingWidget(a, ctx)
  if not a then return ringCard(ctx, nil, "no_plugin") end
  -- One goal: two rings on a strip left neither room for its own numbers.
  return ringCard(ctx, goalsFor(a, ctx, 1))
end

function Modules.statsWidget(a, ctx)
  if not a then return draw(ctx, nil, "no_plugin") end
  return draw(ctx, { Modules.statsCard(a.shelf_cache, userId()) })
end

-- ------------------------------------------------------------- year card

-- Thousands, for a total a reader reads at a glance ("12,480 pages").
local function grouped(n)
  local s = tostring(math.floor(n + 0.5))
  local body, commas = s:reverse():gsub("(%d%d%d)", "%1,")
  local out = body:reverse()
  if commas > 0 then out = out:gsub("^,", "") end
  return out
end

-- This year in twelve bars, from the saved stats: the pages (or the books, when
-- no edition has a page count) each month, the total, and the biggest month.
function Modules.yearCard(shelf_cache, user_id, year)
  if not (shelf_cache and user_id) then return nil, "signed_out" end
  local saved = shelf_cache:stats(user_id)
  if not saved then return nil, "no_data" end
  local Stats = require("hardcover/lib/stats")
  year = year or tonumber(os.date("%Y"))
  local s = Stats.compute(saved.rows, { year = year })
  if s.books == 0 then return nil, "no_books" end
  -- Pages say more than books: one long book is not the same month as three
  -- short ones, and the stats keep both series.
  local pages = s.pages > 0
  local months = pages and s.pages_months or s.months
  local peak, peak_month = 0, nil
  for m = 1, 12 do
    if months[m] > peak then peak, peak_month = months[m], m end
  end
  local labels = {}
  for m = 1, 12 do
    labels[m] = os.date("%b", os.time{ year = year, month = m, day = 1 })
  end
  return {
    year = year,
    months = months,
    labels = labels,
    peak = peak,
    peak_month = peak_month,
    unit = pages and _("pages") or _("books"),
    total = pages and s.pages or s.books,
    -- The month still counting, drawn hollow: on e-ink a shade of grey is not
    -- a state, and a full bar for a month that is half over reads as a drop.
    current = (year == tonumber(os.date("%Y"))) and tonumber(os.date("%m")) or nil,
  }
end

-- The twelve bars, painted the way the ring is: the card's ink, one rect per
-- bar, heights from the biggest month. Bar widths are whole pixels and the row
-- is centred, so the months stay evenly spaced at any cell width.
local function monthChart(ctx, data, width, height)
  local Kit = require("lib/bookshelf_module_kit")
  local Blitbuffer = require("ffi/blitbuffer")
  local Color = require("lib/bookshelf_color")
  local Widget = require("ui/widget/widget")
  local Geom = require("ui/geometry")
  local sc = Kit.sc(ctx.scale)

  local TextWidget = require("lib/bookshelf_colour_text")
  local ink = Kit.COLOR_PRIMARY or Blitbuffer.COLOR_BLACK
  local gap = math.max(1, sc(3))
  local bar_w = math.max(1, math.floor((width - 11 * gap) / 12))
  local w = bar_w * 12 + gap * 11
  local h = math.max(1, height)
  local peak = math.max(1, data.peak or 1)
  local months, current = data.months, data.current

  -- The month names go under the bars where they fit: every month when the
  -- bars are wide enough, every third one when they are not, and none at all
  -- in a cell too short to hold them. A row of bars with no months at all is a
  -- shape rather than a year.
  local names, widest = {}, 0
  if data.labels then
    for m = 1, 12 do
      names[m] = TextWidget:new{ text = data.labels[m],
        face = Kit.face(9, ctx.scale), fgcolor = Kit.COLOR_MUTED }
      widest = math.max(widest, names[m]:getSize().w)
    end
  end
  local step = 0
  if widest > 0 and h >= sc(56) then
    if bar_w >= widest + sc(2) then step = 1
    elseif bar_w * 3 >= widest + sc(2) then step = 3 end
  end
  local labels = step > 0
  local label_h = labels and sc(15) or 0
  local bars_h = math.max(1, h - label_h)

  local Chart = Widget:extend{}
  function Chart:init() self.dimen = Geom:new{ w = w, h = h } end
  function Chart:getSize() return Geom:new{ w = w, h = h } end
  function Chart:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
    for m = 1, 12 do
      local v = months[m] or 0
      if v > 0 then
        local bh = math.max(sc(2), math.floor(bars_h * v / peak + 0.5))
        local bx, by = x + (m - 1) * (bar_w + gap), y + bars_h - bh
        if m == current then
          -- Hollow: the month is still counting, so its bar is a shape rather
          -- than a measurement. Four sides, thin enough to stay a bar.
          local t = math.max(1, sc(1))
          Color.paintRect(bb, bx, by, bar_w, t, ink)
          Color.paintRect(bb, bx, y + h - t, bar_w, t, ink)
          if bh > 2 * t then
            Color.paintRect(bb, bx, by, t, bh, ink)
            Color.paintRect(bb, bx + bar_w - t, by, t, bh, ink)
          end
        else
          Color.paintRect(bb, bx, by, bar_w, bh, ink)
        end
      end
    end
    if labels then
      for m = 1, 12, step do
        local name = names[m]
        local lw = name:getSize().w
        name:paintTo(bb, x + (m - 1) * (bar_w + gap) + math.floor((bar_w - lw) / 2),
          y + bars_h + sc(2))
      end
    end
  end
  return Chart:new{}
end

-- The card: the year and its total, the twelve bars, and the month that carried
-- the year. A wide cell puts the words beside the bars; a short one gives up the
-- caption before it gives up the bars.
local function yearDraw(ctx, data, reason)
  if not data then return empty(ctx, reasonText(reason)) end
  local Kit = require("lib/bookshelf_module_kit")
  local TextWidget = require("lib/bookshelf_colour_text")
  local VerticalGroup = require("ui/widget/verticalgroup")
  local VerticalSpan = require("ui/widget/verticalspan")
  local HorizontalGroup = require("ui/widget/horizontalgroup")
  local HorizontalSpan = require("ui/widget/horizontalspan")
  local CenterContainer = require("ui/widget/container/centercontainer")
  local Geom = require("ui/geometry")
  local sc = Kit.sc(ctx.scale)

  local w = math.max(50, ctx.width or 50)
  local h = ctx.height
  local gap = sc(8)

  -- The year and its total. Built per width, because a wide cell gives the
  -- words a column and the bars the rest: without the limit a long total would
  -- push the bars off the card.
  local function title(width)
    local heading = TextWidget:new{ text = tostring(data.year),
      face = Kit.face(15, ctx.scale, { bold = true }), bold = true,
      fgcolor = Kit.COLOR_MUTED, max_width = width }
    local value = TextWidget:new{ text = grouped(data.total),
      face = Kit.face(26, ctx.scale, { bold = true }), bold = true,
      fgcolor = Kit.COLOR_PRIMARY, max_width = width }
    local suffix = TextWidget:new{ text = " " .. data.unit,
      face = Kit.face(14, ctx.scale), fgcolor = Kit.COLOR_PRIMARY,
      max_width = math.max(10, (width or w) - value:getSize().w) }
    local dy = math.max(0, value:getBaseline() - suffix:getBaseline())
    return VerticalGroup:new{ align = "left",
      heading, VerticalSpan:new{ width = sc(2) },
      HorizontalGroup:new{ align = "top", value,
        VerticalGroup:new{ align = "left", VerticalSpan:new{ width = dy }, suffix } } }
  end
  local caption
  if data.peak_month then
    caption = TextWidget:new{ text = string.format(_("Best: %s"),
        os.date("%B", os.time{ year = data.year, month = data.peak_month, day = 1 })),
      face = Kit.face(13, ctx.scale), fgcolor = Kit.COLOR_MUTED, max_width = w }
  end

  -- A wide cell: the words on the left, the year's shape on the right, where a
  -- strip has room for both. The chart gets what the words do not take, and the
  -- words never take more than half, so a long total cannot squeeze the year
  -- flat.
  if wideCell(ctx, w) and h then
    local words_w = math.min(title(nil):getSize().w, math.floor(w * 0.5))
    local chart_w = math.max(sc(60), w - words_w - gap)
    local column = VerticalGroup:new{ align = "left", title(words_w) }
    if caption then
      column[#column + 1] = VerticalSpan:new{ width = sc(4) }
      column[#column + 1] = caption
    end
    return HorizontalGroup:new{ align = "center",
      column,
      HorizontalSpan:new{ width = gap },
      CenterContainer:new{ dimen = Geom:new{ w = chart_w, h = h },
        monthChart(ctx, data, chart_w, math.max(sc(24), math.floor(h * 0.84))) } }
  end

  local text = title(w)
  local text_h = text:getSize().h
  if not h then
    -- The start menu has no cell: take a natural height for the bars.
    return VerticalGroup:new{ align = "left", text, VerticalSpan:new{ width = gap },
      monthChart(ctx, data, w, sc(70)) }
  end
  local room = h - text_h - gap
  if caption then
    if room - caption:getSize().h - sc(3) >= sc(24) then
      room = room - caption:getSize().h - sc(3)
    else
      caption = nil
    end
  end
  local stack = VerticalGroup:new{ align = "left", text, VerticalSpan:new{ width = gap },
    monthChart(ctx, data, w, math.max(sc(16), room)) }
  if caption then
    stack[#stack + 1] = VerticalSpan:new{ width = sc(6) }
    stack[#stack + 1] = caption
  end
  return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, stack }
end

function Modules.yearWidget(a, ctx)
  if not a then return yearDraw(ctx, nil, "no_plugin") end
  return yearDraw(ctx, Modules.yearCard(a.shelf_cache, userId()))
end

-- The goal card's own settings (long press on the card): pin it to one of the
-- running goals, or leave it on Automatic. A pinned goal that has since ended
-- falls back to Automatic, which is what the card is already showing. Adding the
-- card twice and pinning each to a different goal shows two goals at once.
function Modules.goalSettings(a, ctx)
  if not (ctx and ctx.config) then return end
  local UIManager = require("ui/uimanager")
  local ButtonDialog = require("ui/widget/buttondialog")
  local Kit = require("lib/bookshelf_module_kit")

  local choices = a and Modules.goalChoices(a.shelf_cache, a.goal_queue, userId()) or {}
  local pinned = ctx.config:get("goal")
  local active
  for _, c in ipairs(choices) do
    if pinned ~= nil and tostring(c.id) == tostring(pinned) then active = c.id end
  end

  local buttons = {}
  local dialog
  local function close(setting, value)
    return function()
      UIManager:close(dialog)
      if setting == "delete" then ctx.config:delete("goal") else ctx.config:set("goal", value) end
    end
  end

  buttons[#buttons + 1] = { Kit.radioRow {
    label = _("Automatic (ends soonest)"),
    active = active == nil,
    on_pick = close("delete"),
  } }
  for _, c in ipairs(choices) do
    buttons[#buttons + 1] = { Kit.radioRow {
      label = c.label,
      active = active ~= nil and tostring(c.id) == tostring(active),
      on_pick = close("set", c.id),
    } }
  end
  if #choices == 0 then
    buttons[#buttons + 1] = { { text = _("No goal is running right now."), callback = function() end } }
  end

  dialog = ButtonDialog:new(Kit.withClose {
    title = _("Which goal to show"), title_align = "center", width_factor = 0.7,
    buttons = buttons,
  })
  UIManager:show(dialog)
end

-- Opens one of the plugin's screens (showGoals, showStats) with no host widget,
-- so it covers the start menu instead of sitting in a dialog.
function Modules.openScreen(a, name)
  local dm = a and a.dialog_manager
  if dm and dm[name] then dm[name](dm) end
end

-- ------------------------------------------------------------------ cleanup

-- 2.3.1 and older wrote a stub file per card into Bookshelf's own module folder
-- (<settings>/bookshelf/micromodules). The cards are a plugin pack now, so those
-- stubs are dead files that log a warning on every Bookshelf scan, and would
-- shadow the pack if the plugin were ever downgraded. Remove the ones carrying
-- our marker and leave anything else in that folder alone.
local STUB_MARKER = "-- Written by Hardcover Sync"

local function firstLine(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local line = f:read(#STUB_MARKER)
  f:close()
  return line
end

-- Returns true when at least one stub was deleted.
function Modules.cleanStubs(dir)
  if not dir then
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok then return false end
    dir = DataStorage:getSettingsDir() .. "/bookshelf/micromodules"
  end
  local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
  if not ok_lfs or lfs.attributes(dir, "mode") ~= "directory" then return false end

  local removed = false
  for name in lfs.dir(dir) do
    if name:sub(-4) == ".lua" then
      local path = dir .. "/" .. name
      if firstLine(path) == STUB_MARKER and os.remove(path) then removed = true end
    end
  end
  return removed
end

return Modules