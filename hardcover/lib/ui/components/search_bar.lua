-- Search bar (MMD top bar + search field): the top bar turned into a place to type. A back arrow
-- (touch 48) that leaves without searching, the search field as a pill 48 tall (a magnifier, the words
-- in full Black, a clear X at the end once there are words) and the black rule under it, over whatever
-- screen is showing. KOReader's virtual keyboard comes up from the bottom; its Enter key searches.
-- Nothing else moves and the page beneath is neither dimmed nor covered below the bar.
--
--   local bar = SearchBar:new {
--     input = "start text", hint = "Title or author",
--     on_submit = function(query) ... return true end, -- true closes the bar (a search on its way)
--   }
--   UIManager:show(bar)
--   bar:onShowKeyboard()
--
-- Back hides the keyboard, then leaves. A tap on the page below does the same. `getInputText` and
-- `setInputText` are the same as on KOReader's input dialog.

local Device = require("device")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText = require("ui/widget/inputtext")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Draw = require("hardcover/lib/ui/components/draw")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local SearchBar = InputContainer:extend {
  name = "hardcover_search_bar",
  is_always_active = true, -- gets taps while the keyboard is the top window
  modal = true,
  input = "",
  hint = nil,
  on_submit = nil, -- function(query) -> true to close the bar
  on_cancel = nil,
}

function SearchBar:init()
  local screen = Device.screen
  local sw = screen:getWidth()
  local top = Theme.mmd.top_bar
  local m = Theme.mmd.search
  local rule = Theme.mmd.rule.overlay
  local inner_h = top.h - rule
  local border = Theme.line.firm

  -- the back arrow, then the pill to the right edge
  local back = TapRow:new {
    callback = function() self:cancel() end,
    CenterContainer:new { dimen = Geom:new { w = Theme.TOUCH_MIN, h = Theme.TOUCH_MIN },
      Draw.icon("back", top.icon) },
  }
  local left_pad = top.side - Theme.px(8)
  local pill_w = sw - left_pad - Theme.TOUCH_MIN - top.side
  local side = Theme.px(14)
  local gap = Theme.px(8)
  local pill_in_h = m.h - 2 * border

  local face = Theme.mmdFace("text", 21)
  local field_w = pill_w - 2 * border - side - m.icon_touch - gap - m.clear_touch
  self._input_widget = InputText:new {
    text = self.input or "",
    hint = self.hint,
    face = face,
    width = field_w,
    padding = 0,
    margin = 0,
    bordersize = 0,
    scroll = false,
    parent = self,
    enter_callback = function() self:submit() end,
    edit_callback = function() self:_repaintClear() end,
  }

  -- the X has its cell from the start so nothing shifts as words appear; it draws and answers only
  -- while there are words
  local clear_icon = Draw.icon("close", m.clear)
  local clear_cell = Draw.drawn(m.clear_touch, pill_in_h, function(bb, x, y, w, h)
    if self:getInputText() == "" then return end
    clear_icon:paintTo(bb, x + math.floor((w - m.clear) / 2), y + math.floor((h - m.clear) / 2))
  end)
  self._clear_cell = clear_cell
  local clear = TapRow:new {
    callback = function() self:clear() end,
    clear_cell,
  }
  self.clear_button = clear

  local icon_cell = CenterContainer:new { dimen = Geom:new { w = m.icon_touch, h = pill_in_h },
    Draw.icon("search", m.icon) }
  local row = HorizontalGroup:new { align = "center",
    Theme.hspan(side), icon_cell, Theme.hspan(gap),
    LeftContainer:new { dimen = Geom:new { w = field_w, h = pill_in_h }, self._input_widget },
    clear,
  }
  local pill = Theme.box(pill_w, m.h, row, { round = true, border = border })

  local line = HorizontalGroup:new { align = "center", Theme.hspan(left_pad), back, pill }
  local bar = VerticalGroup:new { align = "left",
    LeftContainer:new { dimen = Geom:new { w = sw, h = inner_h }, line },
    Draw.drawn(sw, rule, function(bb, x, y, w, h) bb:paintRect(x, y, w, h, Theme.BLACK) end),
  }
  self.back_button = back
  self.frame = FrameContainer:new { width = sw, bordersize = 0, padding = 0, margin = 0,
    background = Theme.WHITE, bar }
  self[1] = TopContainer:new { dimen = Geom:new { x = 0, y = 0, w = sw, h = screen:getHeight() }, self.frame }

  if Device:isTouchDevice() then
    self.ges_events = { Tap = { GestureRange:new { ges = "tap",
      range = Geom:new { x = 0, y = 0, w = sw, h = screen:getHeight() } } } }
  end
  if Device:hasKeys() then
    self.key_events = { Back = { { Device.input.group.Back } } }
  end
end

function SearchBar:getInputText() return self._input_widget:getText() end

function SearchBar:setInputText(text)
  self._input_widget:setText(text)
  self:_repaintClear()
end

function SearchBar:_repaintClear()
  local dimen = self._clear_cell and self._clear_cell.dimen
  if dimen and dimen.x then UIManager:setDirty(self, function() return "ui", dimen end) end
end

function SearchBar:onShowKeyboard(ignore_first_hold_release)
  self._input_widget:onShowKeyboard(ignore_first_hold_release)
end

function SearchBar:onCloseKeyboard() self._input_widget:onCloseKeyboard() end

function SearchBar:isKeyboardVisible() return self._input_widget:isKeyboardVisible() end

-- the X: no words, and the keyboard stays up for the next ones
function SearchBar:clear()
  if self:getInputText() == "" then return end
  self:setInputText("")
end

-- Enter: hand the words over; the caller says whether the bar is done
function SearchBar:submit()
  if self.on_submit and self.on_submit(self:getInputText()) then
    UIManager:close(self)
  end
end

function SearchBar:cancel()
  if self.on_cancel then self.on_cancel() end
  UIManager:close(self)
end

function SearchBar:onBack()
  if self:isKeyboardVisible() then
    self:onCloseKeyboard()
  else
    self:cancel()
  end
  return true
end

-- a tap on the page below, once the keyboard is down, leaves; with the keyboard up it puts it down
function SearchBar:onTap(_, ges)
  if self:isKeyboardVisible() then
    local kb = self._input_widget.keyboard
    if kb and kb.dimen and ges.pos:notIntersectWith(kb.dimen) and ges.pos:notIntersectWith(self.frame.dimen) then
      self:onCloseKeyboard()
    end
  elseif self.frame.dimen and ges.pos:notIntersectWith(self.frame.dimen) then
    self:cancel()
  end
end

function SearchBar:onShow()
  UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

function SearchBar:onCloseWidget()
  self._input_widget:onCloseKeyboard()
  self._input_widget:onCloseWidget()
  UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
end

return SearchBar
