-- Input dialog (MMD Dialog with a field): a heading, an optional line of text, a field and one or
-- two stacked buttons, the filled one first. KOReader's InputText does the typing and its virtual
-- keyboard comes up under the dialog, which sits on top of it. The frame, heading and buttons are the
-- plugin's own, as Dialog's, but wider, and with the buttons side by side (filled on the right): the
-- keyboard leaves little height, and stacked buttons would push the box up under the top bar.
--
--   local input
--   input = InputDialog:new {
--     title = "Search books", text = "optional line", input = "start text", hint = "Title or author",
--     input_type = "number" (or nil), allow_newline = false,
--     buttons = { { label = "Cancel", callback = function() UIManager:close(input) end },
--                 { label = "Search", primary = true, callback = function() ... end } },
--   }
--   UIManager:show(input)
--   input:onShowKeyboard()
--
-- A button does not close the dialog; its callback does, when it is done (a search that failed
-- keeps the box). Enter runs the filled button. Back hides the keyboard, then cancels (the outlined
-- button's callback), and so does a tap outside once the keyboard is down. `getInputText` and
-- `setInputText` are the same as on KOReader's.

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText = require("ui/widget/inputtext")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Button = require("hardcover/lib/ui/components/button")
local Overlay = require("hardcover/lib/ui/components/overlay")
local Theme = require("hardcover/lib/ui/theme")

local InputDialog = InputContainer:extend {
  name = "hardcover_input_dialog",
  is_always_active = true, -- gets taps while the keyboard is the top window
  modal = true,
  title = "",
  text = nil,
  input = "",
  hint = nil,
  input_type = nil,
  allow_newline = false,
  buttons = nil, -- { { label, callback, primary } }, one or two
}

function InputDialog:init()
  local screen = Device.screen
  local side = Theme.px(12)
  local w = math.min(screen:getWidth() - 2 * Theme.margin, Theme.px(560))
  local inner_w = w - 2 * side
  assert(self.buttons and #self.buttons >= 1 and #self.buttons <= 2, "an input dialog has one or two buttons")
  self.ordered = {}
  for _, spec in ipairs(self.buttons) do if spec.primary then self.ordered[#self.ordered + 1] = spec end end
  for _, spec in ipairs(self.buttons) do if not spec.primary then self.ordered[#self.ordered + 1] = spec end end

  local face, bold = Theme.mmdFace("text", 21)
  local field_w = inner_w - 2 * (Size.border.inputtext + Size.padding.default)
  self._input_widget = InputText:new {
    text = self.input or "",
    hint = self.hint,
    face = face,
    width = field_w,
    padding = Size.padding.default,
    margin = 0,
    input_type = self.input_type,
    enter_callback = (not self.allow_newline) and function() self:onEnter() end or nil,
    scroll = false,
    parent = self,
  }
  -- the field sits at the left edge of the column, the buttons are as wide as the column
  local tface, tbold = Theme.mmdFace("strong", 25)
  local col = VerticalGroup:new { align = "left", Overlay.top_rule(w), Theme.span(Theme.px(12)) }
  local function indented(widget)
    col[#col + 1] = HorizontalGroup:new { Theme.hspan(side), widget }
  end
  indented(TextBoxWidget:new { text = self.title, face = tface, bold = tbold, width = inner_w, fgcolor = Theme.BLACK })
  if self.text then
    col[#col + 1] = Theme.span(Theme.px(10))
    indented(TextBoxWidget:new { text = self.text, face = face, bold = bold, width = inner_w, fgcolor = Theme.BLACK })
  end
  col[#col + 1] = Theme.span(Theme.px(12))
  indented(self._input_widget)
  col[#col + 1] = Theme.span(Theme.px(24))
  -- one button the full width; two side by side, the filled one on the right
  local gap = Theme.px(12)
  local bw = #self.ordered == 1 and inner_w or math.floor((inner_w - gap) / 2)
  local row = HorizontalGroup:new {}
  for i = #self.ordered, 1, -1 do
    local spec = self.ordered[i]
    if #row > 0 then row[#row + 1] = Theme.hspan(gap) end
    row[#row + 1] = Button.new { label = spec.label, w = bw, primary = spec.primary,
      callback = function() if spec.callback then spec.callback() end end }
  end
  indented(row)
  col[#col + 1] = Theme.span(Theme.px(12))

  -- no outline of its own: the top rule is the edge
  self.frame = FrameContainer:new { width = w, bordersize = 0, padding = 0, margin = 0,
    background = Theme.WHITE, col }
  self:_place()
  if Device:isTouchDevice() then
    self.ges_events = { Tap = { GestureRange:new { ges = "tap",
      range = Geom:new { x = 0, y = 0, w = screen:getWidth(), h = screen:getHeight() } } } }
  end
  if Device:hasKeys() then
    self.key_events = { Back = { { Device.input.group.Back } } }
  end
end

-- the frame at the bottom of what the keyboard leaves, so it is as far from the top bar as it can be
function InputDialog:_place()
  local screen = Device.screen
  local kb = self._input_widget:getKeyboardDimen()
  self.keyboard_visible = self._input_widget:isKeyboardVisible()
  self[1] = BottomContainer:new {
    dimen = Geom:new { x = 0, y = 0, w = screen:getWidth(), h = screen:getHeight() - (kb and kb.h or 0) },
    self.frame,
  }
end

function InputDialog:getInputText() return self._input_widget:getText() end
function InputDialog:setInputText(text) self._input_widget:setText(text) end

function InputDialog:onShowKeyboard(ignore_first_hold_release)
  self._input_widget:onShowKeyboard(ignore_first_hold_release)
  self.keyboard_visible = self._input_widget:isKeyboardVisible()
end

function InputDialog:onCloseKeyboard()
  self._input_widget:onCloseKeyboard()
  self.keyboard_visible = self._input_widget:isKeyboardVisible()
end

function InputDialog:isKeyboardVisible() return self._input_widget:isKeyboardVisible() end

-- Enter: the filled button
function InputDialog:onEnter()
  for _, spec in ipairs(self.ordered) do
    if spec.primary then
      if spec.callback then spec.callback() end
      return
    end
  end
end

-- Back and a tap outside: the outlined button's callback, or just close
function InputDialog:cancel()
  for _, spec in ipairs(self.ordered) do
    if not spec.primary then
      if spec.callback then spec.callback() end
      return
    end
  end
  UIManager:close(self)
end

function InputDialog:onBack()
  if self:isKeyboardVisible() then
    self:onCloseKeyboard()
  else
    self:cancel()
  end
  return true
end

function InputDialog:onTap(_, ges)
  if self:isKeyboardVisible() then
    local kb = self._input_widget.keyboard
    if kb and kb.dimen and ges.pos:notIntersectWith(kb.dimen) then self:onCloseKeyboard() end
  elseif self.frame.dimen and ges.pos:notIntersectWith(self.frame.dimen) then
    self:cancel()
  end
end

function InputDialog:onShow()
  UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

function InputDialog:onCloseWidget()
  self._input_widget:onCloseKeyboard()
  self._input_widget:onCloseWidget()
  UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
end

return InputDialog
