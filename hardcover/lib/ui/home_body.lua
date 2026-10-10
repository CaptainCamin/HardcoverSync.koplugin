-- Home as a tab of the shell: one fixed screen that never scrolls.
--
-- From the top: the search field, the "Currently reading" heading with the books being read as
-- cards, a quiet line about changes waiting to sync ("All synced" when there are none), and the
-- shelves as list rows. It fills the room it is given: the cards come first, as many as fit
-- (three at most); when even one card does not fit alongside the rest, the shelves are dropped,
-- then the sync line. The nav bar is not part of this body, so it can never be what gives way.
--
-- It is the old Home's data holder (HomeDialog: rows, entries, cards, cover cells, the loaders'
-- setRows / setReading / rebuildSoon) with a different layout and no scrolling. Goals, Stats, the
-- lists and the vibes are tabs of their own, so they are not on this page.

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")

local CoverCells = require("hardcover/lib/ui/cover_cells")
local Draw = require("hardcover/lib/ui/components/draw")
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local Home = require("hardcover/lib/home")
local HomeDialog = require("hardcover/lib/ui/home_dialog")
local Hosted = require("hardcover/lib/ui/hosted")
local ListItem = require("hardcover/lib/ui/components/list_item")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local HomeBody = HomeDialog:extend {
  name = "hardcover_home_body",
  pending_fn = nil, -- returns how many changes are waiting to sync
  note_cb = nil,    -- the sync line was tapped
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

-- The search field: a rounded outline that reads as an input.
function HomeBody:searchField(width)
  local field_h = Screen:scaleBySize(52)
  local icon = Screen:scaleBySize(26)
  return TapRow:new {
    callback = function() if self.search_cb then self.search_cb() end end,
    Theme.box(width, field_h, LeftContainer:new {
      dimen = Geom:new { w = width - 2 * Theme.line.firm, h = field_h - 2 * Theme.line.firm },
      HorizontalGroup:new { align = "center", Theme.hspan("m"),
        IconWidget:new { icon = "appbar.search", width = icon, height = icon },
        Theme.hspan("s"),
        Theme.mmdText(_("Search books on Hardcover"), "text", 18, { secondary = true, width = width - 4 * Theme.space.m }) },
    }, { radius = 26 }),
  }
end

-- "Currently reading", with how many, as the way into that shelf.
function HomeBody:readingHeader(width, total)
  local right = HorizontalGroup:new { align = "center" }
  if total > 0 then
    local count = total == 1 and _("1 book") or string.format(_("%d books"), total)
    right[#right + 1] = Theme.mmdText(count, "text", 15, { secondary = true })
    right[#right + 1] = Theme.hspan("s")
  end
  right[#right + 1] = Draw.chevron("right")
  return TapRow:new {
    callback = function()
      if self.select_cb then
        self.select_cb({ status_id = HARDCOVER.STATUS.READING, title = _("Currently Reading") })
      end
    end,
    Theme.sectionHeader(_("Currently reading"), width, right),
  }
end

-- One quiet line: nothing waiting, or how many changes are and a way to the screen that sends them.
function HomeBody:syncNote(width)
  local waiting = self.pending_fn and self.pending_fn() or 0
  local label = waiting == 0 and _("All synced")
    or (waiting == 1 and _("1 change waiting to sync") or string.format(_("%d changes waiting to sync"), waiting))
  local line = HorizontalGroup:new { align = "center",
    Theme.mmdText(label, waiting == 0 and "text" or "strong", 18, { secondary = waiting == 0, width = width - Theme.space.xl }) }
  if waiting > 0 then
    line[#line + 1] = Theme.hspan("s")
    line[#line + 1] = Draw.chevron("right")
  end
  local row = LeftContainer:new { dimen = Geom:new { w = width, h = Theme.TOUCH_MIN }, line }
  return waiting > 0 and TapRow:new { callback = function() if self.note_cb then self.note_cb() end end, row } or row
end

-- The shelves other than the one the heading opens, as rows with their counts.
function HomeBody:shelfRows(width)
  local group = VerticalGroup:new { align = "left" }
  local shown = {}
  for _i, row in ipairs(self.rows or {}) do
    if row.status_id ~= HARDCOVER.STATUS.READING then shown[#shown + 1] = row end
  end
  for i, row in ipairs(shown) do
    local trailing = HorizontalGroup:new { align = "center" }
    local count = Home.countText(row.count)
    if count ~= "" then
      trailing[#trailing + 1] = Theme.mmdText(count, "text", 18, { secondary = true })
      trailing[#trailing + 1] = Theme.hspan("s")
    end
    trailing[#trailing + 1] = Draw.chevron("right")
    group[#group + 1] = ListItem.new {
      width = width, label = row.title, trailing = trailing, strong = false,
      divider = i < #shown and "dotted" or nil,
      callback = function() if self.select_cb then self.select_cb(row) end end,
    }
  end
  return group
end

function HomeBody:build()
  self.covers:begin()
  self.tiles = {}
  self.built_entries = self.entries

  local w, h = Hosted.size(self)
  local width = w - 2 * Theme.margin

  local cards = Home.cards(self.entries)
  local reading_total = #cards
  for _i, row in ipairs(self.rows or {}) do
    if row.status_id == HARDCOVER.STATUS.READING and type(row.count) == "number" and row.count >= #cards then
      reading_total = row.count
    end
  end

  local field = self:searchField(width)
  local header = self:readingHeader(width, reading_total)
  self.search_button, self.reading_header = field, header
  local note = self:syncNote(width)
  local shelves = self:shelfRows(w)

  -- what is fixed above the cards, in order: space, search, space, heading, space
  local top_h = Theme.space.m * 3 + field:getSize().h + header:getSize().h
  local card_h = #cards > 0 and self:buildCard(cards[1], width, nil):getSize().h or 0
  local empty = #cards == 0 and Theme.mmdText(_("Nothing to show yet. Tap the heading to open the shelf."),
    "text", 15, { secondary = true, width = width }) or nil
  local empty_h = empty and (empty:getSize().h + Theme.space.l) or 0
  local note_h, shelves_h = note:getSize().h, shelves:getSize().h

  -- the cards first, down to one; then the shelves go, then the sync line
  local show_note, show_shelves = true, true
  local count = 0
  if #cards > 0 then
    local function fits(extra)
      return math.floor((h - top_h - extra) / (card_h + Theme.space.m))
    end
    count = fits(note_h + shelves_h)
    if count < 1 then
      show_shelves = false
      count = fits(note_h)
    end
    if count < 1 then
      show_note = false
      count = math.max(1, fits(0))
    end
    count = math.min(count, #cards, HomeDialog.MAX_CARDS)
  end

  -- the narrow parts sit inside the page margin; the shelf rows carry their own side padding
  local function inset(widget) return HorizontalGroup:new { Theme.hspan(Theme.margin), widget } end
  self.layout = { cards = count, note = show_note, shelves = show_shelves } -- what fitted
  local column = VerticalGroup:new { align = "left" }
  column[#column + 1] = Theme.span("m")
  column[#column + 1] = inset(field)
  column[#column + 1] = Theme.span("m")
  column[#column + 1] = inset(header)
  column[#column + 1] = Theme.span("m")
  if empty then
    column[#column + 1] = inset(empty)
    column[#column + 1] = Theme.span("l")
  end
  for i = 1, count do
    column[#column + 1] = inset(self:buildCard(cards[i], width, nil))
    column[#column + 1] = Theme.span("m")
  end
  if show_note then column[#column + 1] = inset(note) end
  if show_shelves then column[#column + 1] = shelves end
  column:resetLayout()

  self.frame = FrameContainer:new {
    width = w, height = h, background = Blitbuffer.COLOR_WHITE,
    bordersize = 0, padding = 0, margin = 0,
    column,
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
