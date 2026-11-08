-- Hardcover cards for Bookshelf's micro-modules.
--
-- The cards ship as a Bookshelf module pack: bookshelf_modules/ at the plugin
-- root holds one spec file per card, and Bookshelf scans every installed plugin
-- for that folder (see its micromodules/README.md). Keeping the specs there
-- instead of writing them into Bookshelf's own module folder means they update
-- with the plugin and are skipped when the plugin is disabled.
--
-- Cards draw only what is already saved on the device (no network on render),
-- so they read the same offline. Open Goals, Stats or Want to Read to refresh.

local _ = require("gettext")

local Modules = {}

local shelfModule
local function setting(ctx, name, default)
  local found = shelfModule and shelfModule(ctx)
  local value
  if found then value = found.module[name]
  elseif ctx.config then value = ctx.config:get(name) end
  if value == nil then return default end
  return value
end

local function grouped(n)
  local s = tostring(math.floor(n + 0.5))
  local body, commas = s:reverse():gsub("(%d%d%d)", "%1,")
  local out = body:reverse()
  if commas > 0 then out = out:gsub("^,", "") end
  return out
end

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
    -- A square cell at the host's largest type can be too narrow for a long
    -- goal name; "Goal" still says what the number belongs to.
    short_heading = _("Goal"),
    value = string.format("%d", math.floor(p.progress + 0.5)),
    suffix = " / " .. count(p.target, p.unit),
    -- When the cell is too narrow for " / 70 books", the target still fits
    -- without the unit: the bar and the heading say what is being counted.
    short_suffix = string.format(" / %d", math.floor(p.target + 0.5)),
    fraction = p.fraction,
    sub = p.status,
    left = Goals.leftText(p),
    context = p.per_week_text,
    stats = goalStats(p),
    pace_fraction = p.pace_fraction,
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
    -- When the host has grown the type too large for the full heading, the
    -- year alone still says which reading year the number belongs to.
    short_heading = tostring(year),
    value = string.format("%d", s.books),
    suffix = " " .. (s.books == 1 and _("book") or _("books")),
    sub = #sub > 0 and table.concat(sub, " \194\183 ") or nil,
    context = s.best_month and string.format(_("Best month: %s (%d)"),
      os.date("%B", os.time { year = year, month = s.best_month.month, day = 1 }), s.best_month.count) or nil,
    facts = {
      { value = grouped(s.pages), label = _("Pages read") },
      { value = s.average_pages and grouped(s.average_pages) or "—", label = _("Average pages") },
    },
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

-- Full-history cards never infer lifetime totals from the old, latest-read
-- dashboard rows, nor pass a capped download off as a complete library.
local function historyFor(shelf_cache, user_id)
  if not user_id then return nil, "signed_out" end
  local saved = shelf_cache and shelf_cache:stats(user_id)
  if not (saved and saved.history) then return nil, "no_history" end
  if saved.complete == false then return nil, "incomplete_history" end
  return saved.history, nil, saved
end

local TOTAL_LABELS = {
  authors = _("Authors read"), books = _("Books read"),
  five_star = _("Five-star books"), rereads = _("Rereads"),
}

local function lifetimeTotals(shelf_cache, user_id)
  local history, reason = historyFor(shelf_cache, user_id)
  if not history then return nil, reason end
  local totals = { authors = 0, books = 0, five_star = 0, rereads = 0 }
  local books, authors = {}, {}
  for _, row in ipairs(history) do
    local id = tostring(row.book_id)
    -- Hardcover normally has one entry per book. Do not double-count a book
    -- if an imported library contains duplicates.
    local reads = row.completions or 1
    books[id] = math.max(books[id] or 0, reads)
    for _, author in ipairs(row.authors or {}) do
      local key = author.id and ("id:" .. tostring(author.id)) or ("slug:" .. author.slug)
      authors[key] = true
    end
  end
  local rated = {}
  for _, row in ipairs(history) do
    if row.rating == 5 then rated[tostring(row.book_id)] = true end
  end
  for _, reads in pairs(books) do
    totals.books = totals.books + 1
    totals.rereads = totals.rereads + math.max(0, reads - 1)
  end
  for _id in pairs(authors) do totals.authors = totals.authors + 1 end
  for _id in pairs(rated) do totals.five_star = totals.five_star + 1 end
  return totals
end

local function totalOf(totals, kind)
  return { value = tostring(totals[kind]), sub = TOTAL_LABELS[kind] }
end

function Modules.totalCard(shelf_cache, user_id, kind)
  local totals, reason = lifetimeTotals(shelf_cache, user_id)
  if not totals then return nil, reason end
  return totalOf(totals, kind)
end

-- A deterministic daily choice. Fit-search and picker renders never advance
-- it. An explicit Another tap adds an offset local to this card and day.
local function dailyPick(candidates, today, offset)
  if #candidates == 0 then return nil end
  local seed = tonumber((today:gsub("%-", ""))) or 0
  return candidates[(seed + (offset or 0)) % #candidates + 1]
end

function Modules.memoryCard(shelf_cache, user_id, today, offset, window, reach)
  local history, reason, saved = historyFor(shelf_cache, user_id)
  if not history then return nil, reason end
  today = today or os.date("%Y-%m-%d")
  window = window or "month"
  -- Use the goal calendar's date arithmetic, not seconds or day-of-year:
  -- a seven-day anniversary window crosses New Year and handles leap years.
  local Goals = require("hardcover/lib/goals")
  local anchor, year = Goals.parseDate(today), tonumber(today:sub(1, 4))
  -- Each window pass asks again for the same dates; parse each one once.
  local distances = {}
  local function distance(date)
    if #date < 10 then return nil end
    local nearest = distances[date]
    if nearest == nil then
      for shift = -1, 1 do
        local stamp = Goals.parseDate(tostring(year + shift) .. date:sub(5, 10))
        if stamp then nearest = math.min(nearest or math.huge, math.abs(stamp - anchor)) end
      end
      distances[date] = nearest or false
    end
    return nearest or nil
  end
  local windows = window == "day" and { "day", "week", "month" }
    or window == "week" and { "week", "month" } or { "month" }
  local candidates, seen = {}, {}
  local matched
  for _, current in ipairs(windows) do
    for _, row in ipairs(history) do
      for _, date in ipairs(row.reads or {}) do
        local key = tostring(row.book_id) .. ":" .. date
        local prior = date:sub(1, 4) < today:sub(1, 4)
        local in_reach = reach ~= "last_year" or tonumber(date:sub(1, 4)) == tonumber(today:sub(1, 4)) - 1
        local fits = #date >= 7 and date:sub(6, 7) == today:sub(6, 7)
        if current ~= "month" then
          local days = distance(date)
          fits = days ~= nil and days <= (current == "day" and 0 or 3)
        end
        if prior and in_reach and fits and not seen[key] then
          seen[key] = true
          candidates[#candidates + 1] = { book_id = row.book_id, title = row.title,
            rating = row.rating, image = row.image, date = date,
            author = row.authors and row.authors[1] and row.authors[1].name }
        end
      end
    end
    if #candidates > 0 then matched = current; break end
  end
  table.sort(candidates, function(a, b)
    if a.date ~= b.date then return a.date > b.date end
    return a.book_id < b.book_id
  end)
  local chosen = dailyPick(candidates, today, offset)
  if not chosen then return nil, "no_memories" end
  chosen.candidates, chosen.stale, chosen.window = #candidates, saved.stale, matched
  return chosen
end

-- Select from the saved Want to Read membership before decoding a book. A
-- large TBR costs one small membership read and one book, not every cover and
-- description. Only dates before this calendar month qualify as rediscovery.
function Modules.tbrCard(shelf_store, user_id, today, offset)
  if not user_id then return nil, "signed_out" end
  local members, meta
  if shelf_store then members, meta = shelf_store:members(user_id, 1) end
  if not members then return nil, "no_tbr" end
  if not meta.complete then return nil, "incomplete_tbr" end
  today = today or os.date("%Y-%m-%d")
  local candidates = {}
  for _, member in ipairs(members) do
    local date = member.date_added
    if type(date) == "string" and date:match("^%d%d%d%d%-%d%d%-%d%d")
        and date:sub(1, 7) < today:sub(1, 7) then candidates[#candidates + 1] = member end
  end
  table.sort(candidates, function(a, b)
    if a.date_added ~= b.date_added then return a.date_added < b.date_added end
    return a.book_id < b.book_id
  end)
  local member = dailyPick(candidates, today, offset)
  if not member then return nil, "no_older_tbr" end
  local entry = shelf_store:entriesOf({ member })[1]
  if not entry then return nil, "no_tbr" end
  return { book_id = entry.book_id, title = entry.title, author = entry.authors,
    image = entry.cached_image, date = member.date_added:sub(1, 10),
    candidates = #candidates, stale = meta.fingerprint == nil }
end

-- ------------------------------------------------------------------ cards

local function moduleMessage(ctx, heading, text)
  local Kit = require("lib/bookshelf_module_kit")
  local Theme = require("hardcover/lib/ui/theme")
  local Group = require("ui/widget/verticalgroup")
  return Group:new { align = "left",
    Kit.fitText { text = heading, width = ctx.width, size = Theme.type.small,
      scale_pct = ctx.scale, opts = { bold = true } },
    require("ui/widget/verticalspan"):new { width = Kit.sc(ctx.scale)(Theme.space.s) },
    Kit.fitText { text = text, width = ctx.width, size = ctx.clamp and Theme.type.label or Theme.type.small,
      scale_pct = ctx.scale },
  }
end

-- A card with nothing to show says which card it is and what to do, in whole
-- wrapped lines: a one-line TextWidget would cut the message to an ellipsis.
local function empty(ctx, text, heading)
  return moduleMessage(ctx, heading or _("Hardcover"), text)
end

local function reasonText(reason)
  if reason == "signed_out" then return _("Sign in to Hardcover Sync.") end
  if reason == "no_goal" then return _("No current goal. Tap to set one.") end
  if reason == "no_books" then return _("No books finished this year yet.") end
  if reason == "no_plugin" then return _("Turn on Hardcover Sync.") end
  if reason == "no_history" then return _("Tap to load reading history in Stats.") end
  if reason == "incomplete_history" then return _("History incomplete. Tap to refresh Stats.") end
  if reason == "no_memories" then return _("No finishes this month in earlier years.") end
  if reason == "no_tbr" then return _("Tap to load your Want to Read shelf.") end
  if reason == "incomplete_tbr" then return _("Want to Read incomplete. Tap to refresh.") end
  if reason == "no_older_tbr" then return _("No books saved before this month on Want to Read.") end
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

-- Dividers use the host's palette rather than painting a white-backed strip.
local function moduleRule(ctx, width, dotted)
  local Theme = require("hardcover/lib/ui/theme")
  local Kit = require("lib/bookshelf_module_kit")
  local Widget = require("ui/widget/widget")
  local Geom = require("ui/geometry")
  local Color = require("lib/bookshelf_color")
  local thickness = Theme.line.hair
  local pitch = Kit.sc(ctx.scale)(Theme.space.xs)
  local Rule = Widget:extend{}
  function Rule:getSize() return Geom:new { w = width, h = thickness } end
  function Rule:paintTo(bb, x, y)
    if dotted then
      for dx = 0, width - thickness, pitch do
        Color.paintRect(bb, x + dx, y, thickness, thickness, Kit.COLOR_MUTED)
      end
    else
      Color.paintRect(bb, x, y, width, thickness, Kit.COLOR_MUTED)
    end
  end
  return Rule:new{}
end

-- One goal fills the card; a wide strip preserves its two independent goals.
local function draw(ctx, cards, reason, opts)
  opts = opts or {}
  if not cards or #cards == 0 then return empty(ctx, reasonText(reason), opts.heading) end
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
    local Theme = require("hardcover/lib/ui/theme")
    local bar = c.fraction and Kit.progressBar {
      width = cw, height = sc(Theme.space.s), fraction = c.fraction,
    } or nil
    if bar and c.pace_fraction then
      local paint = bar.paintTo
      local Geom = require("ui/geometry")
      local height, overhang = bar:getSize().h, sc(Theme.space.xs)
      function bar:getSize()
        return Geom:new { w = cw, h = height + 2 * overhang }
      end
      function bar:paintTo(bb, x, y)
        paint(self, bb, x, y + overhang)
        local Color = require("lib/bookshelf_color")
        local tick = Theme.line.firm
        local at = math.max(0, math.min(cw - tick, math.floor(cw * c.pace_fraction - tick / 2)))
        -- The black marker remains visible over the black fill through its
        -- overhang, not a white cutout. Reserve that space in the host's fit.
        Color.paintRect(bb, x + at, y, tick, self:getSize().h, Kit.COLOR_PRIMARY)
        self.dimen = Geom:new { x = x, y = y, w = cw, h = self:getSize().h }
      end
    end
    -- Each level adds one kind of line, so a card can lose its quietest fact
    -- without also losing the heading that says what it is.
    local heading = c.heading
    local suffix = c.suffix
    local function at(level)
      return Kit.valueCard {
        width = cw, height = ctx.height, scale_pct = ctx.scale,
        heading = level >= 3 and heading or nil,
        value = c.value,
        suffix = level >= 2 and suffix or nil,
        bar = bar, bar_fraction = c.fraction,
        sub = level >= 4 and c.sub or nil,
        context = level >= 5 and c.context or nil,
      }
    end
    -- A level is only kept when it fits the cell at this scale. Judging it at
    -- the host's 60% floor let a smaller scale unlock an extra line that then
    -- overflowed, so the host shrank further and the card grew again.
    -- Words wider than the card would be cut to an ellipsis, so a cell too
    -- narrow for the goal's name gets the number and the bar instead.
    local TextWidget = require("lib/bookshelf_colour_text")
    local function fitsWidth(text, size, bold)
      if not text then return true end
      local face = Kit.face(size, ctx.scale, bold and { bold = true } or nil)
      local probe = TextWidget:new{ text = text, face = face, bold = bold }
      local ok, w = pcall(function() return probe:getSize().w end)
      if probe.free then probe:free() end
      return not ok or w <= cw
    end
    -- The number and its suffix share one line, so measure them together: a
    -- suffix that fits on its own can still be cut to an ellipsis beside it.
    local function fitsPair(text, unit)
      if not unit then return true end
      local vsize = Kit.isStrip and Kit.isStrip(cw, ctx.height) and 26 or 20
      local vface = Kit.face(vsize, ctx.scale, { bold = true })
      local v = TextWidget:new{ text = text, face = vface, bold = true }
      local u = TextWidget:new{ text = unit, face = Kit.face(14, ctx.scale) }
      local ok, w = pcall(function() return v:getSize().w + u:getSize().w end)
      if v.free then v:free() end
      if u.free then u:free() end
      return not ok or w <= cw
    end
    -- The host grows a sparse card until it fills the cell, and a long heading
    -- that fitted at 100% can be too wide at 220%. Use the short form rather
    -- than lose the line that says what the number is.
    if c.short_heading and not fitsWidth(heading, 15, true) then heading = c.short_heading end
    if suffix and not fitsPair(c.value, suffix) then
      suffix = c.short_suffix and fitsPair(c.value, c.short_suffix) and c.short_suffix or nil
    end
    if not ctx.height then return at(top) end
    -- Drop a line the cell is too narrow to show whole, rather than letting the
    -- host cut it to an ellipsis: the finish rate first, then the pace line,
    -- then the heading. The number keeps its unit as long as that unit fits.
    local max = top
    if c.context and not fitsWidth(c.context, 13) then max = math.min(max, 4) end
    if c.sub and not fitsWidth(c.sub, 13) then max = math.min(max, 3) end
    if not fitsWidth(heading, 15, true) then max = math.min(max, 2) end
    if not fitsWidth(suffix, 14) then max = 1 end
    local floor = math.min(opts.min_level or 1, max)
    local rungs = {}
    for level = max, floor, -1 do rungs[#rungs + 1] = level end
    if #rungs == 0 then rungs[1] = max end
    -- Richest first. The last rung keeps at least the number and its unit, so
    -- even a one-line card still says what the number counts.
    for _, level in ipairs(rungs) do
      local widget = at(level)
      local ok, size = pcall(function() return widget:getSize() end)
      local fits = ok and size and size.h <= ctx.height
      if fits then return widget end
    end
    return at(rungs[#rungs])
  end
  -- Two goals need a strip. A 2x1 cell is wide too, but half of it is too
  -- narrow for a goal's name at the size the host grows the card to.
  if #cards > 1 and wideCell(ctx, w) and w >= 2.4 * ctx.height then
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local sep = sc(40)
    local half = math.floor((w - sep) / 2)
    local left, right = card(cards[1], half, 4), card(cards[2], half, 4)
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
  return card(cards[1], cw, 5)
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
  local function suffixWidth(text)
    local probe = TextWidget:new{ text = text, face = Kit.face(14, ctx.scale) }
    local w = probe:getSize().w
    if probe.free then probe:free() end
    return w
  end
  local suffix = card.suffix
  if suffix and num:getSize().w + suffixWidth(suffix) > width then
    suffix = card.short_suffix and num:getSize().w + suffixWidth(card.short_suffix) <= width
      and card.short_suffix or nil
  end
  local value = num
  if suffix then
    local suf = TextWidget:new{ text = suffix, face = Kit.face(14, ctx.scale),
      fgcolor = Kit.COLOR_PRIMARY, max_width = math.max(10, width - num:getSize().w) }
    local dy = math.max(0, num:getBaseline() - suf:getBaseline())
    value = HorizontalGroup:new{ align = "top", num,
      VerticalGroup:new{ align = "left", VerticalSpan:new{ width = dy }, suf } }
  end

  -- One entry per line: its widget, the space above it, and whether the layout
  -- may drop it when the cell is short. A name too wide for the column is left
  -- out whole rather than cut to an ellipsis; the ring and its count still say
  -- what the card is.
  local heading_text = card.heading
  local heading = TextWidget:new{ text = heading_text, face = fh, bold = bh,
    fgcolor = Kit.COLOR_MUTED }
  if heading:getSize().w > width and card.short_heading then
    heading_text = card.short_heading
    heading = TextWidget:new{ text = heading_text, face = fh, bold = bh,
      fgcolor = Kit.COLOR_MUTED }
  end
  local lines = {}
  if heading:getSize().w <= width then
    heading = TextWidget:new{ text = heading_text, face = fh, bold = bh,
      fgcolor = Kit.COLOR_MUTED, max_width = width }
    lines[#lines + 1] = { w = heading }
  end
  lines[#lines + 1] = { w = value, gap = #lines > 0 and sc(2) or 0 }
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
    -- A line wider than the column is left out whole: an ellipsis in a small
    -- card says less than the count and percentage that remain.
    local function line_if_fits(text, gap)
      local probe = TextWidget:new{ text = text, face = quiet, fgcolor = Kit.COLOR_MUTED }
      if probe:getSize().w <= width then
        lines[#lines + 1] = { w = TextWidget:new{ text = text,
          face = quiet, fgcolor = Kit.COLOR_MUTED, max_width = width },
          gap = gap, opt = true }
      end
    end
    if card.sub then line_if_fits(card.sub, sc(4)) end
    if opts.extra and card.left then line_if_fits(card.left, sc(3)) end
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

  local function build(drop, tight)
    local g = VerticalGroup:new{ align = "left" }
    for i, line in ipairs(lines) do
      if not (drop and drop[i]) then
        if #g > 0 and line.gap and not tight then
          g[#g + 1] = VerticalSpan:new{ width = line.gap }
        end
        g[#g + 1] = line.w
      end
    end
    return g
  end

  local g, drop = build(), {}
  if height then
    -- A pixel of rounding can put the column just past the cell. Close the
    -- small gaps before dropping a line the reader still needs.
    if g:getSize().h > height then g = build(drop, true) end
    for i = #lines, 1, -1 do
      if g:getSize().h <= height then break end
      if lines[i].opt then
        drop[i] = true
        g = build(drop, true)
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
  if not cards or #cards == 0 then return empty(ctx, reasonText(reason), _("Goal ring")) end
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
  local Theme = require("hardcover/lib/ui/theme")
  local wide = wideCell(ctx, w) or (h and w >= Theme.space.xl * 4 and w >= h * 0.8)

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
    local ring = size >= sc(44) and ringWithPct(ctx, size, fraction) or nil
    -- The percentage is the point of the ring. A ring squeezed beside the name
    -- can be too small for it at a high screen density, so in that case drop
    -- the name and give the ring the whole tile.
    if ring and #ring > 1 then
      return CenterContainer:new{ dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new{ align = "center", ring,
          VerticalSpan:new{ width = gap }, text } }
    end
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
-- The host re-renders a card repeatedly to fit its cell, changing only the
-- size. Build each card's data once per fit, not once per font size, in
-- `a._bookshelf_<slot>`. Short-lived: anything saved meanwhile, even outside
-- this plugin, appears on the next second's render.
local function fitMemo(a, slot, key, compute)
  local field = "_bookshelf_" .. slot
  local memo, now = a[field], os.time()
  if not memo or memo.key ~= key or memo.at ~= now then
    local card, reason = compute()
    memo = { key = key, at = now, card = card, reason = reason }
    a[field] = memo
  end
  return memo.card, memo.reason
end

local FIT_MEMOS = { "tbr", "memories", "stats", "totals" }

-- Which saved Stats a memo was built from: a refresh saves a new table and
-- invalidating a shelf marks the saved one stale.
local function statsKey(a, user_id)
  local saved = a.shelf_cache and user_id and a.shelf_cache:stats(user_id)
  if not saved then return "none" end
  return tostring(saved) .. ":" .. tostring(saved.saved_at) .. ":" .. tostring(saved.stale)
end

local function goalsFor(a, ctx, limit)
  local queue = a.goal_queue
  local offline = a.dialog_manager and a.dialog_manager:finishedOffline() or 0
  local pinned = setting(ctx, "goal")
  return Modules.goalCards(a.shelf_cache, queue, userId(), offline, nil, pinned, limit)
end

function Modules.goalWidget(a, ctx)
  if setting(ctx, "presentation", "bar") == "ring" then
    if not a then return ringCard(ctx, nil, "no_plugin") end
    return ringCard(ctx, goalsFor(a, ctx, 1))
  end
  if not a then return draw(ctx, nil, "no_plugin", { heading = _("Reading goal") }) end
  local cards, reason = goalsFor(a, ctx, 2)
  return draw(ctx, cards, reason, { heading = _("Reading goal") })
end

function Modules.goalRingWidget(a, ctx)
  if setting(ctx, "presentation", "ring") == "bar" then
    if not a then return draw(ctx, nil, "no_plugin", { heading = _("Reading goal") }) end
    local cards, reason = goalsFor(a, ctx, 2)
    return draw(ctx, cards, reason, { heading = _("Reading goal") })
  end
  if not a then return ringCard(ctx, nil, "no_plugin") end
  -- One goal: two rings on a strip left neither room for its own numbers.
  return ringCard(ctx, goalsFor(a, ctx, 1))
end

function Modules.statsWidget(a, ctx)
  if not a then return draw(ctx, nil, "no_plugin", { heading = _("Hardcover stats") }) end
  local id, year = userId(), tonumber(os.date("%Y"))
  local card, reason = fitMemo(a, "stats", tostring(id) .. ":" .. year .. ":" .. statsKey(a, id),
    function() return Modules.statsCard(a.shelf_cache, id, year) end)
  if not card then return draw(ctx, nil, reason, { heading = _("Hardcover stats") }) end
  local Kit = require("lib/bookshelf_module_kit")
  local Theme = require("hardcover/lib/ui/theme")
  local VGroup = require("ui/widget/verticalgroup")
  local VSpan = require("ui/widget/verticalspan")
  local HGroup = require("ui/widget/horizontalgroup")
  local HSpan = require("ui/widget/horizontalspan")
  local sc = Kit.sc(ctx.scale)
  local width, gap = ctx.width, sc(Theme.space.s)
  local heading = Kit.fitText { text = card.heading, width = width,
    size = Theme.type.small, scale_pct = ctx.scale, fgcolor = Kit.COLOR_MUTED }
  local base = Kit.valueCard { width = width, scale_pct = ctx.scale,
    value = card.value, suffix = card.suffix }
  local ledger = VGroup:new { align = "left", heading, VSpan:new { width = gap }, base }
  for _, fact in ipairs(card.facts) do
    local value_w = math.floor((width - gap) * 0.4)
    local value = Kit.fitText { text = fact.value, width = value_w,
      size = Theme.type.body, scale_pct = ctx.scale, opts = { bold = true }, fgcolor = Kit.COLOR_PRIMARY }
    local label = Kit.fitText { text = fact.label, width = width - value_w - gap,
      size = Theme.type.label, scale_pct = ctx.scale, align = "right", fgcolor = Kit.COLOR_MUTED }
    local row = HGroup:new { align = "center", value,
      HSpan:new { width = gap }, label }
    local extra = gap * 2 + Theme.line.hair + row:getSize().h
    -- Keep the ledger intact during the host's font search. Dropping a row
    -- during a probe makes an overflowing card appear to have room to grow.
    if ctx.clamp and ctx.height and ledger:getSize().h + extra > ctx.height then row:free(); break end
    ledger[#ledger + 1] = VSpan:new { width = gap }
    ledger[#ledger + 1] = moduleRule(ctx, width, true)
    ledger[#ledger + 1] = VSpan:new { width = gap }
    ledger[#ledger + 1] = row
    ledger:resetLayout()
  end
  if ctx.clamp and ctx.height and ledger:getSize().h > ctx.height then
    ledger:free()
    return draw(ctx, { card }, nil, { min_level = 2 })
  end
  return ledger
end

-- Uncapped text reports its natural height to Bookshelf's fit search. A
-- single-line ellipsis would hide overflow and let the host grow clipped labels.
function Modules.totalWidget(a, ctx, kind)
  local Theme = require("hardcover/lib/ui/theme")
  local roomy = not ctx.height or ctx.height >= Theme.space.xl * 4
  local card, reason
  if a then
    -- The four totals cards share one pass over the history.
    local id = userId()
    local totals
    totals, reason = fitMemo(a, "totals", tostring(id) .. ":" .. statsKey(a, id),
      function() return lifetimeTotals(a.shelf_cache, id) end)
    card = totals and totalOf(totals, kind)
  else
    reason = "no_plugin"
  end
  if not card then
    local message = reasonText(reason)
    if not roomy then
      message = reason == "signed_out" and _("Sign in") or reason == "no_plugin" and _("Enable plugin")
        or reason == "incomplete_history" and _("Refresh Stats") or _("Load Stats")
    end
    return moduleMessage(ctx, TOTAL_LABELS[kind], message)
  end
  local Kit = require("lib/bookshelf_module_kit")
  local Group = require("ui/widget/verticalgroup")
  local Span = require("ui/widget/verticalspan")
  local size = roomy and Theme.type.display * 2 or Theme.type.display
  local face, bold = Kit.face(ctx.clamp and Theme.type.title or size, ctx.scale, { bold = true })
  local value = require("lib/bookshelf_colour_text"):new { text = card.value, face = face, bold = bold,
    fgcolor = Kit.COLOR_PRIMARY }
  local shape = ctx.shape or (Kit.shape and Kit.shape(ctx.width, ctx.height))
  local stacked = ctx.height and shape == "tall"
  local label = Kit.fitText { text = card.sub, width = ctx.width, size = Theme.type.label,
    scale_pct = ctx.scale, align = stacked and "center" or "left", fgcolor = Kit.COLOR_MUTED }
  local gap = Kit.sc(ctx.scale)(Theme.space.xs)
  if ctx.height then gap = math.max(0, math.min(gap, ctx.height - value:getSize().h - label:getSize().h)) end
  local top = value
  -- Keep the icon in the host's fit probes, so it scales with the number
  -- instead of disappearing as soon as a probe exceeds the cell width.
  -- Portrait cells use the height for an icon above the number; reporting the
  -- whole stack lets the host fit it before the compact icon-free fallback.
  if not ctx.clamp and setting(ctx, "show_icon", true) then
    local icon_size = value:getSize().h
    local names = { authors = "edit", books = "shelves", five_star = "star-filled", rereads = "sync" }
    local icon = Theme.icon(names[kind], icon_size)
    if Kit.tintIcon then icon = Kit.tintIcon(icon) end
    if stacked then
      top = Group:new { align = "center", icon, Span:new { width = gap }, value }
    else
      top = require("ui/widget/horizontalgroup"):new { align = "center", value,
        require("ui/widget/horizontalspan"):new { width = gap }, icon }
    end
  end
  return Group:new { align = stacked and "center" or "left", top, Span:new { width = gap }, label }
end

-- ------------------------------------------------------- rediscovery cards

local function choiceOffset(ctx, today)
  local choice = setting(ctx, "discovery_choice")
  return choice and choice.day == today and choice.offset or 0
end

local function discoveryFor(a, ctx, kind)
  if not a then return nil, "no_plugin" end
  local today, id = os.date("%Y-%m-%d"), userId()
  local offset = choiceOffset(ctx, today)
  local key = tostring(id) .. ":" .. today .. ":" .. offset
  if kind == "memories" then
    local window, reach = setting(ctx, "memory_window", "month"), setting(ctx, "memory_reach", "all")
    return fitMemo(a, "memories", table.concat({ key, tostring(window), tostring(reach), statsKey(a, id) }, ":"),
      function() return Modules.memoryCard(a.shelf_cache, id, today, offset, window, reach) end)
  end
  -- Decode the TBR membership once per fit, not once per font size.
  return fitMemo(a, "tbr", key, function() return Modules.tbrCard(a.shelf_store, id, today, offset) end)
end

-- Covers decoded during the current fit, by path and size. The fit's probes
-- often ask for the same size, so a cover is read and scaled once; each
-- widget gets its own copy to dispose of.
local fit_covers = { images = {} }
local function decodedCover(path, width, height)
  local now = os.time()
  if fit_covers.at ~= now then
    for _, image in pairs(fit_covers.images) do
      if image then image:free() end
    end
    fit_covers.at, fit_covers.images = now, {}
  end
  local key = path .. ":" .. width .. "x" .. height
  local image = fit_covers.images[key]
  if image == nil then
    image = require("ui/renderimage"):renderImageFile(path, false, width, height) or false
    fit_covers.images[key] = image
  end
  return image and image:copy() or nil
end

-- Uses only a cached image path. Decode by contents (cache files end in .img,
-- which ImageWidget's file loader cannot recognise). Each widget owns its
-- bitmap; nothing is fetched, and no bitmap is shared with another render.
local function discoveryCover(ctx, data, width, required)
  local Kit = require("lib/bookshelf_module_kit")
  local Theme = require("hardcover/lib/ui/theme")
  local CenterContainer = require("ui/widget/container/centercontainer")
  local Geom = require("ui/geometry")
  local height = math.floor(width * 3 / 2)
  local url = type(data.image) == "table" and data.image.url
  local path = url and require("hardcover/lib/ui/image_loader"):cachedPath(url)
  local image = path and decodedCover(path, width, height)
  if image then
    return require("ui/widget/imagewidget"):new {
      image = image, image_disposable = true, width = width, height = height, scale_factor = 0,
    }
  end
  if not required then return nil end
  -- Keep a book-shaped placeholder; the real title is beside it, not squeezed
  -- into an unreadable miniature cover.
  local pad = Kit.sc(ctx.scale)(Theme.space.xs)
  local border = Theme.line.hair
  local inner = math.max(1, width - 2 * (pad + border))
  local icon = Theme.icon("book", math.max(1, math.floor(inner * 0.6)))
  if Kit.tintIcon then icon = Kit.tintIcon(icon) end
  return require("ui/widget/container/framecontainer"):new {
    padding = pad, margin = 0, bordersize = border, color = Kit.COLOR_PRIMARY,
    background = Kit.CARD_BG,
    CenterContainer:new {
      dimen = Geom:new { w = inner, h = math.max(1, height - 2 * (pad + border)) },
      icon,
    },
  }
end

function Modules.discoveryWidget(a, ctx, kind)
  if ctx.set_tap_regions then ctx.set_tap_regions({}) end
  local data, reason = discoveryFor(a, ctx, kind)
  if not data then
    if reason == "no_memories" and setting(ctx, "memory_reach", "all") == "last_year" then
      return moduleMessage(ctx, _("Reading memories"), _("No finishes this month last year."))
    end
    return moduleMessage(ctx, kind == "memories" and _("Reading memories") or _("TBR rediscovery"), reasonText(reason))
  end
  local Kit = require("lib/bookshelf_module_kit")
  local Theme = require("hardcover/lib/ui/theme")
  local TextWidget = require("lib/bookshelf_colour_text")
  local VerticalGroup = require("ui/widget/verticalgroup")
  local VerticalSpan = require("ui/widget/verticalspan")
  local HorizontalGroup = require("ui/widget/horizontalgroup")
  local HorizontalSpan = require("ui/widget/horizontalspan")
  local FrameContainer = require("ui/widget/container/framecontainer")
  local CenterContainer = require("ui/widget/container/centercontainer")
  local Geom = require("ui/geometry")
  local sc = Kit.sc(ctx.scale)
  local gap, w = sc(Theme.space.s), ctx.width
  local memories = kind == "memories"
  local wide = wideCell(ctx, w)
  local compact = not wide and ctx.height and ctx.height < w * 1.25
  local function line(text, size, width, secondary, bold)
    if width then
      return Kit.fitText { text = text, size = size, width = width, scale_pct = ctx.scale,
        opts = { bold = bold }, fgcolor = secondary and Kit.COLOR_MUTED or Kit.COLOR_PRIMARY }
    end
    local face, weight = Kit.face(size, ctx.scale, { bold = bold })
    return TextWidget:new { text = text, face = face, bold = weight,
      max_width = width, fgcolor = secondary and Kit.COLOR_MUTED or Kit.COLOR_PRIMARY }
  end
  local button, button_w, button_h
  if data.candidates > 1 and setting(ctx, "show_another", true)
      and ctx.set_tap_regions and ctx.config and not ctx.preview then
    -- Controls retain their normal touch size while the host scales content.
    local label = TextWidget:new { text = _("Another"),
      face = Kit.face(Theme.type.small, math.min(ctx.scale or 100, 100)), fgcolor = Kit.COLOR_PRIMARY }
    button_w = math.min(w, math.max(Theme.TOUCH_MIN, label:getSize().w + 2 * Theme.space.s))
    button_h = math.max(Theme.TOUCH_MIN, label:getSize().h + 2 * Theme.space.s)
    button = FrameContainer:new { padding = 0, margin = 0,
      bordersize = Theme.line.hair, color = Kit.COLOR_PRIMARY, radius = Theme.mmd.button.radius,
      CenterContainer:new { dimen = Geom:new { w = button_w - 2 * Theme.line.hair,
        h = button_h - 2 * Theme.line.hair }, label } }
  end
  local function dateHeader(width)
    local labels = { day = _("This day in"), week = _("This week in"), month = _("This month in") }
    return VerticalGroup:new { align = "left",
      line(labels[data.window] or labels.month, Theme.type.small, width, true),
      line(data.date:sub(1, 4), Theme.type.display * 1.6, nil, false, true),
      moduleRule(ctx, width, false),
    }
  end
  local function words(width)
    local g = VerticalGroup:new { align = "left" }
    local flexible_gap
    if memories and not wide then
      g[#g + 1] = dateHeader(width)
      flexible_gap = VerticalSpan:new { width = gap }
      g[#g + 1] = flexible_gap
    elseif not memories and not compact then
      g[#g + 1] = line(_("On your TBR"), Theme.type.small, width, true)
      g[#g + 1] = VerticalSpan:new { width = gap }
    end
    local title_at = #g + 1
    local title_args = { text = data.title or _("Untitled"), width = width,
      size = Theme.type.body, scale_pct = ctx.scale, opts = { bold = true },
      max_h = ctx.clamp and sc(Theme.px(Theme.type.body) * 3) or nil }
    g[title_at] = Kit.fitText(title_args)
    if data.author then g[#g + 1] = line(data.author, Theme.type.small, width, true) end
    local rating_at
    if memories and data.rating and setting(ctx, "show_rating", true) then
      rating_at = #g + 1
      g[rating_at] = line(string.format(_("Your rating: %s / 5"), data.rating), Theme.type.small, width, false)
    elseif not memories then
      local Goals = require("hardcover/lib/goals")
      flexible_gap = VerticalSpan:new { width = gap }
      g[#g + 1] = flexible_gap
      g[#g + 1] = compact and Kit.fitText { text = _("Added to Hardcover"), width = width,
        size = Theme.type.label, scale_pct = ctx.scale, fgcolor = Kit.COLOR_MUTED }
        or line(_("Added to Hardcover"), Theme.type.label, width, true)
      g[#g + 1] = line(Goals.dateLabel(data.date), Theme.type.label, width, true)
    end
    if data.stale and not compact and (not ctx.height or ctx.height >= Theme.space.xl * 4) then
      g[#g + 1] = line(_("From saved history"), Theme.type.label, width, true)
    end
    -- The host's final clamp keeps the date, attribution and action visible;
    -- the title is the flexible part. Do not run another font-fit loop here.
    if ctx.clamp and ctx.height then
      local limit = ctx.height - (not wide and button and button_h or 0)
      local overflow = g:getSize().h - limit
      if overflow > 0 and flexible_gap then
        local removed = math.min(flexible_gap.width, overflow)
        flexible_gap.width = flexible_gap.width - removed
        overflow = overflow - removed
        g:resetLayout()
      end
      -- A cell still too tight after the gap closed drops the rating line
      -- before the title gives up any of its lines.
      if overflow > 0 and rating_at and g[rating_at] then
        table.remove(g, rating_at):free()
        g:resetLayout()
        overflow = g:getSize().h - limit
      end
      if overflow > 0 then
        title_args.max_h = math.max(1, g[title_at]:getSize().h - overflow)
        g[title_at]:free()
        g[title_at] = Kit.fitText(title_args)
        g:resetLayout()
      end
    end
    return g
  end
  local body
  if wide then
    local body_w = w - (button and button_w + gap or 0)
    local cover_w = math.min(math.floor(body_w * 0.2),
      sc(Theme.space.xl * (memories and 1.5 or 2)))
    if ctx.height then cover_w = math.min(cover_w, math.floor(ctx.height * 2 / 3)) end
    local cover = setting(ctx, "show_cover", not memories) and discoveryCover(ctx, data, cover_w, not memories)
    local date = memories and dateHeader(math.floor(body_w * 0.3))
    local text_w = body_w - (cover and cover_w + gap or 0) - (date and date:getSize().w + gap or 0)
    body = HorizontalGroup:new { align = "center" }
    if date then body[#body + 1] = date; body[#body + 1] = HorizontalSpan:new { width = gap } end
    if cover and not memories then body[#body + 1] = cover; body[#body + 1] = HorizontalSpan:new { width = gap } end
    body[#body + 1] = words(math.max(1, text_w))
    if cover and memories then body[#body + 1] = HorizontalSpan:new { width = gap }; body[#body + 1] = cover end
  elseif memories then
    local cover_w = math.min(math.floor(w / 3), sc(Theme.space.xl * 2))
    if ctx.height then cover_w = math.min(cover_w, math.max(1,
      math.floor((ctx.height - (button and button_h or 0) - gap) * 2 / 3))) end
    local cover = setting(ctx, "show_cover", false) and discoveryCover(ctx, data, cover_w, false)
    body = cover and HorizontalGroup:new { align = "center", words(w - cover_w - gap),
      HorizontalSpan:new { width = gap }, cover } or words(w)
  elseif not setting(ctx, "show_cover", true) then
    body = words(w)
  else
    local cover_w = math.min(math.floor(w / 3), sc(Theme.space.xl * (compact and 2 or 4)))
    if ctx.height then
      cover_w = math.min(cover_w, math.max(1, math.floor((ctx.height - (button and button_h or 0) - gap) * 2 / 3)))
    end
    body = HorizontalGroup:new { align = "center", discoveryCover(ctx, data, cover_w, true),
      HorizontalSpan:new { width = gap }, words(w - cover_w - gap) }
  end
  -- The host handles taps; a visible button contributes a region in the
  -- returned widget's coordinates. Preserve a finger-sized target even when
  -- the host shrinks the type. Older hosts simply get the whole-card action.
  if not button then
    if memories or (ctx.height and body:getSize().h + gap + Theme.line.hair > ctx.height) then return body end
    return VerticalGroup:new { align = "left", body, VerticalSpan:new { width = gap }, moduleRule(ctx, w, true) }
  end
  if wide then
    local h = math.max(body:getSize().h, button_h)
    ctx.set_tap_regions({ { id = "another", x = body:getSize().w + gap,
      y = math.floor((h - button_h) / 2), w = button_w, h = button_h } })
    return HorizontalGroup:new { align = "center", body, HorizontalSpan:new { width = gap }, button }
  end
  local footer_gap = gap
  if ctx.height then footer_gap = math.max(0, math.min(gap, ctx.height - body:getSize().h - button_h)) end
  local rule_h = not memories and footer_gap >= Theme.line.hair and Theme.line.hair or 0
  ctx.set_tap_regions({ { id = "another", x = 0, y = body:getSize().h + footer_gap,
    w = button_w, h = button_h } })
  local result = VerticalGroup:new { align = "left", body }
  local before_rule = math.floor((footer_gap - rule_h) / 2)
  result[#result + 1] = VerticalSpan:new { width = before_rule }
  if rule_h > 0 then result[#result + 1] = moduleRule(ctx, w, true) end
  result[#result + 1] = VerticalSpan:new { width = footer_gap - rule_h - before_rule }
  result[#result + 1] = button
  return result
end

function Modules.discoveryTap(a, ctx, kind)
  if not a then return end
  local action = setting(ctx, "tap_action", "book")
  if ctx.tapped_region == "another" or (action == "another" and discoveryFor(a, ctx, kind)) then
    if not ctx.config then return end
    local today = os.date("%Y-%m-%d")
    Modules.saveSetting(ctx, "discovery_choice", { day = today, offset = choiceOffset(ctx, today) + 1 })
    return
  end
  if action == "refresh" then Modules.refreshDiscovery(a, ctx, kind); return end
  local data = discoveryFor(a, ctx, kind)
  local dm = a.dialog_manager
  if not dm then return end
  if action == "home" then dm:showHome()
  elseif data and action ~= "source" then dm:showBookDetail(data.book_id)
  elseif kind == "tbr" then dm:showShelf(1, _("Want to Read"))
  else dm:showStats() end
end

function Modules.discoveryKeepOpen(ctx)
  local action = setting(ctx, "tap_action", "book")
  return ctx.tapped_region == "another" or action == "another" or action == "refresh"
end

-- Refresh is explicitly requested by a tap, never a render. Failed requests
-- leave the saved card intact; the same source loaders serve the full screens.
function Modules.refreshDiscovery(a, ctx, kind)
  local Status = require("hardcover/lib/ui/status_dialogs")
  if not require("hardcover/lib/network").connected() then
    Status.info(_("Refreshing needs an internet connection.")); return
  end
  local id = userId()
  if not id then Status.info(_("Sign in to Hardcover first.")); return end
  local loading = Status.loading(_("Refreshing from Hardcover…"))
  local function done(ok)
    Status.close(loading)
    if ok then
      for _, slot in ipairs(FIT_MEMOS) do a["_bookshelf_" .. slot] = nil end
      if ctx.refresh then ctx.refresh() end
    end
    Status.info(ok and _("Updated from Hardcover.") or _("Couldn't refresh. Your saved data is unchanged."))
  end
  if kind == "tbr" then
    a.dialog_manager:downloadShelf(1, { front = true, force = true, check = false,
      on_done = function(result) done(result and result.complete) end })
  else
    require("hardcover/lib/hardcover_api"):getStatsAsync(id, function(stats)
      if userId() ~= id then
        Status.close(loading)
        return
      end
      if stats and stats.complete ~= false then
        if a.shelf_cache:putStats(id, stats) then done(true)
        else
          Status.close(loading)
          Status.info(_("Couldn't save the refreshed stats."))
        end
      else done(false) end
    end)
  end
end

-- ------------------------------------------------------------- year card

-- This year in twelve bars, from the saved stats, with a selectable metric.
function Modules.yearCard(shelf_cache, user_id, year, metric)
  if not (shelf_cache and user_id) then return nil, "signed_out" end
  local saved = shelf_cache:stats(user_id)
  if not saved then return nil, "no_data" end
  local Stats = require("hardcover/lib/stats")
  year = year or tonumber(os.date("%Y"))
  local s = Stats.compute(saved.rows, { year = year })
  if s.books == 0 then return nil, "no_books" end
  local pages = metric ~= "books" and s.pages > 0
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
      -- First UTF-8 character, including its continuation bytes.
      names[m] = TextWidget:new{ text = data.labels[m]:match("^.[\128-\191]*"),
        face = Kit.face(require("hardcover/lib/ui/theme").type.label, ctx.scale), fgcolor = Kit.COLOR_MUTED }
      widest = math.max(widest, names[m]:getSize().w)
    end
  end
  local step = 0
  if widest > 0 and h >= sc(56) then
    if bar_w >= widest + sc(2) then step = 1
    elseif bar_w * 3 >= widest + sc(2) then step = 3 end
  end
  local labels = step > 0
  -- Reserve the measured height of the month names, not a fixed guess: at the
  -- host's larger scales a guessed row was shorter than the text it held.
  local label_h = labels and names[1]:getSize().h + sc(2) or 0
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
          -- The bottom edge sits on the bars' baseline, not at the chart's
          -- full height: the month names live below that baseline.
          Color.paintRect(bb, bx, y + bars_h - t, bar_w, t, ink)
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

-- Months stacked vertically, with horizontal bars and aligned monthly totals.
-- Report the natural text height to the host's fit search; only its final
-- clamp may thin out labels, never the twelve bars themselves.
local function monthRows(ctx, data, width, height)
  local Kit = require("lib/bookshelf_module_kit")
  local Theme = require("hardcover/lib/ui/theme")
  local Color = require("lib/bookshelf_color")
  local Geom = require("ui/geometry")
  local Text = require("lib/bookshelf_colour_text")
  local sc = Kit.sc(ctx.scale)
  local gap, names, values = sc(Theme.space.xs), {}, {}
  local name_w, value_w, text_h = 0, 0, 0
  for m = 1, 12 do
    names[m] = Text:new { text = data.labels[m], face = Kit.face(Theme.type.label, ctx.scale),
      fgcolor = Kit.COLOR_MUTED }
    values[m] = Text:new { text = grouped(data.months[m]), face = Kit.face(Theme.type.label, ctx.scale),
      fgcolor = Kit.COLOR_PRIMARY }
    name_w = math.max(name_w, names[m]:getSize().w)
    value_w = math.max(value_w, values[m]:getSize().w)
    text_h = math.max(text_h, names[m]:getSize().h, values[m]:getSize().h)
  end
  local h = math.max(height or 0, 12 * text_h + 11 * gap)
  if ctx.clamp and height then
    h = math.max(12, height)
    -- Close the gaps before dropping labels when the fitted card is only a
    -- few pixels short of twelve complete rows. Keep a hairline between bars
    -- in short cells so equal monthly counts do not merge into solid blocks.
    gap = math.min(gap, math.floor(h / 24), math.max(Theme.line.hair, math.floor((h - 12 * text_h) / 11)))
  end
  local row_h = math.max(1, math.floor((h - 11 * gap) / 12))
  local step = math.max(1, math.ceil((text_h + gap) / (row_h + gap)))
  local w = math.max(width, name_w + value_w + 2 * gap + sc(Theme.space.m))
  local plot_w = w - name_w - value_w - 2 * gap
  local bar_h = math.max(1, math.min(row_h, sc(Theme.space.s)))
  local Chart = require("ui/widget/widget"):extend{}
  function Chart:getSize() return Geom:new { w = w, h = h } end
  function Chart:free()
    for m = 1, 12 do names[m]:free(); values[m]:free() end
  end
  function Chart:paintTo(bb, x, y)
    self.dimen = Geom:new { x = x, y = y, w = w, h = h }
    for m = 1, 12 do
      local top = y + (m - 1) * (row_h + gap)
      if (m - 1) % step == 0 and top + text_h <= y + h then
        local ty = top + math.max(0, math.floor((row_h - text_h) / 2))
        names[m]:paintTo(bb, x, ty)
        if step == 1 then values[m]:paintTo(bb, x + w - values[m]:getSize().w, ty) end
      end
      if data.months[m] > 0 then
        local bw = math.max(1, math.floor(plot_w * data.months[m] / math.max(1, data.peak)))
        local bx, by = x + name_w + gap, top + math.floor((row_h - bar_h) / 2)
        local t = Theme.line.hair
        if m == data.current and bw > 2 * t and bar_h > 2 * t then
          Color.paintRect(bb, bx, by, bw, t, Kit.COLOR_PRIMARY)
          Color.paintRect(bb, bx, by + bar_h - t, bw, t, Kit.COLOR_PRIMARY)
          Color.paintRect(bb, bx, by, t, bar_h, Kit.COLOR_PRIMARY)
          Color.paintRect(bb, bx + bw - t, by, t, bar_h, Kit.COLOR_PRIMARY)
        else
          Color.paintRect(bb, bx, by, bw, bar_h, Kit.COLOR_PRIMARY)
        end
      end
    end
  end
  local chart = Chart:new{}
  -- Expose visible text in the widget tree while painting its aligned
  -- positions here rather than delegating layout to a container.
  for m = 1, 12 do
    if (m - 1) % step == 0 and (m - 1) * (row_h + gap) + text_h <= h then
      chart[#chart + 1] = names[m]
      if step == 1 then chart[#chart + 1] = values[m] end
    end
  end
  return chart
end

-- The card: the year and its total, the twelve bars, and the month that carried
-- the year. A wide cell puts the words beside the bars; a short one gives up the
-- caption before it gives up the bars.
local function yearDraw(ctx, data, reason)
  if not data then return empty(ctx, reasonText(reason), _("Year in books")) end
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
  local rows = setting(ctx, "chart_layout", "columns") == "rows"

  -- The year and its total. Built per width, because a wide cell gives the
  -- words a column and the bars the rest: without the limit a long total would
  -- push the bars off the card.
  local function title(width, tight, no_unit)
    local limit = width or w
    local heading = TextWidget:new{ text = tostring(data.year),
      face = Kit.face(15, ctx.scale, { bold = true }), bold = true,
      fgcolor = Kit.COLOR_MUTED, max_width = width }
    local value = TextWidget:new{ text = grouped(data.total),
      face = Kit.face(26, ctx.scale, { bold = true }), bold = true,
      fgcolor = Kit.COLOR_PRIMARY, max_width = width }
    -- Measure the unit beside the total before capping it. If the pair does
    -- not fit, the unit goes under the number instead of being cut off.
    local suffix = TextWidget:new{ text = " " .. data.unit,
      face = Kit.face(14, ctx.scale), fgcolor = Kit.COLOR_PRIMARY }
    local unit_line
    if value:getSize().w + suffix:getSize().w > limit then
      suffix = nil
      unit_line = TextWidget:new{ text = data.unit,
        face = Kit.face(tight and 12 or 13, ctx.scale),
        fgcolor = Kit.COLOR_MUTED, max_width = width }
    end
    if no_unit then suffix, unit_line = nil, nil end
    local total = value
    if suffix then
      local dy = math.max(0, value:getBaseline() - suffix:getBaseline())
      total = HorizontalGroup:new{ align = "top", value,
        VerticalGroup:new{ align = "left", VerticalSpan:new{ width = dy }, suffix } }
    end
    local g = VerticalGroup:new{ align = "left",
      heading, VerticalSpan:new{ width = tight and 0 or sc(2) }, total }
    if unit_line then
      g[#g + 1] = VerticalSpan:new{ width = tight and 0 or sc(1) }
      g[#g + 1] = unit_line
    end
    return g
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
  if not rows and wideCell(ctx, w) and h then
    local words_w = math.min(title(nil):getSize().w, math.floor(w * 0.5))
    local chart_w = math.max(sc(60), w - words_w - gap)
    local column = VerticalGroup:new{ align = "left", title(words_w) }
    if caption then
      column[#column + 1] = VerticalSpan:new{ width = sc(4) }
      column[#column + 1] = caption
    end
    -- The chart fills the cell height, so a column taller than the cell would
    -- be clipped even though the chart fits. Drop the caption before that.
    if column:getSize().h > h then
      column = VerticalGroup:new{ align = "left", title(words_w, true) }
    end
    -- Still too tall: the unit goes before the card is clipped. The year and
    -- the total remain, and the chart carries the rest of the meaning.
    if column:getSize().h > h then
      column = VerticalGroup:new{ align = "left", title(words_w, true, true) }
    end
    return HorizontalGroup:new{ align = "center",
      column,
      HorizontalSpan:new{ width = gap },
      CenterContainer:new{ dimen = Geom:new{ w = chart_w, h = h },
        monthChart(ctx, data, chart_w, math.max(sc(24), math.floor(h * 0.84))) } }
  end

  local text = title(w)
  local text_h = text:getSize().h
  if rows then
    return VerticalGroup:new { align = "left", text, VerticalSpan:new { width = gap },
      monthRows(ctx, data, w, h and math.max(12, h - text_h - gap) or nil) }
  end
  if not h then
    -- The start menu has no cell: take a natural height for the bars.
    return VerticalGroup:new{ align = "left", text, VerticalSpan:new{ width = gap },
      monthChart(ctx, data, w, sc(70)) }
  end
  local room = h - text_h - gap
  local caption_gap = sc(6)
  if caption then
    -- Reserve exactly the gap the caption is later given. Reserving a smaller
    -- one pushed the card a few pixels past the cell, which the host clipped.
    if room - caption:getSize().h - caption_gap >= sc(24) then
      room = room - caption:getSize().h - caption_gap
    else
      caption = nil
    end
  end
  local stack = VerticalGroup:new{ align = "left", text, VerticalSpan:new{ width = gap },
    monthChart(ctx, data, w, math.max(sc(16), room)) }
  if caption then
    stack[#stack + 1] = VerticalSpan:new{ width = caption_gap }
    stack[#stack + 1] = caption
  end
  return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, stack }
end

function Modules.yearWidget(a, ctx)
  if not a then return yearDraw(ctx, nil, "no_plugin") end
  return yearDraw(ctx, Modules.yearCard(a.shelf_cache, userId(), nil, setting(ctx, "year_metric", "pages")))
end

-- The goal card's own settings (long press on the card): pin it to one of the
-- running goals, or leave it on Automatic. A pinned goal that has since ended
-- falls back to Automatic, which is what the card is already showing. Adding the
-- card twice and pinning each to a different goal shows two goals at once.
-- A shelf's layout editor works on copies of its modules. Saving the whole
-- copy from a settings dialog would also write back its older style and
-- position, and the host's fitted-size memo can reuse the previous goal's
-- render. Change only the goal on the stored shelf module, then forget that
-- card's fit.
shelfModule = function(ctx)
  if ctx.surface ~= "shelf" or not (ctx.bw and ctx.entry and ctx.entry.id) then return nil end
  local ok, found = pcall(function()
    local TabModel = require("lib/bookshelf_tab_model")
    local tabs = TabModel.load()
    for _, tab in ipairs(tabs or {}) do
      if tab.id == ctx.bw.chip and type(tab.shelf_modules) == "table" then
        for _, m in ipairs(tab.shelf_modules) do
          if m.id == ctx.entry.id then
            return { tabs = tabs, module = m, TabModel = TabModel }
          end
        end
      end
    end
  end)
  return ok and found or nil
end

local function setShelfSetting(ctx, name, value)
  local found = shelfModule(ctx)
  if not found then return false end
  found.module[name] = value
  if not pcall(function() found.TabModel.save(found.tabs) end) then return false end
  -- The editor holds a copy; keep this field in step so its next save does not
  -- write the old one back.
  if ctx.entry then ctx.entry[name] = value end
  pcall(function()
    local Cache = require("lib/bookshelf_module_cache")
    local memo = Cache.read("module_fit_memo")
    if type(memo) ~= "table" then return end
    local changed, id = false, "|" .. tostring(ctx.entry.id) .. "|"
    for key in pairs(memo) do
      if type(key) == "string" and key:find(id, 1, true) then
        memo[key] = nil
        changed = true
      end
    end
    if changed then Cache.save("module_fit_memo", memo) end
  end)
  pcall(function() require("lib/bookshelf_hero_modules")._resetFitMemo() end)
  return true
end

function Modules.saveSetting(ctx, name, value)
  if setShelfSetting(ctx, name, value) then
    if ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
  elseif ctx.config then
    if value == nil then ctx.config:delete(name) else ctx.config:set(name, value) end
  end
end

-- One option picker per setting keeps the module menu short, with each saved
-- value visible. All writes use the same shelf-safe path as the goal picker.
local function option(ctx, name, title, choices, default)
  local UIManager = require("ui/uimanager")
  local Kit = require("lib/bookshelf_module_kit")
  local buttons, dialog = {}, nil
  for _, choice in ipairs(choices) do
    local value = choice[1]
    buttons[#buttons + 1] = { Kit.radioRow {
      label = choice[2], active = setting(ctx, name, default) == value,
      on_pick = function()
        UIManager:close(dialog)
        Modules.saveSetting(ctx, name, value)
      end,
    } }
  end
  dialog = require("ui/widget/buttondialog"):new(Kit.withClose {
    title = title, title_align = "center", width_factor = 0.7, buttons = buttons,
  })
  UIManager:show(dialog)
end

function Modules.cardSettings(a, ctx, kind)
  if not (ctx and ctx.config) then return end
  local UIManager = require("ui/uimanager")
  local Kit = require("lib/bookshelf_module_kit")
  local buttons, dialog = {}, nil
  local function add(name, label, choices, default)
    local current = setting(ctx, name, default)
    local text = ""
    for _, c in ipairs(choices) do if c[1] == current then text = c[2] end end
    buttons[#buttons + 1] = { { text = label .. ": " .. text, callback = function()
      UIManager:close(dialog)
      option(ctx, name, label, choices, default)
    end } }
  end
  local yes_no = { { true, _("Show") }, { false, _("Hide") } }
  local discovery = kind == "memories" or kind == "tbr"
  if kind == "memories" then
    add("memory_window", _("Window"), {
      { "day", _("This day") }, { "week", _("This week") }, { "month", _("This month") } }, "month")
    add("memory_reach", _("Reach"), {
      { "last_year", _("Last year") }, { "all", _("All previous years") } }, "all")
  end
  if discovery then
    add("show_cover", _("Cover"), yes_no, kind == "tbr")
    if kind == "memories" then add("show_rating", _("Rating"), yes_no, true) end
    add("show_another", _("Another button"), yes_no, true)
  elseif kind == "goal" or kind == "goal_ring" then
    buttons[#buttons + 1] = { { text = _("Which goal to show"), callback = function()
      UIManager:close(dialog); Modules.goalSettings(a, ctx)
    end } }
    add("presentation", _("Presentation"), { { "bar", _("Bar") }, { "ring", _("Ring") } },
      kind == "goal_ring" and "ring" or "bar")
  elseif TOTAL_LABELS[kind] then
    add("show_icon", _("Icon"), yes_no, true)
  elseif kind == "year" then
    add("chart_layout", _("Layout"), {
      { "columns", _("Upright columns") }, { "rows", _("Stacked rows") } }, "columns")
    add("year_metric", _("Metric"), { { "pages", _("Pages") }, { "books", _("Books") } }, "pages")
  end
  local actions = { { "source", kind == "tbr" and _("Open Want to Read")
    or (kind == "goal" or kind == "goal_ring") and _("Open Goals") or _("Open Stats") },
    { "home", _("Open Hardcover Home") } }
  if discovery then
    table.insert(actions, 1, { "book", _("Open book details") })
    actions[#actions + 1] = { "another", _("Show another saved book") }
    actions[#actions + 1] = { "refresh", _("Refresh from Hardcover") }
  end
  add("tap_action", _("Tap action"), actions, discovery and "book" or "source")
  dialog = require("ui/widget/buttondialog"):new(Kit.withClose {
    title = _("Module settings"), title_align = "center", width_factor = 0.8, buttons = buttons,
  })
  UIManager:show(dialog)
end

function Modules.cardTap(a, ctx, screen)
  Modules.openScreen(a, setting(ctx or {}, "tap_action", "source") == "home" and "showHome" or screen)
end

function Modules.goalSettings(a, ctx)
  if not (ctx and ctx.config) then return end
  local UIManager = require("ui/uimanager")
  local ButtonDialog = require("ui/widget/buttondialog")
  local Kit = require("lib/bookshelf_module_kit")

  local choices = a and Modules.goalChoices(a.shelf_cache, a.goal_queue, userId()) or {}
  local pinned = setting(ctx, "goal")
  local active
  for _, c in ipairs(choices) do
    if pinned ~= nil and tostring(c.id) == tostring(pinned) then active = c.id end
  end

  local buttons = {}
  local dialog
  local function close(setting, value)
    return function()
      UIManager:close(dialog)
      local goal = setting == "delete" and nil or value
      Modules.saveSetting(ctx, "goal", goal)
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
