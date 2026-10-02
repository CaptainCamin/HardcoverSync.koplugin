-- The home screen: what you are reading now, then your shelves.
--
-- A title bar, a search field, then a column that is not scrolled: a
-- "Currently reading" section (the first book as a hero card with its cover,
-- title and progress, the rest as compact rows, as many as fit), then a
-- "Library" section of four count tiles, one per shelf. Not scrolling is deliberate. A
-- ScrollableContainer keeps tap ranges for children that are scrolled out of
-- view, and those can steal taps from the buttons that are on screen; with a
-- fixed column every tappable thing is where it is drawn.
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
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local _ = require("gettext")

local Home = require("hardcover/lib/home")
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local CoverCells = require("hardcover/lib/ui/cover_cells")
local Refresh = require("hardcover/lib/ui/refresh")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

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
  list_count = nil,
  close_callback = nil,
}

function HomeDialog:init()
  self.closed = false
  self.key_events.CloseHome = { { "Back" } }
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
function HomeDialog:tappable(widget, book_id)
  return TapRow:new {
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
function HomeDialog:buildCard(card, width)
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
    self:tappable(row, card.book_id),
    Theme.span("s"),
  }
end

-- One shelf tile: the count big, the name beside it. Tapping opens the shelf.
function HomeDialog:buildTile(row, w, h)
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
      elseif self.select_cb then
        self.select_cb(row)
      end
    end,
    Theme.box(w, h, line, { radius = 10 }),
  }
  -- what the tile shows, so a rebuild can tell which tiles changed (and so which
  -- part of the panel needs redrawing)
  self.tiles[#self.tiles + 1] = { key = row.lists and "lists" or tostring(row.status_id or row.title),
    shows = (row.title or "") .. "|" .. Home.countText(row.count), tile = tile }
  return tile
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
  local width = screen_w - 2 * M
  local function inset(widget)
    return HorizontalGroup:new { Theme.hspan(M), widget }
  end

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

  -- The search field: a rounded outline that reads as an input, and opens the
  -- search box when tapped. The words are centred in it by a container of the
  -- field's own size (a frame given a height does not centre its text).
  local field_h = Screen:scaleBySize(52)
  local search_icon = Screen:scaleBySize(26)
  local field = TapRow:new {
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
    local pair = HorizontalGroup:new { self:buildTile(rows[i], tile_w, tile_h) }
    if rows[i + 1] then
      table.insert(pair, Theme.hspan("m"))
      table.insert(pair, self:buildTile(rows[i + 1], tile_w, tile_h))
    end
    table.insert(library, pair)
    if rows[i + 2] then table.insert(library, Theme.span("m")) end
  end
  self.library = library

  local column = VerticalGroup:new { align = "left" }
  table.insert(column, Theme.span("m"))
  table.insert(column, field)
  table.insert(column, Theme.span("m"))

  -- The heading is always there (it is the way into the Currently Reading
  -- shelf); the cards under it are whatever has been loaded.
  local cards = Home.cards(self.entries)
  local right = HorizontalGroup:new { align = "center" }
  if #cards > 0 then
    local count = #cards == 1 and _("1 book") or string.format(_("%d books"), #cards)
    table.insert(right, text(count, "small", { grey = true }))
    table.insert(right, Theme.hspan("s"))
  end
  table.insert(right, text("\226\128\186", "title", { bold = true }))
  local header = TapRow:new {
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

  if #cards > 0 then
    column:resetLayout() -- a VerticalGroup keeps its size until told otherwise
    local room = screen_h - title_bar:getSize().h - column:getSize().h
      - Theme.space.m - library:getSize().h - Theme.space.m - Theme.space.l
    for i, card in ipairs(cards) do
      local widget = self:buildCard(card, width)
      local h = widget:getSize().h
      -- always show the first, so the section never reads as empty
      if i > 1 and h > room then
        widget:free()
        break
      end
      room = room - h
      table.insert(column, widget)
    end
    table.insert(column, Theme.span("m"))
  end
  table.insert(column, library)
  column:resetLayout() -- children were added since its size was last read

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
      inset(column),
    },
  }
  self.dimen = Geom:new { x = 0, y = 0, w = screen_w, h = screen_h }
  self[1] = self.frame

  self.covers:finish()
end

-- Painting is when the tiles learn where they are; until then a rebuild cannot
-- say which part of the panel it changes.
function HomeDialog:paintTo(...)
  InputContainer.paintTo(self, ...)
  self.painted = true
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

-- The whole page, or just what changed since it was last drawn.
--
-- A rebuild makes a new widget tree, but not everything on the screen changes:
-- when counts arrive only the tiles do, when the reading list arrives only
-- everything from its heading down. Redrawing the whole panel for a number in a
-- tile costs the user a visible full-screen refresh, so the region is worked
-- out from what is on screen before and after, and only that is refreshed.
-- Before the first paint, or when the layouts cannot be compared, it is the whole
-- panel.
function HomeDialog:rebuild()
  local before = self.painted and self:snapshot() or nil

  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil
  self:build()

  if not before then
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
