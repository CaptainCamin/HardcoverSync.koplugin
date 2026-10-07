-- The home screen: what you are reading now, then your shelves and lists.
--
-- A title bar, then one column: a search field, a "Currently reading" section (the
-- heading opens that shelf; every book is a card of the same size), a "Library"
-- section of count tiles (the shelves and the lists), and an optional card the
-- caller supplies (the reading goal). The column is as long as it needs to be; when
-- it is taller than the screen the page scrolls, and every tap range is clipped to
-- what the scroll area shows (see viewport.lua) so something scrolled out of view
-- cannot take a tap meant for what is on screen. A page that fits is not scrolled.
--
-- Choosing a card opens that book; choosing a shelf opens it on top of this
-- screen, so closing the shelf comes back here.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local _ = require("gettext")

local Goals = require("hardcover/lib/goals")
local GoalWidgets = require("hardcover/lib/ui/goal_widgets")
local Home = require("hardcover/lib/home")
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local CoverCells = require("hardcover/lib/ui/cover_cells")
local Refresh = require("hardcover/lib/ui/refresh")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

-- How many books being read get a card on Home; the rest are under the heading.
local HomeDialog = InputContainer:extend {
  name = "hardcover_home_dialog",
  title = _("Hardcover"),
  rows = {},
  entries = {},
  select_cb = nil,
  open_book_cb = nil,
  settings_cb = nil,
  search_cb = nil,
  lists_cb = nil,    -- the "More lists" tile appears when this is set
  vibes_cb = nil,    -- the "Vibes" tile (Hardcover's own recommendation lists) appears when this is set
  stats_cb = nil,    -- the "Stats" tile (your reading as charts) appears when this is set
  for_you_cb = nil,  -- the "For you" tile (books suggested from your ratings) appears when this is set
  goals = nil,       -- Goals.normalize rows (saved or fresh); the goal card shows the chosen one
  finished_offline = 0, -- books finished here and not yet counted by Hardcover
  goal_cb = nil,     -- called with the goal when its card is tapped
  goals_cb = nil,    -- the "Goals" heading: opens the Goals screen
  list_count = nil,
  close_callback = nil,
}

HomeDialog.MAX_CARDS = 3

function HomeDialog:init()
  self.closed = false
  self.key_events.CloseHome = { { "Back" } }
  -- PROTOTYPE (modular Home): a variant chosen by a dev setting; nil = today's Home
  if rawget(_G, "G_reader_settings") and G_reader_settings:readSetting("hardcover_prototype_home_variant") then
    local def = require("hardcover/lib/ui/home_modular_prototype").current()
    self.prototype_variant = def and def.key
  end
  -- the covers outlive a rebuild: Home rebuilds as its data arrives, and a picture
  -- already decoded is reused rather than decoded again
  self.covers = CoverCells:new {
    window = self,
    loader = function() return self.image_loader or require("hardcover/lib/ui/image_loader") end,
  }
  self:build()
end

-- A cover box of the given size: the generic book icon until the picture
-- arrives, so nothing moves when it does.
function HomeDialog:coverCell(card, w, h)
  return self.covers:cell(card.cover_url, w, h)
end

local function progressBar(width, height, fraction)
  return ProgressWidget:new {
    width = width,
    height = height,
    percentage = fraction,
    ticks = nil,
    last = nil,
  }
end

local text = Theme.text

-- The wrapper that makes a card tappable (and only over what it draws)
function HomeDialog:tappable(widget, book_id, viewport)
  return TapRow:new {
    viewport = viewport,
    callback = function()
      if self.open_book_cb then
        self.open_book_cb(book_id)
      end
    end,
    widget,
  }
end

-- A book you are reading: cover, title, author, progress. Every card is the same
-- size, so the section reads as a tidy list however many books there are.
function HomeDialog:buildCard(card, width, viewport)
  local cw = Screen:scaleBySize(72)
  local ch = math.floor(cw * 1.5)
  local text_w = width - cw - Theme.line.hair * 2 - Theme.space.l
  local info = VerticalGroup:new { align = "left" }
  local title_face = Theme.face("title")
  table.insert(info, TextBoxWidget:new {
    text = card.title,
    face = title_face,
    bold = true,
    width = text_w,
    height = 2 * title_face.size * 1.4,
    height_adjust = true,
    height_overflow_show_ellipsis = true,
  })
  if card.author and card.author ~= "" then
    table.insert(info, text(card.author, "small", { grey = true, width = text_w }))
  end
  if card.fraction or card.progress_text then
    table.insert(info, Theme.span("s"))
    if card.fraction then
      table.insert(info, progressBar(text_w, Screen:scaleBySize(10), card.fraction))
      table.insert(info, Theme.span("xs"))
    end
    local line = card.progress_text
    if card.fraction then
      line = string.format("%d%%", math.floor(card.fraction * 100 + 0.5))
        .. (line and ("  \194\183  " .. line) or "")
    end
    if line then
      table.insert(info, text(line, "small", { width = text_w }))
    end
  end
  -- every card is as tall as its cover, so they line up whatever the text does
  local row = HorizontalGroup:new {
    align = "center",
    self:coverCell(card, cw, ch),
    Theme.hspan("l"),
    CenterContainer:new { dimen = Geom:new { w = text_w, h = ch }, info },
  }
  return VerticalGroup:new {
    align = "left",
    Theme.rule(width, false),
    Theme.span("s"),
    self:tappable(row, card.book_id, viewport),
    Theme.span("s"),
  }
end

-- One shelf tile: the count big, the name beside it. Tapping opens the shelf.
function HomeDialog:buildTile(row, w, h, viewport, proto_body)
  local line = HorizontalGroup:new { align = "center" }
  local count = Home.countText(row.count)
  if count ~= "" then
    table.insert(line, text(count, "display", { bold = true, width = w }))
    table.insert(line, Theme.hspan("m"))
  end
  table.insert(line, text(row.title, "small", { width = w - Theme.space.l }))
  local tile = TapRow:new {
    callback = function()
      if row.lists then
        if self.lists_cb then self.lists_cb() end
      elseif row.for_you then
        if self.for_you_cb then self.for_you_cb() end
      elseif row.vibes then
        if self.vibes_cb then self.vibes_cb() end
      elseif row.stats then
        if self.stats_cb then self.stats_cb() end
      elseif self.select_cb then
        self.select_cb(row)
      end
    end,
    -- PROTOTYPE: a variant may draw the tile its own way (an unboxed line)
    proto_body and LeftContainer:new { dimen = Geom:new { w = w, h = h }, proto_body }
      or Theme.box(w, h, line, { radius = 10 }),
  }
  -- what the tile shows, so a rebuild can tell which tiles changed (and so which
  -- part of the panel needs redrawing)
  self.tiles[#self.tiles + 1] = { key = row.lists and "lists" or (row.for_you and "for_you") or (row.vibes and "vibes") or (row.stats and "stats") or tostring(row.status_id or row.title),
    shows = (row.title or "") .. "|" .. Home.countText(row.count), tile = tile }
  return tile
end

-- Build everything from the current rows and entries. Pure function of both, so
-- a rebuild cannot leave a stale widget behind.
-- The goal card under the library: the caller's own (goal_card_fn, for tests and
-- mock-ups) or the one Goals.pick chooses from the saved goals; nil when there is
-- no current goal. Worked out on the device from the saved goal and the date, so
-- it shows the same offline.
function HomeDialog:buildGoalCard(width, viewport)
  if self.goal_card_fn then
    return self.goal_card_fn(width, viewport)
  end
  -- with nothing to show, the heading is still there: it is the way to the Goals screen
  local function empty()
    if not self.goals_cb then return nil end
    return GoalWidgets.homeEmpty(width, viewport, function() self.goals_cb() end)
  end
  if type(self.goals) ~= "table" or #self.goals == 0 then return empty() end
  local today = Goals.today()
  local goal = Goals.pick(self.goals, today)
  if not goal then return empty() end
  local p = Goals.pace(goal, today, Goals.extra(goal, today, self.finished_offline))
  return GoalWidgets.homeCard(goal, p, width, viewport,
    function() if self.goal_cb then self.goal_cb(goal) end end,
    function() if self.goals_cb then self.goals_cb() end end)
end

-- The column of everything on the home screen, laid out in `width`. `viewport`
-- (a function returning the visible rectangle of the scroll area, or nil when the
-- page is not scrolling) clips every tap range to what is on screen.
function HomeDialog:buildColumn(width, viewport)
  if self.prototype_variant then
    return require("hardcover/lib/ui/home_modular_prototype").buildColumn(self, width, viewport)
  end
  -- The search field: a rounded outline that reads as an input, and opens the
  -- search box when tapped. The words are centred in it by a container of the
  -- field's own size (a frame given a height does not centre its text).
  local field_h = Screen:scaleBySize(52)
  local search_icon = Screen:scaleBySize(26)
  local field = TapRow:new {
    viewport = viewport,
    callback = function()
      if self.search_cb then
        self.search_cb()
      end
    end,
    Theme.box(width, field_h, LeftContainer:new {
      dimen = Geom:new { w = width - 2 * Theme.line.firm, h = field_h - 2 * Theme.line.firm },
      HorizontalGroup:new {
        align = "center",
        Theme.hspan("m"),
        IconWidget:new { icon = "appbar.search", width = search_icon, height = search_icon },
        Theme.hspan("s"),
        text(_("Search books on Hardcover"), "body", { grey = true, width = width - 4 * Theme.space.m }),
      },
    }, { radius = 26 }),
  }
  self.search_button = field

  -- The library block comes first in the build so its height is known: the
  -- reading list gets whatever the screen has left.
  local library = VerticalGroup:new { align = "left" }
  table.insert(library, Theme.sectionHeader(_("Library"), width))
  table.insert(library, Theme.span("m"))
  local tile_w = math.floor((width - Theme.space.m) / 2)
  local tile_h = Screen:scaleBySize(64)
  -- "Currently reading" is opened from its own heading, so the tiles are the
  -- other shelves, then the lists
  local rows = {}
  for _, row in ipairs(self.rows or {}) do
    if row.status_id ~= HARDCOVER.STATUS.READING then rows[#rows + 1] = row end
  end
  if self.lists_cb then
    rows[#rows + 1] = { lists = true, title = _("More lists"), count = self.list_count }
  end
  if self.for_you_cb then
    rows[#rows + 1] = { for_you = true, title = _("For you") }
  end
  if self.vibes_cb then
    rows[#rows + 1] = { vibes = true, title = _("Vibes") }
  end
  if self.stats_cb then
    rows[#rows + 1] = { stats = true, title = _("Stats") }
  end
  for i = 1, #rows, 2 do
    local pair = HorizontalGroup:new { self:buildTile(rows[i], tile_w, tile_h, viewport) }
    if rows[i + 1] then
      table.insert(pair, Theme.hspan("m"))
      table.insert(pair, self:buildTile(rows[i + 1], tile_w, tile_h, viewport))
    end
    table.insert(library, pair)
    if rows[i + 2] then table.insert(library, Theme.span("m")) end
  end
  self.library = library

  -- an optional card under the library (the reading goal): built by the caller,
  -- at the page width
  local goal_card = self:buildGoalCard(width, viewport)

  local column = VerticalGroup:new { align = "left" }
  table.insert(column, Theme.span("m"))
  table.insert(column, field)
  table.insert(column, Theme.span("m"))

  -- The heading is always there (it is the way into the Currently Reading
  -- shelf); the cards under it are whatever has been loaded.
  local cards = Home.cards(self.entries)
  -- the heading says how many you are reading (the shelf's count when it is known:
  -- more may be loaded than are shown); only the first few get a card, the rest are
  -- one tap away under the heading
  local reading_total = #cards
  for _i, row in ipairs(self.rows or {}) do
    if row.status_id == HARDCOVER.STATUS.READING and type(row.count) == "number" and row.count >= #cards then
      reading_total = row.count
    end
  end
  local right = HorizontalGroup:new { align = "center" }
  if #cards > 0 then
    local count = reading_total == 1 and _("1 book") or string.format(_("%d books"), reading_total)
    table.insert(right, text(count, "small", { grey = true }))
    table.insert(right, Theme.hspan("s"))
  end
  table.insert(right, text("\226\128\186", "title", { bold = true }))
  local header = TapRow:new {
    viewport = viewport,
    callback = function()
      if self.select_cb then
        self.select_cb({ status_id = HARDCOVER.STATUS.READING, title = _("Currently Reading") })
      end
    end,
    Theme.sectionHeader(_("Currently reading"), width, right),
  }
  self.reading_header = header
  table.insert(column, header)
  table.insert(column, Theme.span("m"))

  if #cards == 0 then
    -- nothing loaded (offline with nothing saved) or nothing being read: say so,
    -- and where to go, rather than leaving a heading with nothing under it
    table.insert(column, text(_("Nothing to show yet. Tap the heading to open the shelf."), "small",
      { grey = true, width = width }))
    table.insert(column, Theme.span("l"))
  end

  -- the first few books, each a card of the same size; the page scrolls when the
  -- screen cannot hold them with everything else
  if #cards > 0 then
    for i = 1, math.min(#cards, HomeDialog.MAX_CARDS) do
      table.insert(column, self:buildCard(cards[i], width, viewport))
    end
    table.insert(column, Theme.span("m"))
  end
  table.insert(column, library)
  if goal_card then
    table.insert(column, Theme.span("l"))
    table.insert(column, goal_card)
    table.insert(column, Theme.span("l")) -- room under the last card when scrolled to the end
  end
  column:resetLayout() -- children were added since its size was last read
  return column
end

-- Build everything from the current rows and entries. Pure function of both, so
-- a rebuild cannot leave a stale widget behind.
function HomeDialog:build()
  self.covers:begin()
  self.tiles = {}
  self.painted = false
  -- the entries this tree is drawn from: a rebuild is asked for after the new
  -- ones are stored, and has to compare against what is on screen
  self.built_entries = self.entries

  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local M = Theme.margin

  local title_bar = Theme.titleBar {
    title = self.title,
    -- the cog opens the plugin's settings
    left_icon = "appbar.settings",
    left_callback = function()
      if self.settings_cb then
        self.settings_cb()
      end
    end,
    close_callback = function() self:onClose() end,
    show_parent = self,
  }
  local room = screen_h - title_bar:getSize().h
  self.proto_room = room -- PROTOTYPE

  -- First at full width. If that is taller than the screen, again narrower (to
  -- leave the scroll bar its gutter) inside a scrolling container, with every tap
  -- clipped to what the container shows (see viewport.lua). A page that fits is
  -- not scrolled at all, so nothing changes for it.
  local width = screen_w - 2 * M
  local column = self:buildColumn(width, nil)
  local body
  self.scroll = nil
  if column:getSize().h > room then
    -- the second pass rebuilds the tiles for the narrower column
    self.tiles = {}
    local gutter = 3 * (ScrollableContainer.scroll_bar_width or Screen:scaleBySize(6))
    width = screen_w - 2 * M - gutter
    self.scroll = ScrollableContainer:new {
      dimen = Geom:new { x = 0, y = 0, w = screen_w, h = room },
      show_parent = self,
    }
    local scroll = self.scroll
    column = self:buildColumn(width, function() return scroll.dimen end)
    scroll[1] = HorizontalGroup:new { Theme.hspan(M), column }
    -- the container works out how far it can scroll when it first paints
    scroll:initState()
    body = scroll
  else
    body = HorizontalGroup:new { Theme.hspan(M), column }
  end

  self.title_bar = title_bar
  self.frame = FrameContainer:new {
    width = screen_w,
    height = screen_h,
    background = Blitbuffer.COLOR_WHITE,
    bordersize = 0,
    padding = 0,
    margin = 0,
    VerticalGroup:new {
      align = "left",
      title_bar,
      body,
    },
  }
  self.dimen = Geom:new { x = 0, y = 0, w = screen_w, h = screen_h }
  self[1] = self.frame
  if self.prototype_variant then -- PROTOTYPE: the variant switcher over the page
    self[1] = require("hardcover/lib/ui/home_modular_prototype").wrap(self, self.frame)
  end

  self.covers:finish()
end

-- Painting is when the tiles learn where they are; until then a rebuild cannot
-- say which part of the panel it changes.
function HomeDialog:paintTo(...)
  InputContainer.paintTo(self, ...)
  self.painted = true
  self.pending_before = nil
end

-- UIManager:show() queues no refresh of its own (it relies on a full-panel
-- fallback that only happens when nothing else is queued), and this screen queues
-- small refreshes of its own as covers and counts arrive. Ask for the first
-- full draw explicitly so it can never be skipped in favour of a small one.
function HomeDialog:onShow()
  UIManager:setDirty(self, "ui")
end

-- Stop fetching and give back the pictures' memory.
function HomeDialog:releaseCovers()
  self.covers:release()
end

-- Build again from the current data (the counts, the books or the goals arrived),
-- redrawing the whole page, or just what changed since it was last drawn.
--
-- A rebuild makes a new widget tree, but not everything on the screen changes:
-- when counts arrive only the tiles do, when the reading list arrives only
-- everything from its heading down. Redrawing the whole panel for a number in a
-- tile costs the user a visible full-screen refresh, so the region is worked
-- out from what is on screen before and after, and only that is refreshed.
-- Before the first paint, when the layouts cannot be compared, or when the page
-- scrolls (tile positions are then relative to the scrolled content), it is the
-- whole panel.
--
-- A page the reader has scrolled down stays where it is: the data arrives a few
-- seconds after the screen opens, which is exactly when someone is scrolling, and a
-- page that jumps back to the top looks like a page that does not scroll.
function HomeDialog:rebuild()
  -- anything waiting for a later rebuild is being drawn now
  self.rebuild_due = false
  local offset = self.scroll and self.scroll:getScrolledOffset().y or 0
  -- two rebuilds before a paint (counts and the reading list arriving together)
  -- compare with what was last on screen, not with the first one's unpainted tree
  local before = self.painted and self:snapshot() or self.pending_before
  local was_scrolling = self.scroll ~= nil

  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil
  self:build()
  self.pending_before = before
  self:restoreScroll(offset)

  if not before or was_scrolling or self.scroll or self.prototype_variant then
    UIManager:setDirty(self, "ui")
    return
  end
  Refresh.region(self, function() return self:changedRegion(before) end)
end

-- What is on screen now, for comparing after a rebuild: where each tile is and
-- what it says, the reading heading's top, and the cards.
function HomeDialog:snapshot()
  local snap = { tiles = {}, cards = self.built_entries, count = 0 }
  for _i, t in ipairs(self.tiles or {}) do
    snap.tiles[t.key] = { shows = t.shows, rect = Refresh.copy(t.tile.dimen) }
    snap.count = snap.count + 1
    local r = t.tile.dimen
    if Refresh.valid(r) then
      snap.bottom = math.max(snap.bottom or 0, r.y + r.h)
    end
  end
  snap.header = self.reading_header and Refresh.copy(self.reading_header.dimen)
  return snap
end

-- The rectangle a rebuild changed, read after the new tree is painted; nil (the
-- whole panel) when the two layouts cannot be compared tile for tile.
function HomeDialog:changedRegion(before)
  local after = self:snapshot()
  if after.count ~= before.count then return nil end

  if not Home.sameCards(before.cards, after.cards) then
    -- everything from the reading heading down, where it was and where it is now
    -- (the library moves when the list gets longer or shorter)
    if not (before.header and after.header and before.bottom and after.bottom) then return nil end
    local top = math.min(before.header.y, after.header.y)
    local bottom = math.max(before.bottom, after.bottom)
    return { x = 0, y = top, w = require("device").screen:getWidth(), h = bottom - top }
  end

  local region
  for k, t in pairs(after.tiles) do
    local old = before.tiles[k]
    if not old then return nil end
    if old.shows ~= t.shows then
      if not Refresh.valid(t.rect) then return nil end
      region = Refresh.union(region, t.rect)
    end
  end
  -- nothing the panel shows differs: the smallest refresh there is
  if region then return region end
  return Refresh.valid(after.header) and { x = after.header.x, y = after.header.y, w = 1, h = 1 } or nil
end

-- Put a scrolled page back where it was (as far as the new page reaches).
function HomeDialog:restoreScroll(offset)
  local scroll = self.scroll
  if not scroll or not offset or offset <= 0 then return end
  scroll:setScrolledOffset(Geom:new { x = 0, y = math.min(offset, scroll._max_scroll_offset_y or offset) })
  if type(scroll._updateScrollBars) == "function" then
    scroll:_updateScrollBars() -- moves the scroll bar
  end
end

-- Swap in fresh counts once they arrive.
-- `soon` (the data loading in the background) waits for the others to arrive
-- instead of redrawing at once; see rebuildSoon.
function HomeDialog:setRows(rows, soon)
  self.rows = rows or {}
  if soon then self:rebuildSoon() else self:rebuild() end
end

-- Swap in the reading list (entries as Api:getCurrentlyReading returns them).
function HomeDialog:setReading(entries, soon)
  self.entries = entries or {}
  if soon then self:rebuildSoon() else self:rebuild() end
end

-- How long a background load waits for more data before redrawing. Opening Home
-- asks for the counts, the reading list, the list count and the goals one after
-- another; redrawing for each is four visible refreshes on e-ink, so what arrives
-- inside this window is drawn together.
HomeDialog.REBUILD_DELAY = 1.5

function HomeDialog:rebuildSoon()
  self.rebuild_due = true
  if self.rebuild_timer then return end
  self.rebuild_timer = function()
    self.rebuild_timer = nil
    if self.closed or not self.rebuild_due then return end
    self:rebuild()
  end
  UIManager:scheduleIn(HomeDialog.REBUILD_DELAY, self.rebuild_timer)
end

-- UIManager:close() queues no refresh of its own; without this the screen stays
-- on the panel after it has closed.
function HomeDialog:onCloseWidget()
  self.closed = true
  if self.rebuild_timer then
    UIManager:unschedule(self.rebuild_timer)
    self.rebuild_timer = nil
  end
  self:releaseCovers()
  UIManager:setDirty(nil, "ui")
end

function HomeDialog:onCloseHome()
  return self:onClose()
end

function HomeDialog:onClose()
  UIManager:close(self)
  if self.close_callback then
    self.close_callback()
  end
  return true
end

return HomeDialog
