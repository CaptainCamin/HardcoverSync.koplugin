-- Which plugin screen of each kind is open.
--
-- KOReader's window stack is the navigation: a screen shown over another is on
-- top, and closing it (a tap, the back button, KOReader itself) reveals the one
-- beneath. Nothing here duplicates that. This only remembers the latest screen of
-- each kind (home, shelf, goals...) so that
--   * showing a kind again (a retry, a second tap) can take the old one down first, and
--   * another screen can reach an open one to update it (a saved goal changes
--     Home's card and the Goals list underneath).
--
-- Each screen is kept in `owner.<kind>_dialog`, the field it has always had, so
-- code and tests that read `manager.home_dialog` keep working.
--
-- Pure: how to tell a widget is on screen and how to close one are handed in
-- (`ui.is_shown(widget)`, `ui.close(widget)`), so it runs under stock Lua in the
-- spec suite.

local ScreenRegistry = {}
ScreenRegistry.__index = ScreenRegistry

local function slot(kind)
  return kind .. "_dialog"
end

function ScreenRegistry.new(owner, ui)
  return setmetatable({ owner = owner, ui = ui }, ScreenRegistry)
end

-- Remember `widget` as the open screen of this kind. Does not touch the previous
-- one (see discard). Returns the widget.
function ScreenRegistry:track(kind, widget)
  self.owner[slot(kind)] = widget
  return widget
end

--
-- Take down the screen of this kind that is about to be replaced, and forget it.
--
-- free() alone is not enough: a dialog that is still on KOReader's window stack
-- stays there, freed, underneath its replacement. Closing the replacement then
-- reveals the dead one -- a menu that was closed but is still on screen. The
-- retry paths hit this: the failed dialog is still showing when "Retry" builds
-- its successor. close() rather than onClose(), so the dialog's close_callback
-- (which can prompt to turn wifi off) is not fired for a replacement.
--
function ScreenRegistry:discard(kind)
  local widget = self.owner[slot(kind)]
  self.owner[slot(kind)] = nil
  if not widget then return end
  if self.ui.is_shown(widget) then
    self.ui.close(widget)
  end
  widget:free()
end

-- The screen of this kind, only while it is on screen: a closed one is not
-- something to update. nil otherwise.
function ScreenRegistry:open(kind)
  local widget = self.owner[slot(kind)]
  if widget and self.ui.is_shown(widget) then
    return widget
  end
  return nil
end

--
-- Quit: which widgets on KOReader's window stack are the plugin's, in the order
-- given (top first). Every screen of the plugin is named "hardcover_..." (its `name`),
-- so the name says which are ours; the reader or the file browser under them is not.
-- `stack` is a list of widgets.
--
function ScreenRegistry.pluginWindows(stack)
  local ours = {}
  for _, widget in ipairs(stack) do
    if type(widget.name) == "string" and widget.name:find("^hardcover_") then
      ours[#ours + 1] = widget
    end
  end
  return ours
end

--
-- Quit: the windows (from pluginWindows) that hold changes not yet saved. A screen says so with
-- an `unsavedChanges()` method; one without it has nothing to lose.
--
function ScreenRegistry.unsaved(windows)
  local out = {}
  for _, widget in ipairs(windows) do
    if type(widget.unsavedChanges) == "function" and widget:unsavedChanges() then
      out[#out + 1] = widget
    end
  end
  return out
end

return ScreenRegistry
