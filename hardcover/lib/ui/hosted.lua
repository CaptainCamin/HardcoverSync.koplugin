-- What a screen needs to know to live as a tab's body in the shell (ui/shell.lua) as well as on
-- its own. A hosted screen has no title bar and no close of its own (the shell has both), takes
-- the size the shell gives it, and asks for its repaints through the shell, because only the shell
-- is on KOReader's window stack.
--
-- A screen opts in by being built with `shell`, `width` and `height`:
--   Hosted.window(self)    what to hand UIManager / Refresh as the window to repaint
--   Hosted.size(self)      the screen's size, whole or the body's share of it
--   Hosted.dirty(self)     repaint this screen, in its own box (the whole panel when it is alone)
--   Hosted.remount(host, screen)  a retry's new screen takes the old one's place
--
-- A screen inside the Library tab also has a `parent` (the Library body).

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

-- A retry built a new screen for a tab that already had one: put it in the old one's place.
-- `host` is what the screen was built with ({ shell, width, height, id, parent }).
function Hosted.remount(host, screen)
  (host.parent or host.shell):remount(host.id, screen)
end

-- The `host` to give a retry's remount: the same tab, at the size the failed screen's parent
-- gives bodies now. The failed screen's captured width/height are stale when the panel was
-- resized since (the shell rebuilds every body on SetDimensions), and for a Library sub-tab
-- the parent's size is already less its own tab row.
function Hosted.retryHost(host)
  if not host then return nil end
  local shell = host.shell or (host.parent and host.parent.shell)
  -- a retry remounts into the failed screen's parent: a resize replaces the bodies, so the
  -- live one is found by kind among the shell's (a Library sub-tab's parent is its body)
  local parent = host.parent or shell
  if host.parent and shell and shell.bodies then
    for _, body in pairs(shell.bodies) do
      if type(body) == "table" and getmetatable(body) == getmetatable(host.parent) then
        parent = body break
      end
    end
  end
  return { shell = shell, width = parent and parent.body_w or host.width,
    height = parent and parent.body_h or host.height,
    id = host.id, parent = parent ~= shell and parent or nil, remount = true }
end

return Hosted
