-- What a screen needs to know to live as a tab's body in the shell (ui/shell.lua) as well as on
-- its own. A hosted screen has no title bar and no close of its own (the shell has both), takes
-- the size the shell gives it, and asks for its repaints through the shell, because only the shell
-- is on KOReader's window stack.
--
-- A screen opts in by being built with `shell`, `width` and `height`:
--   Hosted.window(self)    what to hand UIManager / Refresh as the window to repaint
--   Hosted.size(self)      the screen's size, whole or the body's share of it
--   Hosted.dirty(self)     repaint this screen, in its own box (the whole panel when it is alone)

local Hosted = {}

function Hosted.window(screen)
  return screen.shell or screen
end

function Hosted.size(screen)
  if screen.shell then return screen.width, screen.height end
  local Screen = require("device").screen
  return Screen:getWidth(), Screen:getHeight()
end

function Hosted.dirty(screen)
  local UIManager = require("ui/uimanager")
  if not screen.shell then
    UIManager:setDirty(screen, "ui")
    return
  end
  -- a tab that is not showing has nothing to repaint: it is drawn when it is opened
  if screen.shell:isActive(screen) then
    UIManager:setDirty(screen.shell, function() return "ui", screen.dimen end)
  end
end

return Hosted
