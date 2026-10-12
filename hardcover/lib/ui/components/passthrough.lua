-- Lets KOReader's own gestures (Settings > Taps and gestures) work while one of the plugin's
-- full-screen windows is up.
--
-- KOReader sends a touch to the window on top of the stack, and the gesture manager lives on the
-- file browser or reader underneath, so a window that does not handle a gesture swallows it. A
-- window that calls Passthrough.forward from its handleEvent hands the gestures it did not use
-- to the window below it.
--
-- Not every gesture is passed on: a tap or hold in the middle of the screen is the window's, and
-- passing it on would turn a page behind the screen. Swipes, multi-finger gestures and taps in a
-- corner (where gestures like the frontlight and Wi-Fi toggles live) are.

local Device = require("device")
local UIManager = require("ui/uimanager")

local Passthrough = {}

-- gestures that are never the window's own: nothing in the plugin binds them
local ALWAYS = {
  swipe = true, multiswipe = true,
  two_finger_swipe = true, two_finger_tap = true, two_finger_hold = true,
  two_finger_pan = true, spread = true, pinch = true, rotate = true,
}

-- a tap in the corner squares (an eighth of the screen each way), where corner gestures live
local function inCorner(pos)
  if not pos then return false end
  local sw, sh = Device.screen:getWidth(), Device.screen:getHeight()
  local cw, ch = sw / 8, sh / 8
  return (pos.x < cw or pos.x > sw - cw) and (pos.y < ch or pos.y > sh - ch)
end

function Passthrough.wants(ges)
  if not ges then return false end
  if ALWAYS[ges.ges] then return true end
  return ges.ges == "tap" and inCorner(ges.pos)
end

-- The window under `widget` in the stack, if any.
function Passthrough.below(widget)
  local stack = UIManager._window_stack
  if not stack then return nil end
  for i = #stack, 1, -1 do
    if stack[i].widget == widget then
      return stack[i - 1] and stack[i - 1].widget
    end
  end
end

-- Hand an event the widget did not use to the window below. Returns true if that window used it.
function Passthrough.forward(widget, event)
  if event.handler ~= "onGesture" then return false end
  local ges = event.args and event.args[1]
  if not Passthrough.wants(ges) then return false end
  local below = Passthrough.below(widget)
  if below and below.handleEvent then return below:handleEvent(event) and true or false end
  return false
end

return Passthrough
