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
local GestureRange = require("ui/gesturerange")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local ScrollPager = require("hardcover/lib/ui/scroll_pager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local _ = require("gettext")

local Goals = require("hardcover/lib/goals")
local GoalWidgets = require("hardcover/lib/ui/goal_widgets")
local Home = require("hardcover/lib/home")
local HARDCOVER = require("hardcover/lib/constants/hardcover")
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
  -- A swipe up or down moves the page by a view. The scroll container does this itself
  -- (and gets the swipe first, being a child); this is the page asking too, so a swipe
  -- still works where the container's does not.
  self.ges_events.HomeSwipe = {
    GestureRange:new { ges = "swipe", range = function() return self.dimen end },
  }
  self:build()
end

-- A cover box of the given size: the generic book icon until the picture
-- arrives (loadCovers swaps it in), so nothing moves when it does.
function HomeDialog:coverCell(card, w, h)
  local icon_size = math.floor(w * 0.5)
  local cell = FrameContainer:new {
    bordersize = Theme.line.hair,
    padding = 0,
    margin = 0,
    CenterContainer:new {
      dimen = Geom:new { w = w, h = h },
      IconWidget:new { icon = "book.opened", width = icon_size, height = icon_size },
    },
  }
  if card.cover_url then
    self.cover_cells[card.cover_url] = self.cover_cells[card.cover_url] or {}
    table.insert(self.cover_cells[card.cover_url], { cell = cell, w = w, h = h })
  end
  return cell
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

local function text(str, size, opts)
  opts = opts or {}
  return TextWidget:new {
    text = str,
    face = Theme.face(size),
    bold = opts.bold,
    max_width = opts.width,
    fgcolor = opts.grey and Theme.DARK_GREY or Theme.BLACK,
  }
end

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
function HomeDialog:buildTile(row, w, h, viewport)
  local line = HorizontalGroup:new { align = "center" }
  local count = Home.countText(row.count)
  if count ~= "" then
    table.insert(line, text(count, "display", { bold = true, width = w }))
    table.insert(line, Theme.hspan("m"))
  end
  table.insert(line, text(row.title, "small", { width = w - Theme.space.l }))
  return TapRow:new {
    callback = function()
      if row.lists then
        if self.lists_cb then self.lists_cb() end
      elseif self.select_cb then
        self.select_cb(row)
      end
    end,
    Theme.box(w, h, line, { radius = 10 }),
  }
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
  end
  column:resetLayout() -- children were added since its size was last read
  return column
end

-- Build everything from the current rows and entries. Pure function of both, so
-- a rebuild cannot leave a stale widget behind.
function HomeDialog:build()
  self:releaseCovers()
  self.cover_cells = {}

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

  -- First at full width. If that is taller than the screen, again narrower (to
  -- leave the scroll bar its gutter) inside a scrolling container, with every tap
  -- clipped to what the container shows (see viewport.lua). A page that fits is
  -- not scrolled at all, so nothing changes for it.
  local width = screen_w - 2 * M
  local column = self:buildColumn(width, nil)
  local body
  self.scroll = nil
  if column:getSize().h > room then
    self.cover_cells = {}
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

  self:loadCovers()
end

-- Fetch each distinct cover and put it in its box(es). The loader answers from
-- the on-disk cache first and does not touch the network when offline.
function HomeDialog:loadCovers()
  local urls = {}
  for url in pairs(self.cover_cells) do
    urls[#urls + 1] = url
  end
  if #urls == 0 then return end
  table.sort(urls)

  local loader = self.image_loader or require("hardcover/lib/ui/image_loader")
  self.cover_bbs = {}
  local _batch, halt = loader:loadImages(urls, function(url, content)
    if self.closed then return end
    local cells = self.cover_cells and self.cover_cells[url]
    if not cells then return end

    local RenderImage = require("ui/renderimage")
    for _, spec in ipairs(cells) do
      local bb = RenderImage:renderImageData(content, #content, false, spec.w, spec.h)
      if bb then
        table.insert(self.cover_bbs, bb)
        spec.cell[1] = CenterContainer:new {
          dimen = Geom:new { w = spec.w, h = spec.h },
          ImageWidget:new {
            image = bb,
            image_disposable = false,
            width = spec.w,
            height = spec.h,
            scale_factor = 0,
          },
        }
      end
    end
    UIManager:setDirty(self, "ui")
  end)
  self.cover_halt = halt
end

-- Stop fetching and give back the pictures' memory.
function HomeDialog:releaseCovers()
  if self.cover_halt then
    self.cover_halt()
    self.cover_halt = nil
  end
  for _, bb in ipairs(self.cover_bbs or {}) do
    if bb.free then bb:free() end
  end
  self.cover_bbs = nil
end

-- Build again from the current data (the counts, the books or the goals arrived).
-- A page the reader has scrolled down stays where it is: the data arrives a few
-- seconds after the screen opens, which is exactly when someone is scrolling, and a
-- page that jumps back to the top looks like a page that does not scroll.
function HomeDialog:rebuild()
  local offset = self.scroll and self.scroll:getScrolledOffset().y or 0
  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil
  self:build()
  self:restoreScroll(offset)
  UIManager:setDirty(self, "ui")
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
function HomeDialog:setRows(rows)
  self.rows = rows or {}
  self:rebuild()
end

-- Swap in the reading list (entries as Api:getCurrentlyReading returns them).
function HomeDialog:setReading(entries)
  self.entries = entries or {}
  self:rebuild()
end

-- UIManager:close() queues no refresh of its own; without this the screen stays
-- on the panel after it has closed.
function HomeDialog:onCloseWidget()
  self.closed = true
  self:releaseCovers()
  UIManager:setDirty(nil, "ui")
end

function HomeDialog:onHomeSwipe(_, ges)
  local scroll = self.scroll
  if not scroll then return false end
  local delta = ges.direction == "north" and 1 or ges.direction == "south" and -1 or nil
  if not delta then return false end
  local p = ScrollPager.position(scroll)
  local target = math.max(0, math.min(p.max, p.offset + delta * p.step))
  if target ~= p.offset then
    -- scrollToRatio puts the middle of the view at a point of the whole page
    scroll:scrollToRatio(nil, (target + p.step / 2) / (p.max + p.step))
  end
  return true
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
