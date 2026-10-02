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
local ImageWidget = require("ui/widget/imagewidget")
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
function HomeDialog:build()
  self:releaseCovers()
  self.cover_cells = {}

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
  table.insert(column, header)
  table.insert(column, Theme.span("m"))

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

function HomeDialog:rebuild()
  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil
  self:build()
  UIManager:setDirty(self, "ui")
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
