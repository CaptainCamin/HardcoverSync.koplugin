-- Quit the plugin: close every one of its screens, so the reader (or the file browser)
-- is what is left. The X in every title bar does this; Back only leaves one screen.
--
-- Each screen is closed with UIManager:close, not onClose: a screen's own back action
-- would reveal the one beneath, which would then be closed in turn, and a screen's
-- close_callback may reopen something. onCloseWidget still runs, so each screen tidies up.

local ScreenRegistry = require("hardcover/lib/screen_registry")

local Quit = {}

function Quit.run()
  local UIManager = require("ui/uimanager")
  -- a snapshot, top first: closing changes the stack under us
  local stack = {}
  for i = #UIManager._window_stack, 1, -1 do
    stack[#stack + 1] = UIManager._window_stack[i].widget
  end
  for _, widget in ipairs(ScreenRegistry.pluginWindows(stack)) do
    UIManager:close(widget)
  end
end

return Quit
