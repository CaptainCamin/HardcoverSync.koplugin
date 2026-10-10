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
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Button = require("hardcover/lib/ui/components/button")
local Overlay = require("hardcover/lib/ui/components/overlay")
local Refresh = require("hardcover/lib/ui/refresh")
local Switch = require("hardcover/lib/ui/components/switch")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Screen = Device.screen

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

-- the "update Hardcover as I read" row: a label and a real switch, the whole row the touch area
function ReaderPanel:buildTrackRow(track, width)
  local sw = Switch.new { on = track.checked }
  local label = Theme.mmdText(_("Update Hardcover as I read"), "strong", 21,
    { width = width - sw:getSize().w - Theme.px(16) })
  local h = math.max(Theme.TOUCH_MIN, label:getSize().h + Theme.px(16))
  local row = HorizontalGroup:new { align = "center", label,
    Theme.hspan(width - label:getSize().w - sw:getSize().w), sw }
  return TapRow:new { callback = function() track.toggle(); self:render() end,
    dimen = Geom:new { w = width, h = h }, CenterContainer:new { dimen = Geom:new { w = width, h = h }, row } }
end

function ReaderPanel:render()
  local model = self.opts.model()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local M = Theme.px(20)
  local width = screen_w - 2 * M

  local content = VerticalGroup:new { align = "left" }
  table.insert(content, Theme.span(Theme.px(14)))

  -- the book; wide and short, the title and the status share a line so the page stays in view
  local landscape = screen_w > screen_h
  local pill_row
  if #model.pills > 0 then
    pill_row = HorizontalGroup:new { align = "center" }
    for i, pill in ipairs(model.pills) do
      if i > 1 then table.insert(pill_row, Theme.hspan("s")) end
      table.insert(pill_row, Theme.pill(pill.text, { filled = pill.filled, max_width = width }))
    end
  end
  local title = Theme.mmdText(model.title, "strong", 25, { width = width })
  if landscape and pill_row then
    table.insert(content, HorizontalGroup:new { align = "center", title, Theme.hspan(Theme.px(20)), pill_row })
  else
    table.insert(content, title)
    if pill_row then
      table.insert(content, Theme.span("s"))
      table.insert(content, pill_row)
    end
  end

  if model.line then
    table.insert(content, Theme.span(Theme.px(6)))
    table.insert(content, Theme.mmdText(model.line, "text", 18, { secondary = true, width = width }))
  end

  if model.track then
    table.insert(content, Theme.span(Theme.px(8)))
    table.insert(content, self:buildTrackRow(model.track, width))
  end

  -- the actions, two to a row; an action that cannot be used right now keeps its place, in
  -- secondary text and without a tap
  table.insert(content, Theme.span(Theme.px(14)))
  -- two to a row and compact, so most of the page stays in view
  local gap = Theme.px(12)
  local cols = 2
  local cell = math.floor((width - (cols - 1) * gap) / cols)
  local bh = Theme.px(52)
  local function button(action, w)
    local enabled = action.enabled ~= false
    return Button.new { label = action.text, w = w, h = bh, primary = action.primary and enabled,
      enabled = enabled, callback = enabled and action.run or nil }
  end
  local i = 1
  while i <= #model.actions do
    local a = model.actions[i]
    if a.wide then
      table.insert(content, button(a, width))
      i = i + 1
    else
      local row = HorizontalGroup:new {}
      local n = 0
      while n < cols and model.actions[i] and not model.actions[i].wide do
        if n > 0 then table.insert(row, Theme.hspan(gap)) end
        table.insert(row, button(model.actions[i], cell))
        i, n = i + 1, n + 1
      end
      table.insert(content, row)
    end
    table.insert(content, Theme.span(Theme.px(12)))
  end
  table.insert(content, Button.new { label = _("Cancel"), w = width, h = bh, primary = true,
    callback = function() self:onClose() end })
  table.insert(content, Theme.span(Theme.px(20)))

  local sheet = FrameContainer:new {
    background = Blitbuffer.COLOR_WHITE,
    bordersize = 0,
    padding = 0,
    margin = 0,
    -- a firm rule across the top edge; the sides and bottom are the screen's
    VerticalGroup:new {
      align = "left",
      Overlay.top_rule(screen_w),
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
