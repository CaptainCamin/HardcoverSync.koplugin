-- Whether a screen is still there.
--
-- Answers that arrive late (a request finishing, a cover decoding) must not touch a screen that
-- has gone: updating a freed widget crashes. A screen shown on its own is on KOReader's window
-- stack, so UIManager can say. A screen mounted in the shell (a tab's body) is not on the stack;
-- it is there for as long as its shell is, and it stays live while another tab is showing, so
-- an answer for a hidden tab is kept and is on screen when the tab is opened.
--
-- Use this wherever the code asked `UIManager:isWidgetShown(dialog)`.

local UIManager = require("ui/uimanager")

local Live = {}

function Live.shown(widget)
  if not widget then return false end
  if widget.shell then
    return UIManager:isWidgetShown(widget.shell) and not widget.unmounted
  end
  return UIManager:isWidgetShown(widget)
end

return Live
