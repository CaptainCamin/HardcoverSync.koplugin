-- Quit the plugin: close every one of its screens, so the reader (or the file browser)
-- is what is left. The X in every title bar does this; Back only leaves one screen.
-- A screen with unsaved changes (see ScreenRegistry.unsaved) makes Quit ask first.
--
-- Each screen is closed with UIManager:close, not onClose: a screen's own back action
-- would reveal the one beneath, which would then be closed in turn, and a screen's
-- close_callback may reopen something. onCloseWidget still runs, so each screen tidies up.

local ScreenRegistry = require("hardcover/lib/screen_registry")
local _ = require("gettext")

local Quit = {}

function Quit.run()
  local UIManager = require("ui/uimanager")
  local ConfirmBox = require("ui/widget/confirmbox")

  -- the plugin's windows as the stack is now, top first
  local function ours()
    local stack = {}
    for i = #UIManager._window_stack, 1, -1 do
      stack[#stack + 1] = UIManager._window_stack[i].widget
    end
    return ScreenRegistry.pluginWindows(stack)
  end
  -- closing changes the stack under us, so the list is taken before the first close
  local function close_all(windows)
    for _, widget in ipairs(windows) do
      UIManager:close(widget)
    end
  end

  local windows = ours()
  if #ScreenRegistry.unsaved(windows) == 0 then
    close_all(windows)
    return
  end
  UIManager:show(ConfirmBox:new {
    text = _("Discard your changes and quit?"),
    ok_text = _("Discard"),
    -- read the stack again now: it may have changed while the question was up
    ok_callback = function() close_all(ours()) end,
  })
end

return Quit
