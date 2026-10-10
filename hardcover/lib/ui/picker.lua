-- The plugin's choose-from-a-list sheet (the shelf mover, the lists to add a book to, the goal form's
-- choices, a conflict, a period): an MMD bottom sheet. The 3px rule on top, a Black 25 title with an X,
-- and one list row each (56 tall, dotted dividers). A row that says `current` shows a radio, one that
-- says `checked` a checkbox, any other is plain. A row with `primary` is the filled button under the
-- list (Done). A list too long for the sheet is shown a page at a time with the scroll control.
--
-- It is an Overlay, so UIManager:show(picker) and UIManager:close(picker) work as before.

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Button = require("hardcover/lib/ui/components/button")
local Checkbox = require("hardcover/lib/ui/components/checkbox")
local Draw = require("hardcover/lib/ui/components/draw")
local ListItem = require("hardcover/lib/ui/components/list_item")
local Overlay = require("hardcover/lib/ui/components/overlay")
local Radio = require("hardcover/lib/ui/components/radio")
local ScrollControl = require("hardcover/lib/ui/components/scroll_control")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local Picker = Overlay:extend { name = "hardcover_picker" }

-- opts: title, rows ({ text, callback, current, checked, bold, primary, id, disabled }), close_callback
-- (when it is dismissed by the X, a tap outside it or Back; a row's own callback closes it itself).
function Picker.new(opts)
  local self = Overlay.new(Picker, { anchor = "bottom", on_dismiss = opts.close_callback, [1] = VerticalGroup:new {} })
  self.title, self.rows, self.page = opts.title, opts.rows or {}, 1
  self:rebuild()
  return self
end

function Picker:build()
  local sw, sh = Device.screen:getWidth(), Device.screen:getHeight()
  local row_h = Theme.px(56)
  local side = Theme.px(12)
  local inner_w = sw - 2 * side
  local plain, primary = {}, nil
  for _i, row in ipairs(self.rows) do
    if row.primary then primary = row else plain[#plain + 1] = row end
  end

  local close = TapRow:new {
    callback = function() self:dismiss() end,
    Draw.drawn(Theme.TOUCH_MIN, Theme.TOUCH_MIN, function(bb, x, y)
      local o = math.floor((Theme.TOUCH_MIN - Theme.px(28)) / 2)
      Draw.ICONS.close(bb, x + o, y + o, Theme.px(28), Theme.px(2.5))
    end),
  }
  local face, bold = Theme.mmdFace("strong", 25)
  local title = TextBoxWidget:new { text = self.title or "", face = face, bold = bold,
    width = inner_w - Theme.TOUCH_MIN - Theme.px(4), fgcolor = Theme.BLACK }
  local head = VerticalGroup:new { align = "left", Overlay.top_rule(sw), Theme.span(Theme.px(24)),
    HorizontalGroup:new { align = "top", Theme.hspan(side + Theme.px(4)), title,
      Theme.hspan(inner_w - Theme.px(4) - title:getSize().w - Theme.TOUCH_MIN), close },
    Theme.span(Theme.px(8)) }
  local foot = VerticalGroup:new { align = "left" }
  if primary then
    foot[#foot + 1] = Theme.span(Theme.px(12))
    foot[#foot + 1] = HorizontalGroup:new { Theme.hspan(side), Button.new {
      label = primary.text, w = inner_w, primary = true, callback = primary.callback } }
  end
  foot[#foot + 1] = Theme.span(Theme.px(18))

  -- how many rows fit: about two thirds of the screen for the whole sheet
  local room = math.floor(sh * 0.7) - head:getSize().h - foot:getSize().h
  local per_page = math.max(3, math.floor(room / row_h))
  local paged = #plain > per_page
  self.pages = paged and math.ceil(#plain / per_page) or 1
  self.page = math.max(1, math.min(self.page, self.pages))
  local first = paged and (self.page - 1) * per_page + 1 or 1
  local last = paged and math.min(#plain, first + per_page - 1) or #plain

  local list_w = inner_w - (paged and ScrollControl.gutter() or 0)
  local list = VerticalGroup:new { align = "left" }
  for i = first, last do
    local row = plain[i]
    local trailing
    if row.checked ~= nil then
      trailing = Checkbox.new { checked = row.checked }
    elseif row.current ~= nil then
      trailing = Radio.new { selected = row.current }
    end
    list[#list + 1] = ListItem.new {
      width = list_w, label = row.text, strong = row.bold or row.current or false, h = row_h,
      trailing = trailing, dim = row.disabled, divider = (i < last) and "dotted" or nil,
      callback = (not row.disabled) and row.callback or nil,
    }
  end
  local body = HorizontalGroup:new { align = "top", Theme.hspan(side), list }
  if paged then
    body[#body + 1] = ScrollControl.paged {
      height = per_page * row_h,
      pages = function() return self.pages end,
      page = function() return self.page end,
      go = function(page)
        if page < 1 or page > self.pages then return end
        self.page = page
        self:rebuild()
      end,
    }
  end
  return FrameContainer:new { width = sw, bordersize = 0, padding = 0, margin = 0, background = Theme.WHITE,
    VerticalGroup:new { align = "left", head, body, foot } }
end

-- Draw the sheet again from `rows` (a row changed, or the page did).
function Picker:rebuild()
  local old = self.region
  self[1] = self:build()
  local sw, sh = Device.screen:getWidth(), Device.screen:getHeight()
  local size = self[1]:getSize()
  self.region = Geom:new { x = 0, y = sh - size.h, w = size.w, h = size.h }
  self.dimen = Geom:new { x = 0, y = 0, w = sw, h = sh }
  if old then
    UIManager:setDirty(self, "ui", old:combine(self.region))
  end
end

--
-- Change one row of a shown picker in place (its words, whether it can be tapped, whether it is
-- ticked), without closing it: a choice that is being saved shows it and cannot be tapped again
-- until the answer is in.
--
function Picker.setRow(picker, id, text, enabled, checked)
  if not picker or not picker.rows then return end
  for _i, row in ipairs(picker.rows) do
    if row.id == id then
      row.text = text
      row.disabled = enabled == false
      if checked ~= nil then row.checked = checked end
      picker:rebuild()
      return
    end
  end
end

return Picker
