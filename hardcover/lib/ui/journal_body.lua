-- The Library's Journal tab: your journal on Hardcover, newest first, a page at a time like a shelf.
-- One row per entry, every row the same height and in the same place on every page: the book's
-- cover, its title in bold, what happened (progress, a start or a finish, a rating, a list, or the
-- note, quote or review you wrote), and the authors with the day. Every row with something to open
-- shows a chevron: a note, quote or review opens its whole text, anything else the book.
--
-- The scroll control at the right edge steps by page (a swipe up or down, or the page keys, do the
-- same) and the footer says which entries are on show. Past what is loaded, a "Load more" block at
-- the end of the last page asks for the next page.
--
-- The body fetches nothing itself. DialogManager:showJournal feeds it (setEntries, setMessage) and
-- supplies `more_cb`. Row text comes from hardcover/lib/journal.lua.

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Button = require("hardcover/lib/ui/components/button")
local CoverCells = require("hardcover/lib/ui/cover_cells")
local Draw = require("hardcover/lib/ui/components/draw")
local Hosted = require("hardcover/lib/ui/hosted")
local Journal = require("hardcover/lib/journal")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local px = Theme.px

-- the shelf's cover and side, with room for the third line
local ROW_H = px(104)
local COVER_W, COVER_H = px(46), px(68)
local FOOTER_H = px(40)
local SIDE = px(16)

local JournalBody = InputContainer:extend {
  name = "hardcover_journal",
  entries = nil,   -- Journal.parse's entries (with what is waiting on top), in display order
  message = nil,   -- shown instead of the rows: loading, nothing yet, offline
  has_more = false,
  loading = false, -- the next page is on its way
  page = 1,
  select_cb = nil, -- function(entry), for a row that has something to open
  more_cb = nil,   -- function(), the Load more block
  image_loader = nil,
  now = nil,       -- function() -> seconds, for "Today" (the harness sets it)
  shell = nil,
  width = nil,
  height = nil,
  parent = nil,    -- the Library body that holds this tab
}

function JournalBody:init()
  local w, h = Hosted.size(self)
  self.dimen = Geom:new { x = 0, y = 0, w = w, h = h }
  self.entries = self.entries or {}
  self.page = self.page or 1
  if Device:hasKeys() then
    self.key_events.NextPage = { { Device.input.group.PgFwd } }
    self.key_events.PrevPage = { { Device.input.group.PgBack } }
  end
  if Device:isTouchDevice() then
    -- a swipe up pages on, down pages back (the triangles do the same)
    self.ges_events = {
      SwipeJournal = { GestureRange:new { ges = "swipe", range = function() return self.dimen end } },
    }
  end
  -- pictures already decoded are kept across pages and rebuilds (see cover_cells.lua)
  self.covers = CoverCells:new {
    window = Hosted.window(self),
    loader = function() return self.image_loader or require("hardcover/lib/ui/image_loader") end,
  }
  self:build()
end

-- How many rows fit a page over the footer.
function JournalBody:rowsPerPage(h)
  return math.max(1, math.floor((h - FOOTER_H) / ROW_H))
end

-- One entry: the cover, the title over what happened over the authors and the day, a chevron when
-- it opens something, and a dotted rule below.
function JournalBody:buildRow(entry, width, row_h)
  local row = Journal.row(entry, self.now and self.now() or nil)
  local inner_h = row_h - Theme.line.hair
  local line = HorizontalGroup:new { align = "center", Theme.hspan(SIDE),
    self.covers:cell(row.cover_url, COVER_W, COVER_H), Theme.hspan(SIDE) }

  local chevron = row.open and Draw.chevron("right") or nil
  local trailing_w = chevron and chevron:getSize().w or 0
  local text_w = math.max(px(60), width - SIDE - COVER_W - SIDE - SIDE - trailing_w - SIDE)
  local column = VerticalGroup:new { align = "left",
    Theme.mmdText(row.title, "strong", 21, { width = text_w }),
    Theme.span(px(3)),
    Theme.mmdText(row.what, "text", 18, { width = text_w }),
  }
  if row.detail ~= "" then
    table.insert(column, Theme.span(px(3)))
    table.insert(column, Theme.mmdText(row.detail, "text", 15, { width = text_w, secondary = true }))
  end
  table.insert(line, LeftContainer:new { dimen = Geom:new { w = text_w, h = inner_h }, column })
  table.insert(line, Theme.hspan(SIDE))
  if chevron then table.insert(line, chevron) end
  table.insert(line, Theme.hspan(SIDE))

  local body = CenterContainer:new { dimen = Geom:new { w = width, h = inner_h }, line }
  local tap = row.open and TapRow:new {
    callback = function() if self.select_cb then self.select_cb(entry) end end,
    body,
  } or body
  return VerticalGroup:new { align = "left", tap, Theme.dottedRule(width) }
end

-- The block that asks for the next page, in a row's place.
function JournalBody:buildMore(width, row_h)
  self.more_button = Button.new {
    label = self.loading and _("Loading\226\128\166") or _("Load more"),
    w = width - 2 * SIDE, h = Theme.TOUCH_MIN, size = 19,
    callback = function() self:loadMore() end,
  }
  return VerticalGroup:new { align = "left",
    CenterContainer:new { dimen = Geom:new { w = width, h = row_h - Theme.line.hair }, self.more_button },
    Theme.dottedRule(width),
  }
end

function JournalBody:build()
  local w, h = Hosted.size(self)
  self.more_button = nil
  self.control = nil
  self.covers:begin()
  local body
  if self.message then
    self.pages = 1
    local face, bold = Theme.mmdFace("text", 18)
    body = CenterContainer:new { dimen = Geom:new { w = w, h = h },
      TextBoxWidget:new { text = self.message, face = face, bold = bold, width = w - 4 * Theme.margin,
        alignment = "center", fgcolor = Theme.secondary() } }
  else
    local count = #self.entries
    local items = count + ((self.has_more and self.more_cb) and 1 or 0)
    self.per_page = self:rowsPerPage(h)
    self.pages = math.max(1, math.ceil(items / self.per_page))
    -- a list of several pages shares out what is left over (too short for another row) among its
    -- rows, so no gap sits above the footer; every row on every page gets the same height
    local row_h = ROW_H
    if self.pages > 1 then
      row_h = row_h + math.floor((h - FOOTER_H - self.per_page * row_h) / self.per_page)
    end
    self.page = math.max(1, math.min(self.page or 1, self.pages))
    local width = self.pages > 1 and (w - ScrollControl.gutter()) or w

    local list = VerticalGroup:new { align = "left" }
    local first = (self.page - 1) * self.per_page + 1
    local last = math.min(items, first + self.per_page - 1)
    for i = first, last do
      if i <= count then
        table.insert(list, self:buildRow(self.entries[i], width, row_h))
      else
        table.insert(list, self:buildMore(width, row_h))
      end
    end
    -- the footer sits at the same height on every page of a long list, and straight under the
    -- rows of a short one
    local shown_last = math.min(last, count)
    if first <= shown_last then
      local total = tostring(count) .. (self.has_more and "+" or "")
      local empty_rows = self.pages > 1 and (self.per_page - (last - first + 1)) * row_h or 0
      table.insert(list, Theme.span(empty_rows + px(8)))
      table.insert(list, HorizontalGroup:new { Theme.hspan(SIDE),
        Theme.mmdText(string.format(_("Showing %d to %d of %s"), first, shown_last, total), "text", 15,
          { secondary = true, width = width - 2 * SIDE }) })
    end

    body = list
    if self.pages > 1 then
      local control = ScrollControl.paged {
        height = h,
        pages = function() return self.pages end,
        page = function() return self.page end,
        go = function(page) self:setPage(page) end,
      }
      control.overlap_offset = { w - ScrollControl.gutter(), 0 }
      self.control = control
      body = OverlapGroup:new { dimen = Geom:new { w = w, h = h }, allow_mirroring = false, list, control }
    end
  end
  self.covers:finish()
  self[1] = FrameContainer:new { width = w, height = h, background = Theme.WHITE,
    bordersize = 0, padding = 0, margin = 0, body }
end

-- Build again from the current state, on the same page.
function JournalBody:rebuild()
  if self[1] and type(self[1].free) == "function" then pcall(function() self[1]:free() end) end
  self[1] = nil
  self:build()
  Hosted.dirty(self)
end

-- Show page `n` (clamped).
function JournalBody:setPage(n)
  local page = math.max(1, math.min(n, self.pages or 1))
  if page == self.page then return end
  self.page = page
  self:rebuild()
end

function JournalBody:onNextPage()
  self:setPage(self.page + 1)
  return true
end

function JournalBody:onPrevPage()
  self:setPage(self.page - 1)
  return true
end

function JournalBody:onSwipeJournal(_, ges)
  if self.message or not (ges and ges.direction) then return false end
  if ges.direction == "north" then
    self:setPage(self.page + 1)
    return true
  elseif ges.direction == "south" then
    self:setPage(self.page - 1)
    return true
  end
  return false
end

-- A single message in place of the rows.
function JournalBody:setMessage(message)
  self.message = message
  self.has_more = false
  self.loading = false
  self.more_from = nil
  self:rebuild()
end

-- Show these entries (the first page, or the first page followed by later ones). The answer to
-- Load more goes on to the page of the first new row; anything else stays on the page shown.
function JournalBody:setEntries(entries, has_more)
  local jump = self.loading and self.more_from
  self.message = nil
  self.entries = entries or {}
  self.has_more = has_more == true
  self.loading = false
  self.more_from = nil
  if #self.entries == 0 and not self.has_more then
    self:setMessage(_("Nothing in your journal yet. What you do with your books on Hardcover (progress, ratings, notes, quotes and reviews) appears here."))
    return
  end
  if jump and jump <= #self.entries and self.per_page then
    self.page = math.floor((jump - 1) / self.per_page) + 1
  end
  self:rebuild()
end

-- The next page was asked for (or failed): the block says so.
function JournalBody:setLoading(loading)
  self.loading = loading == true
  if not self.loading then self.more_from = nil end
  self:rebuild()
end

-- Guarded so a double tap cannot fire two requests.
function JournalBody:loadMore()
  if self.loading or not self.has_more or not self.more_cb then return end
  self.more_from = #self.entries + 1
  self:setLoading(true)
  self.more_cb()
end

function JournalBody:onCloseWidget()
  self.covers:release()
end

return JournalBody
