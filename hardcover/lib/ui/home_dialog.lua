-- The home screen: what you are reading now, then your shelves.
--
-- A title bar, then a column that is not scrolled: the "Currently reading"
-- cards (cover, title, author, progress) as many as fit above the shelf
-- buttons, then one button per shelf. Not scrolling is deliberate. A
-- ScrollableContainer keeps tap ranges for children that are scrolled out of
-- view, and those can steal taps from the buttons that are on screen; with a
-- fixed column every tappable thing is where it is drawn.
--
-- Choosing a card opens that book; choosing a shelf opens it on top of this
-- screen, so closing the shelf comes back here.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
-- VerticalSpan takes its size as `width` (it has no `height`)
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Home = require("hardcover/lib/home")

local Screen = Device.screen

--
-- A tappable region that only answers taps inside what it draws.
--
-- The range is read from `self.dimen` at tap time, which paintTo keeps current,
-- so a card that is not on screen (or is covered by another screen) has no
-- range at all. Local to the home screen on purpose: it never scrolls, so this
-- is all the clipping it needs.
--
local TapRegion = InputContainer:extend {
  callback = nil,
}

function TapRegion:init()
  self.dimen = Geom:new { w = 0, h = 0 }
  if self[1] and self[1].getSize then
    local size = self[1]:getSize()
    self.dimen.w, self.dimen.h = size.w, size.h
  end
  self.ges_events = {
    TapSelect = {
      GestureRange:new {
        ges = "tap",
        range = function() return self.dimen end,
      },
    },
  }
end

function TapRegion:onTapSelect()
  if self.callback then
    self.callback()
  end
  return true
end

local HomeDialog = InputContainer:extend {
  name = "hardcover_home_dialog",
  title = _("Hardcover"),
  rows = {},
  entries = {},
  select_cb = nil,
  open_book_cb = nil,
  settings_cb = nil,
  search_cb = nil,
  close_callback = nil,
}

function HomeDialog:init()
  self.closed = false
  self.key_events.CloseHome = { { "Back" } }
  self:build()
end

-- the cover box's size, and the card's other measurements
local function metrics()
  local cover_w = Screen:scaleBySize(64)
  return {
    cover_w = cover_w,
    cover_h = math.floor(cover_w * 1.5),
    gap = Screen:scaleBySize(12),
    side = Screen:scaleBySize(16),
    border = Size.border.thin,
    padding = Size.padding.default,
  }
end

function HomeDialog:buildCard(card, width, m)
  local inner = width - 2 * m.border - 2 * m.padding
  local text_w = inner - m.cover_w - 2 * m.border - m.gap

  -- the cover box is always there; the picture replaces the placeholder when it
  -- arrives, and never does for a book with no cover
  local icon_size = math.floor(m.cover_w * 0.5)
  local cover_cell = FrameContainer:new {
    bordersize = m.border,
    padding = 0,
    margin = 0,
    CenterContainer:new {
      dimen = Geom:new { w = m.cover_w, h = m.cover_h },
      IconWidget:new { icon = "book.opened", width = icon_size, height = icon_size },
    },
  }
  if card.cover_url then
    self.cover_cells[card.cover_url] = self.cover_cells[card.cover_url] or {}
    table.insert(self.cover_cells[card.cover_url], cover_cell)
  end

  local title_face = Font:getFace("cfont", 20)
  local title = TextBoxWidget:new {
    text = card.title,
    face = title_face,
    bold = true,
    width = text_w,
    height = 2 * title_face.size * 1.4,
    height_adjust = true,
    height_overflow_show_ellipsis = true,
  }

  local text = VerticalGroup:new { align = "left", title }
  if card.author and card.author ~= "" then
    table.insert(text, TextWidget:new {
      text = card.author,
      face = Font:getFace("cfont", 16),
      max_width = text_w,
    })
  end

  if card.fraction or card.progress_text then
    table.insert(text, VerticalSpan:new { width = Screen:scaleBySize(8) })
    if card.fraction then
      table.insert(text, ProgressWidget:new {
        width = text_w,
        height = Screen:scaleBySize(8),
        percentage = card.fraction,
        ticks = nil,
        last = nil,
      })
      table.insert(text, VerticalSpan:new { width = Screen:scaleBySize(4) })
    end
    if card.progress_text then
      table.insert(text, TextWidget:new {
        text = card.progress_text,
        face = Font:getFace("cfont", 15),
        max_width = text_w,
      })
    end
  end

  -- the text column is centred against the cover
  local body = HorizontalGroup:new {
    align = "center",
    cover_cell,
    HorizontalSpan:new { width = m.gap },
    text,
  }

  local frame = FrameContainer:new {
    bordersize = m.border,
    padding = m.padding,
    margin = 0,
    width = width,
    background = Blitbuffer.COLOR_WHITE,
    body,
  }

  local book_id = card.book_id
  return TapRegion:new {
    callback = function()
      if self.open_book_cb then
        self.open_book_cb(book_id)
      end
    end,
    frame,
  }
end

function HomeDialog:sectionTitle(text, width)
  return TextWidget:new {
    text = text,
    face = Font:getFace("cfont", 17),
    bold = true,
    max_width = width,
  }
end

-- Build everything from the current rows and entries. Pure function of both, so
-- a rebuild cannot leave a stale widget behind.
function HomeDialog:build()
  self:releaseCovers()
  self.cover_cells = {}

  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local m = metrics()
  local width = screen_w - 2 * m.side
  local gap = Screen:scaleBySize(10)

  local title_bar = TitleBar:new {
    width = screen_w,
    fullscreen = true,
    align = "center",
    title = self.title,
    -- the cog opens the plugin's settings
    left_icon = "appbar.settings",
    left_icon_tap_callback = function()
      if self.settings_cb then
        self.settings_cb()
      end
    end,
    with_bottom_line = true,
    close_callback = function() self:onClose() end,
    show_parent = self,
  }

  -- The shelf buttons come first in the build so their height is known: the
  -- cards get whatever the screen has left.
  local shelves = VerticalGroup:new { align = "left" }
  table.insert(shelves, self:sectionTitle(_("Shelves"), width))
  table.insert(shelves, VerticalSpan:new { width = Screen:scaleBySize(6) })
  for _, row in ipairs(self.rows or {}) do
    table.insert(shelves, Button:new {
      text = Home.rowLabel(row),
      width = width,
      text_font_size = 20,
      padding_v = Screen:scaleBySize(10),
      callback = function()
        if self.select_cb then
          self.select_cb(row)
        end
      end,
    })
    table.insert(shelves, VerticalSpan:new { width = Screen:scaleBySize(6) })
  end

  -- A small button, on the same line as the "Currently reading" heading (or
  -- alone, right-aligned, when nothing is being read), so the top of the screen
  -- stays uncrowded. Not full width: it is a shortcut, not the main thing here.
  local search_button = Button:new {
    text = _("Search books"),
    text_font_size = 15,
    padding_h = Screen:scaleBySize(10),
    padding_v = Screen:scaleBySize(3),
    margin = 0,
    callback = function()
      if self.search_cb then
        self.search_cb()
      end
    end,
  }
  self.search_button = search_button

  local column = VerticalGroup:new { align = "left" }
  table.insert(column, VerticalSpan:new { width = gap })

  local cards = Home.cards(self.entries)
  local heading = #cards > 0 and self:sectionTitle(_("Currently reading"), width) or nil
  local header_row = HorizontalGroup:new { align = "center" }
  if heading then
    table.insert(header_row, heading)
  end
  table.insert(header_row, HorizontalSpan:new {
    width = math.max(0, width - (heading and heading:getSize().w or 0) - search_button:getSize().w),
  })
  table.insert(header_row, search_button)
  table.insert(column, header_row)
  table.insert(column, VerticalSpan:new { width = Screen:scaleBySize(6) })

  if #cards > 0 then
    local room = screen_h - title_bar:getSize().h - shelves:getSize().h - 3 * gap
      - header_row:getSize().h - Screen:scaleBySize(6) - gap
    local shown = 0
    for _, card in ipairs(cards) do
      local widget = self:buildCard(card, width, m)
      local h = widget:getSize().h + Screen:scaleBySize(8)
      -- always show the first, so the section never reads as empty
      if shown > 0 and h > room then
        widget:free()
        break
      end
      room = room - h
      shown = shown + 1
      table.insert(column, widget)
      table.insert(column, VerticalSpan:new { width = Screen:scaleBySize(8) })
    end
    table.insert(column, VerticalSpan:new { width = gap })
  end
  table.insert(column, shelves)

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
      HorizontalGroup:new {
        HorizontalSpan:new { width = m.side },
        column,
      },
    },
  }
  self.dimen = Geom:new { x = 0, y = 0, w = screen_w, h = screen_h }
  self[1] = self.frame

  self:loadCovers(m)
end

-- Fetch each distinct cover and put it in its box(es). The loader answers from
-- the on-disk cache first and does not touch the network when offline.
function HomeDialog:loadCovers(m)
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
    local bb = RenderImage:renderImageData(content, #content, false, m.cover_w, m.cover_h)
    if not bb then return end
    table.insert(self.cover_bbs, bb)

    for _, cell in ipairs(cells) do
      cell[1] = CenterContainer:new {
        dimen = Geom:new { w = m.cover_w, h = m.cover_h },
        ImageWidget:new {
          image = bb,
          image_disposable = false,
          width = m.cover_w,
          height = m.cover_h,
          scale_factor = 0,
        },
      }
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
