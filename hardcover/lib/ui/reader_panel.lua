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
--   { title, linked (bool), pills = { { text, filled }, ... }, line (string or nil),
--     track = { checked, toggle } or nil,
--     actions = { { text, enabled, primary, run }, ... } }
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

-- the tick box of the "track progress" row
local function tickBox(checked)
  local size = Screen:scaleBySize(26)
  local mark = checked and TextWidget:new { text = CHECK, face = Theme.face("body"), bold = true, fgcolor = Theme.BLACK }
    or Theme.hspan(1)
  return Theme.box(size, size, mark, { radius = 4 })
end

function ReaderPanel:buildTrackRow(track, width)
  local h = Theme.TOUCH_MIN + Theme.space.s
  local inner = width - 2 * Theme.line.firm
  local label = TextWidget:new {
    text = _("Update Hardcover as I read"),
    face = Theme.face("body"),
    bold = true,
    max_width = inner - tickBox(true):getSize().w - 3 * Theme.space.m,
    fgcolor = Theme.BLACK,
  }
  local box = Theme.box(width, h, HorizontalGroup:new {
    align = "center",
    label,
    Theme.hspan(math.max(0, inner - label:getSize().w - tickBox(true):getSize().w - 2 * Theme.space.m)),
    tickBox(track.checked),
  }, { radius = 8 })
  return TapRow:new { callback = function() track.toggle(); self:render() end, box }
end

function ReaderPanel:render()
  local model = self.opts.model()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local M = Theme.margin
  local width = screen_w - 2 * M

  local content = VerticalGroup:new { align = "left" }
  table.insert(content, Theme.span("m"))

  -- the book
  table.insert(content, TextWidget:new {
    text = model.title,
    face = Theme.face("display"),
    bold = true,
    max_width = width,
    fgcolor = Theme.BLACK,
  })

  if #model.pills > 0 then
    table.insert(content, Theme.span("s"))
    local row = HorizontalGroup:new { align = "center" }
    for i, pill in ipairs(model.pills) do
      if i > 1 then table.insert(row, Theme.hspan("s")) end
      table.insert(row, Theme.pill(pill.text, { filled = pill.filled, max_width = width }))
    end
    table.insert(content, row)
  end

  if model.line then
    table.insert(content, Theme.span("s"))
    table.insert(content, TextWidget:new {
      text = model.line,
      face = Theme.face("body"),
      max_width = width,
      fgcolor = Theme.DARK_GREY,
    })
  end

  if model.track then
    table.insert(content, Theme.span("m"))
    table.insert(content, self:buildTrackRow(model.track, width))
  end

  -- the actions, two to a row
  table.insert(content, Theme.span("m"))
  table.insert(content, Theme.rule(width, true))
  table.insert(content, Theme.span("m"))
  local gap = Theme.space.m
  local half = math.floor((width - gap) / 2)
  local i = 1
  while i <= #model.actions do
    local a, b = model.actions[i], model.actions[i + 1]
    local function button(action, w)
      return Theme.button(action.text, w, {
        filled = action.primary,
        enabled = action.enabled ~= false,
        callback = action.run,
        size = "body",
      })
    end
    if a.wide or not b or b.wide then
      table.insert(content, button(a, a.wide and width or half))
      i = i + 1
    else
      table.insert(content, HorizontalGroup:new { button(a, half), Theme.hspan(gap), button(b, half) })
      i = i + 2
    end
    table.insert(content, Theme.span("s"))
  end
  table.insert(content, Theme.span("m"))

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
  self.sheet_top = screen_h - sheet:getSize().h
  self.sheet_rect = { x = 0, y = self.sheet_top, w = screen_w, h = sheet:getSize().h }
  -- only the sheet is drawn over the page, so only the sheet's rows of the panel
  -- need redrawing (and, when it changes height, where it used to be): not the
  -- whole book page behind it
  UIManager:setDirty(self, "ui", self:rect(Refresh.union(old, self.sheet_rect)))
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
  -- the page under the sheet is already in the framebuffer (close() repaints it);
  -- the panel only needs to redraw where the sheet was
  UIManager:setDirty(nil, "ui", self.sheet_rect and self:rect(self.sheet_rect) or nil)
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
