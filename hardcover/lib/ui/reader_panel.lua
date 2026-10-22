-- The open book's reader panel: cached cover, status, rating and progress above
-- five fixed book actions. Options and Close have separate touch targets at the
-- top right. Contextual actions sit in dotted cards with solid enabled buttons.
-- The model is rebuilt from saved state and pending writes on every render.
--
-- model(): { title, linked, cover_path?, status?, rating?, line?, progress?,
--   message?, shelf_action? = { text, enabled?, run }, menu? = { rows },
--   actions = { { text, icon?, enabled?, run }, ... } }
-- A tap above the sheet, Close, or Back dismisses it.

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

-- A contextual card is dotted; the action inside it remains a solid outlined button.
function ReaderPanel:buildShelfRow(text, action, width)
  local pad = Theme.space.m
  local inner = width - 2 * pad
  local button_w = math.min(Theme.px(142), math.floor(inner * 0.42))
  local label_w = inner - button_w - Theme.space.m
  local label = require("ui/widget/textboxwidget"):new {
    text = text, face = Theme.mmdFace("text", 20), width = label_w,
  }
  local button = Button.new { label = action.text, w = button_w, h = Theme.TOUCH_MIN,
    enabled = action.enabled ~= false, callback = action.enabled ~= false and action.run or nil }
  local row = HorizontalGroup:new { align = "center", label, Theme.hspan(Theme.space.m), button }
  return Theme.box(width, math.max(Theme.px(82), row:getSize().h + 2 * pad), row,
    { radius = 12, dotted = true })
end

function ReaderPanel:buildClose()
  local size = Theme.TOUCH_MIN
  self.close_button = TapRow:new { callback = function() self:onClose() end,
    dimen = Geom:new { w = size, h = size },
    CenterContainer:new { dimen = Geom:new { w = size, h = size }, Theme.icon("close", Theme.px(24)) } }
  return self.close_button
end

-- the settings gear: an icon in a TOUCH_MIN square that opens the panel's menu as a list sheet
function ReaderPanel:buildGear(menu)
  local size = Theme.TOUCH_MIN
  self.gear = TapRow:new { callback = function() self:openMenu(menu) end,
    dimen = Geom:new { w = size, h = size },
    CenterContainer:new { dimen = Geom:new { w = size, h = size }, Theme.icon("settings", Theme.px(28)) } }
  return self.gear
end

-- the gear's menu: a small popup under the gear (its right edge on the gear's), not a sheet
function ReaderPanel:openMenu(menu)
  local Popover = require("hardcover/lib/ui/components/popover")
  local screen_w = Screen:getWidth()
  local at = self.gear and self.gear.dimen
  local items = {}
  for _i, item in ipairs(menu.rows) do
    items[#items + 1] = { label = item.text, disabled = item.enabled == false, callback = item.run }
  end
  -- (before the gear has been painted it has no place yet: the top right of the sheet stands in)
  local x = at and at.x and (at.x + at.w) or (screen_w - Theme.px(20))
  local y = at and at.y and (at.y + at.h) or ((self.sheet_top or 0) + Theme.TOUCH_MIN)
  self.menu_popup = Popover.show { items = items, x = x, y = y,
    width = Popover.fitWidth(items, screen_w - Theme.px(16)),
    on_dismiss = function() self.menu_popup = nil end }
  return self.menu_popup
end

function ReaderPanel:render()
  local model = self.opts.model()
  local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
  local M = Theme.px(20)
  local width = screen_w - 2 * M

  local content = VerticalGroup:new { align = "left" }
  table.insert(content, Theme.span("m"))

  -- Cover, title and two separate touch targets. The title yields space to both controls.
  local cw, ch = Theme.px(56), Theme.px(84)
  local gap = Theme.space.m
  local text_w = width - cw - gap
  local gear = model.menu and self:buildGear(model.menu)
  local close = self:buildClose()
  local controls = (gear and gear:getSize().w + Theme.space.xs or 0) + close:getSize().w
  local title_w = math.max(1, text_w - controls)
  local title = Theme.mmdText(model.title, "strong", 25, { width = title_w })
  local head = HorizontalGroup:new { align = "center", title,
    Theme.hspan(math.max(0, title_w - title:getSize().w)) }
  if gear then table.insert(head, gear); table.insert(head, Theme.hspan("xs")) end
  table.insert(head, close)
  local book = VerticalGroup:new { align = "left", head }
  if model.linked then
    local rating = tonumber(model.rating)
    local stars = rating and rating > 0 and HorizontalGroup:new { align = "center",
      Theme.icon("star-filled", Theme.px(22)), Theme.hspan("xs"),
      Theme.mmdText(tostring(rating), "strong", 20) }
      or Theme.mmdText(_("Not rated"), "text", 18, { secondary = true })
    local status = Theme.mmdText(model.status or _("Shelf not checked yet"), "strong", 19,
      { width = math.max(1, text_w - stars:getSize().w - gap) })
    table.insert(book, Theme.span("xs"))
    table.insert(book, HorizontalGroup:new { align = "center", status,
      Theme.hspan(math.max(0, text_w - status:getSize().w - stars:getSize().w)), stars })
  end
  if model.line then
    table.insert(book, Theme.span("xs"))
    table.insert(book, Theme.mmdText(model.line, "text", 18, { secondary = true, width = text_w }))
  end
  if model.progress ~= nil then
    table.insert(book, Theme.span("xs"))
    table.insert(book, Theme.progress { width = text_w, height = Theme.px(12), percentage = model.progress })
  end
  local cover
  if model.cover_path then
    local ok, image = pcall(function()
      return require("ui/widget/imagewidget"):new {
        file = model.cover_path, width = cw, height = ch, scale_factor = 0,
      }
    end)
    if ok then cover = image end
  end
  cover = cover or Theme.box(cw, ch, Theme.icon("book", Theme.px(28)), { radius = 0 })
  table.insert(content, HorizontalGroup:new { align = "top", cover, Theme.hspan(gap), book })
  if model.message and model.shelf_action then
    table.insert(content, Theme.span("m"))
    table.insert(content, self:buildShelfRow(model.message, model.shelf_action, width))
  end

  table.insert(content, Theme.span("l"))
  local round, wide = {}, {}
  for _, action in ipairs(model.actions) do
    table.insert(action.icon and round or wide, action)
  end
  if #round > 0 then
    local cell = math.floor(width / #round)
    local row = HorizontalGroup:new { align = "top" }
    for _, action in ipairs(round) do
      table.insert(row, CenterContainer:new {
        dimen = Geom:new { w = cell, h = Theme.mmd.round_button.size.large + Theme.px(36) },
        Button.round { icon = action.icon, label = action.text, scale = "large",
          enabled = action.enabled ~= false, callback = action.enabled ~= false and action.run or nil },
      })
    end
    table.insert(content, row)
  end
  for _, action in ipairs(wide) do
    table.insert(content, Button.new { label = action.text, w = width, h = Theme.px(56),
      enabled = action.enabled ~= false, callback = action.enabled ~= false and action.run or nil })
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
