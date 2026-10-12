-- Home as a tab of the shell: one fixed screen that never scrolls, as drawn in mock 1 / 1a.
--
-- Top to bottom: "Currently reading" with the book you read most recently as a bordered card (cover,
-- title, author, a thick progress bar, "62% · page 186 of 300" and one filled Open book
-- button); a box saying whether changes are waiting to sync (a sync icon, a count and Sync now) or
-- all is well (a check, All synced, Sync now still there), both with a dotted outline, the same height
-- either way so what is below never moves. Sync now sends; a tap anywhere else on the box opens the
-- list of what is waiting. Then "Shelves" as two-line list rows with their counts. The other books
-- being read are one tap away under Shelves > Currently reading.
--
-- It fills the room it is given: the card first, then the sync box, then as many shelf rows as fit.
-- The nav bar is not part of this body, so it can never be what gives way.
--
-- It also holds Home's data (rows, entries, cover cells) for the loaders' setRows / setReading /
-- rebuildSoon.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Button = require("hardcover/lib/ui/components/button")
local CoverCells = require("hardcover/lib/ui/cover_cells")
local Draw = require("hardcover/lib/ui/components/draw")
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local Home = require("hardcover/lib/home")
local Hosted = require("hardcover/lib/ui/hosted")
local ListItem = require("hardcover/lib/ui/components/list_item")
local Note = require("hardcover/lib/ui/components/note")
local Theme = require("hardcover/lib/ui/theme")

local px = Theme.px

local HomeBody = InputContainer:extend {
  name = "hardcover_home_body",
  rows = {},          -- Home.rows: the shelves and how many books are on each
  entries = {},       -- the books being read, as Api:getCurrentlyReading returns them
  select_cb = nil,    -- called with a shelf's row when it is tapped
  open_book_cb = nil, -- called with the book id when Open book is tapped
  pending_fn = nil, -- returns how many changes are waiting to sync
  sync_cb = nil,    -- Sync now
  pending_cb = nil, -- a tap on the sync box: what is waiting
}

function HomeBody:init()
  self.closed = false
  local w, h = Hosted.size(self)
  self.dimen = Geom:new { x = 0, y = 0, w = w, h = h }
  self.covers = CoverCells:new {
    window = Hosted.window(self),
    loader = function() return self.image_loader or require("hardcover/lib/ui/image_loader") end,
  }
  self:build()
end

-- A cover box of the given size: the generic book icon until the picture arrives, so nothing moves
-- when it does.
function HomeBody:coverCell(card, w, h)
  return self.covers:cell(card.cover_url, w, h)
end

local function booksText(n)
  if type(n) ~= "number" then return nil end
  return n == 1 and _("1 book") or string.format(_("%d books"), n)
end

-- The book being read, as a bordered card with one filled button.
function HomeBody:readingCard(card, width)
  local pad, border = px(14), px(3)
  local inner = width - 2 * pad - 2 * border
  local cw, ch = px(84), px(126)
  local gap = px(14)
  local text_w = inner - cw - gap
  local face, bold = Theme.title(25)
  local info = VerticalGroup:new { align = "left",
    TextBoxWidget:new { text = card.title, face = face, bold = bold, width = text_w,
      height = 3 * (face.size * 1.3), height_adjust = true, height_overflow_show_ellipsis = true } }
  if card.author and card.author ~= "" then
    info[#info + 1] = Theme.span(px(6))
    info[#info + 1] = Theme.mmdText(card.author, "text", 18, { secondary = true, width = text_w })
  end
  if card.fraction then
    info[#info + 1] = Theme.span(px(14))
    info[#info + 1] = Theme.progress { width = text_w, height = px(12), percentage = card.fraction }
  end
  local line
  if card.fraction and card.current and card.total then
    line = string.format(_("%d%% · page %d of %d"), math.floor(card.fraction * 100 + 0.5), card.current, card.total)
  elseif card.total then
    line = string.format(_("%d pages"), card.total)
  end
  if line then
    info[#info + 1] = Theme.span(px(6))
    info[#info + 1] = Theme.mmdText(line, "text", 18, { secondary = true, width = text_w })
  end
  local top = HorizontalGroup:new { align = "top",
    self:coverCell(card, cw, ch), Theme.hspan(gap), info }
  local open = Button.new { label = _("Open book"), w = inner, h = px(56), primary = true,
    callback = function() if self.open_book_cb then self.open_book_cb(card.book_id) end end }
  self.open_button = open
  return FrameContainer:new { bordersize = border, radius = px(12), padding = pad, margin = 0,
    color = Theme.BLACK, background = Theme.WHITE,
    VerticalGroup:new { align = "left", top, Theme.span(px(14)), open } }
end

-- Nothing being read (or nothing loaded yet): say so, in the same box.
function HomeBody:emptyCard(width)
  local pad, border = px(14), px(3)
  return FrameContainer:new { bordersize = border, radius = px(12), padding = pad, margin = 0,
    color = Theme.BLACK, background = Theme.WHITE,
    VerticalGroup:new { align = "left",
      Theme.mmdText(_("Nothing to show yet"), "strong", 21, { width = width - 2 * pad - 2 * border }),
      Theme.span(px(4)),
      Theme.mmdText(_("Books you are reading will appear here."), "text", 18,
        { secondary = true, width = width - 2 * pad - 2 * border }) } }
end

-- The sync box, dotted whether or not anything is waiting; the two states differ by icon and words,
-- and are built at the taller one's height so switching between them moves nothing below.
function HomeBody:syncNote(width)
  local waiting = self.pending_fn and self.pending_fn() or 0
  local action = { label = _("Sync now"), callback = function() if self.sync_cb then self.sync_cb() end end }
  local on_tap = function() if self.pending_cb then self.pending_cb() end end
  local function make(count, h)
    if count > 0 then
      return Note.new { width = width, h = h, dotted = true, icon_name = "sync", action = action, on_tap = on_tap,
        title = count == 1 and _("1 change waiting") or string.format(_("%d changes waiting"), count),
        text = _("They sync when you are online.") }
    end
    return Note.new { width = width, h = h, dotted = true, icon_name = "check", action = action, on_tap = on_tap,
      title = _("All synced"), text = _("Nothing is waiting to send.") }
  end
  local probe = make(waiting > 0 and 0 or 1)
  local h = math.max(probe:getSize().h, make(waiting):getSize().h)
  probe:free()
  return make(waiting, h)
end

-- One shelf as a list row: its name, how many books, a chevron.
function HomeBody:shelfRow(row, width, last)
  return ListItem.new {
    width = width, label = row.title, support = booksText(row.count),
    trailing = Draw.chevron("right"), divider = (not last) and "dotted" or nil,
    callback = function() if self.select_cb then self.select_cb(row) end end,
  }
end

function HomeBody:build()
  self.covers:begin()
  self.built_entries = self.entries

  local w, h = Hosted.size(self)
  local side = ListItem.PAD
  local width = w - 2 * side
  local cards = Home.cards(self.entries)
  local card = cards[1]

  local column = VerticalGroup:new { align = "left" }
  local function inset(widget) return HorizontalGroup:new { Theme.hspan(side), widget } end

  column[#column + 1] = Theme.span(px(8))
  column[#column + 1] = ListItem.section(_("Currently reading"), w, 0)
  column[#column + 1] = inset(card and self:readingCard(card, width) or self:emptyCard(width))
  column[#column + 1] = Theme.span(px(10))
  local used = column:getSize().h

  -- the sync box, if there is room for it under the card
  local note = self:syncNote(width)
  local shown_note = false
  if used + note:getSize().h <= h then
    column[#column + 1] = inset(note)
    used = used + note:getSize().h
    shown_note = true
  end

  -- then the shelves: the head and as many rows as fit
  local rows = {}
  for _i, row in ipairs(Home.listOrder(self.rows)) do rows[#rows + 1] = row end
  local head = ListItem.section(_("Shelves"), w, px(4))
  local shown_rows = 0
  if shown_note then
    local room = h - used - head:getSize().h
    local items = {}
    for i, row in ipairs(rows) do
      local item = self:shelfRow(row, w, i == #rows)
      if item:getSize().h > room then break end
      room = room - item:getSize().h
      items[#items + 1] = item
    end
    if #items > 0 then
      column[#column + 1] = head
      for _i, item in ipairs(items) do column[#column + 1] = item end
      shown_rows = #items
    end
  end
  self.layout = { card = card ~= nil, note = shown_note, shelves = shown_rows } -- what fitted
  column:resetLayout()

  self.frame = FrameContainer:new {
    width = w, height = h, background = Blitbuffer.COLOR_WHITE,
    bordersize = 0, padding = 0, margin = 0, column,
  }
  self.dimen = Geom:new { x = 0, y = 0, w = w, h = h }
  self[1] = self.frame
  self.covers:finish()
end

-- The page never scrolls, so a rebuild is one redraw of this body.
function HomeBody:rebuild()
  self.rebuild_due = false
  if self[1] and type(self[1].free) == "function" then
    pcall(function() self[1]:free() end)
  end
  self[1] = nil
  self:build()
  Hosted.dirty(self)
end

function HomeBody:onShow() end

-- Stop fetching and give back the pictures' memory.
function HomeBody:releaseCovers()
  self.covers:release()
end

-- Swap in fresh counts once they arrive.
-- `soon` (the data loading in the background) waits for the others to arrive instead of redrawing
-- at once; see rebuildSoon.
function HomeBody:setRows(rows, soon)
  self.rows = rows or {}
  if soon then self:rebuildSoon() else self:rebuild() end
end

-- Swap in the reading list (entries as Api:getCurrentlyReading returns them).
function HomeBody:setReading(entries, soon)
  self.entries = entries or {}
  if soon then self:rebuildSoon() else self:rebuild() end
end

-- How long a background load waits for more data before redrawing. Opening Home asks for the
-- counts, the reading list and the goals one after another; redrawing for each is a visible refresh
-- on e-ink each, so what arrives inside this window is drawn together.
HomeBody.REBUILD_DELAY = 1.5

function HomeBody:rebuildSoon()
  self.rebuild_due = true
  if self.rebuild_timer then return end
  self.rebuild_timer = function()
    self.rebuild_timer = nil
    if self.closed or not self.rebuild_due then return end
    self:rebuild()
  end
  UIManager:scheduleIn(HomeBody.REBUILD_DELAY, self.rebuild_timer)
end

function HomeBody:onCloseWidget()
  self.closed = true
  if self.rebuild_timer then
    UIManager:unschedule(self.rebuild_timer)
    self.rebuild_timer = nil
  end
  self:releaseCovers()
end

function HomeBody:onClose()
  return true -- the shell leaves, not a tab
end

return HomeBody
