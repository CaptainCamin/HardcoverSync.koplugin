-- The panel for the book that is open: a sheet that rises from the bottom of the
-- reading screen, so the page stays visible above it.
--
-- It shows where the book stands (title, status, page, rating, whether progress
-- is tracked) and the few things a reader does mid-book as big buttons: set the
-- page, change the status, rate, note, details, reviews. Everything is asked of
-- `opts.model()` on every draw, so after an action the panel shows what is true
-- now instead of what was true when it opened.
--
-- model() returns:
--   { title, on_title (function) or nil   -- tapping the title opens the book's details; it
--       carries a chevron when set,
--     linked (bool), info (plain text, e.g. "Not linked to Hardcover") or nil,
--     status = { text, run, enabled } or nil   -- a pill you tap to change the status
--     track = { checked, toggle } or nil       -- a pill: tracking on/off
--     progress = { fraction, line, run, enabled } or nil   -- the bar and the line under
--                it; tapping them runs `run` (set the page)
--     blurb (string) or nil,
--     actions = { { text, enabled, primary, wide, icon, narrow, run }, ... } }
--
-- Only things you can tap have a border: the status and tracking pills, the progress
-- (it sets the page), and the buttons. An action with an `icon` is a tile (icon and
-- label in one pill, a run of them sharing a row; `narrow` is icon only); the rest
-- are pill buttons.
--
-- Tapping above the sheet, or the Back key, closes it.

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Refresh = require("hardcover/lib/ui/refresh")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

local CHECK = "\226\156\147" -- check mark

local ReaderPanel = InputContainer:extend {
  name = "hardcover_reader_panel",
  opts = nil,
}

function ReaderPanel:init()
  self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
  self.key_events.ClosePanel = { { "Back" } }
  self.ges_events = {
    TapOutside = { GestureRange:new { ges = "tap", range = self.dimen } },
  }
  self:render()
end

-- an icon beside its label (or alone when `narrow`), in a pill w wide
function ReaderPanel:buildTile(action, w)
  local enabled = action.enabled ~= false
  local icon = Theme.icon(action.icon, Theme.px(26))
  local face_inner = w - 2 * Theme.line.firm - Theme.space.s - icon:getSize().w - Theme.space.xs
  local content = action.narrow and icon or HorizontalGroup:new {
    align = "center",
    icon,
    Theme.hspan("xs"),
    Theme.text(action.text, "small", { bold = true, grey = not enabled, width = face_inner }),
  }
  local box = Theme.box(w, Theme.px(56), content, { round = true })
  return TapRow:new { callback = enabled and action.run or nil, feedback = true, box }
end

function ReaderPanel:render()
  local model = self.opts.model()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local M = Theme.margin
  local width = screen_w - 2 * M

  local content = VerticalGroup:new { align = "left" }
  table.insert(content, Theme.span("s"))

  -- the book
  local title_face, title_bold = Theme.serif("display")
  if model.on_title then
    -- a heading you can tap: the chevron right after it is the only cue, so it must always
    -- fit (a long title is cut short instead)
    local chevron = Theme.chevron(Theme.px(30))
    local title = TextWidget:new {
      text = model.title,
      face = title_face,
      bold = title_bold,
      max_width = width - chevron:getSize().w - Theme.space.s,
      fgcolor = Theme.BLACK,
    }
    local line = HorizontalGroup:new { align = "center", title, Theme.hspan("s"), chevron }
    table.insert(content, Theme.touchable(line, line:getSize().w, model.on_title))
  else
    table.insert(content, TextWidget:new {
      text = model.title,
      face = title_face,
      bold = title_bold,
      max_width = width,
      fgcolor = Theme.BLACK,
    })
  end

  -- the status pill at the left and the tracking pill at the right, so the row spans
  -- the page like the buttons below it. Both are tappable, so both have a border.
  table.insert(content, Theme.span("m"))
  local left, right
  if model.info then
    left = Theme.label(model.info, { grey = true, size = "body" })
  elseif model.status then
    local st = model.status
    left = Theme.tapPill(st.text, { chevron = true, max_width = width / 2 }, st.enabled ~= false and st.run or nil)
  end
  if model.track then
    local tr = model.track
    right = Theme.tapPill(tr.checked and _("Tracking on") or _("Tracking off"), { filled = tr.checked, max_width = width / 2 },
      function() tr.toggle(); self:render() end)
  end
  local chips = HorizontalGroup:new { align = "center" }
  if left then table.insert(chips, left) end
  if right then
    local used = (left and left:getSize().w or 0) + right:getSize().w
    table.insert(chips, Theme.hspan(math.max(Theme.space.s, width - used)))
    table.insert(chips, right)
  end
  table.insert(content, chips)

  -- where you are in the book: the bar and its line are one tap target (set the page)
  if model.progress then
    local pr = model.progress
    table.insert(content, Theme.span("m"))
    local block = VerticalGroup:new {
      align = "left",
      Theme.progress { width = width, height = Theme.px(14), percentage = pr.fraction },
      Theme.span("m"),
      -- a chevron at the end says the line opens something (the page picker)
      pr.enabled ~= false and HorizontalGroup:new {
        align = "center",
        Theme.text(pr.line, "body", { width = width - Theme.px(24) - Theme.space.s }),
        Theme.hspan(Theme.space.s),
        Theme.chevron(),
      } or Theme.text(pr.line, "body", { width = width }),
    }
    table.insert(content, TapRow:new { callback = pr.enabled ~= false and pr.run or nil, feedback = true, block })
  end

  if model.blurb then
    table.insert(content, Theme.span("m"))
    table.insert(content, TextWidget:new {
      text = model.blurb, face = Theme.face("body"), max_width = width, fgcolor = Theme.DARK_GREY,
    })
  end

  -- the actions: tiles share a row, the rest are pill buttons up to three to a row
  table.insert(content, Theme.span("l"))
  local gap = Theme.space.m
  local function button(action, w)
    return Theme.button(action.text, w, {
      filled = action.primary,
      enabled = action.enabled ~= false,
      callback = action.run,
      size = "small",
      h = Theme.px(50),
    })
  end
  local i = 1
  while i <= #model.actions do
    local a, b = model.actions[i], model.actions[i + 1]
    if a.icon then
      local tiles = {}
      while model.actions[i] and model.actions[i].icon do
        tiles[#tiles + 1] = model.actions[i]
        i = i + 1
      end
      local narrow_w = Theme.px(72)
      local wide_n, used = 0, 0
      for _, t in ipairs(tiles) do
        if t.narrow then used = used + narrow_w else wide_n = wide_n + 1 end
      end
      local tw = math.floor((width - (#tiles - 1) * gap - used) / math.max(1, wide_n))
      local row = HorizontalGroup:new {}
      for n, t in ipairs(tiles) do
        if n > 1 then table.insert(row, Theme.hspan(gap)) end
        table.insert(row, self:buildTile(t, t.narrow and narrow_w or tw))
      end
      table.insert(content, row)
    elseif a.wide then
      table.insert(content, button(a, width))
      i = i + 1
    else
      local group = {}
      while model.actions[i] and not model.actions[i].icon and not model.actions[i].wide and #group < 3 do
        group[#group + 1] = model.actions[i]
        i = i + 1
      end
      local bw = math.floor((width - (#group - 1) * gap) / #group)
      local row = HorizontalGroup:new {}
      for n, act in ipairs(group) do
        if n > 1 then table.insert(row, Theme.hspan(gap)) end
        table.insert(row, button(act, bw))
      end
      table.insert(content, row)
    end
    table.insert(content, Theme.span("s"))
  end
  table.insert(content, Theme.span("s"))

  local sheet = FrameContainer:new {
    background = Blitbuffer.COLOR_WHITE,
    bordersize = 0,
    padding = 0,
    margin = 0,
    -- a firm rule across the top edge; the sides and bottom are the screen's
    VerticalGroup:new {
      align = "left",
      Theme.rule(screen_w, true),
      HorizontalGroup:new { Theme.hspan(M), content },
    },
  }
  self.sheet = sheet
  self[1] = BottomContainer:new {
    dimen = Geom:new { x = 0, y = 0, w = screen_w, h = screen_h },
    sheet,
  }
  local old = self.sheet_rect
  local old_top = self.sheet_top
  self.sheet_top = screen_h - sheet:getSize().h
  -- the page behind the sheet is hatched, once: all of it when the panel opens, and
  -- the strip the sheet uncovers when it gets shorter
  if not old_top then
    self.scrim = { x = 0, y = 0, w = screen_w, h = self.sheet_top }
  elseif self.sheet_top > old_top then
    self.scrim = { x = 0, y = old_top, w = screen_w, h = self.sheet_top - old_top }
  end
  self.sheet_rect = { x = 0, y = self.sheet_top, w = screen_w, h = sheet:getSize().h }
  -- only the sheet is drawn over the page, so only the sheet's rows of the panel
  -- need redrawing (and, when it changes height, where it used to be): not the
  -- whole book page behind it
  local dirty = Refresh.union(old, self.sheet_rect)
  if self.scrim then dirty = Refresh.union(dirty, self.scrim) end
  UIManager:setDirty(self, "ui", self:rect(dirty))
end

-- the sheet, then the hatching over the page it leaves visible (see render)
function ReaderPanel:paintTo(bb, x, y)
  InputContainer.paintTo(self, bb, x, y)
  local s = self.scrim
  if s then
    Theme.hatchRect(bb, x + s.x, y + s.y, s.w, s.h)
    self.scrim = nil
  end
end

-- a Geom for a {x, y, w, h}
function ReaderPanel:rect(r)
  return Geom:new { x = r.x, y = r.y, w = r.w, h = r.h }
end

function ReaderPanel:onTapOutside(_, ges)
  if ges and ges.pos and ges.pos.y < (self.sheet_top or 0) then
    return self:onClose()
  end
  return false
end

-- leaving the panel must repaint the page under it
function ReaderPanel:onCloseWidget()
  -- the page under was hatched, so all of it needs repainting without the hatching
  UIManager:setDirty(nil, "ui", self.dimen)
end

function ReaderPanel:onClosePanel()
  return self:onClose()
end

function ReaderPanel:onClose()
  UIManager:close(self)
  if self.opts.on_close then self.opts.on_close() end
  return true
end

local Dialog = {}

function Dialog.show(opts)
  local panel = ReaderPanel:new { opts = opts }
  UIManager:show(panel)
  return panel
end

return Dialog
