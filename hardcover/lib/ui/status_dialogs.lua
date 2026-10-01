-- Loading, error, info and retry surfaces shared by every Hardcover screen.
--
-- This module exists because the plugin had no shared way to say any of those
-- things, and each screen improvised its own -- which is how four code paths
-- ended up showing an error before the screen it belonged to, and how a failed
-- rating save could be reported by calling a misspelled field and raising.
--
-- The rule it encodes: whatever the user tapped puts something on screen BEFORE
-- any network result exists. Callers show their dialog, then call loading(),
-- then fill the dialog in from the callback.
--
-- Adapted from ZlibraryKO/zlibrary.koplugin -- zlibrary/ui.lua showLoadingMessage,
-- showErrorMessage, closeMessage and showRetryErrorDialog, and
-- zlibrary/dialog_manager.lua showErrorMessage's icon and self-closing widgets.

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local _ = require("gettext")

local SD = {}

-- A loading indicator. Deliberately an InfoMessage and not a spinner widget: it
-- is one line of code and cannot fail to construct on an older KOReader.
--
-- No force_one_line, deliberately. To fit a single line, InfoMessage shrinks its
-- font and re-runs init(); a plugin that patches InfoMessage.init to impose its
-- own font (appearance.koplugin does) resets that font on every re-run, so the
-- loop never converges and KOReader dies with a stack overflow. Wrapping onto a
-- second line needs no re-run.
--
-- The hourglass is a text glyph rather than an icon because show_icon = false
-- already; naming it inline keeps the message readable in a text dump.
function SD.loading(text)
  local message = InfoMessage:new{
    text = string.format("\u{23f3}  %s", text),
    dismissable = false,
    show_icon = false,
  }
  UIManager:show(message)
  return message
end

-- Close a message this module returned.
--
-- Prefers the widget's own close() because that is what dismisses an InfoMessage
-- correctly and fires its dismiss_callback; UIManager:close is the fallback for
-- anything without one. The "full" setDirty afterwards is not decoration: after
-- the panel has been covered by a message, a partial refresh can leave a ghost
-- of it, and a full repaint is cheap on e-ink compared to a wrong screen.
function SD.close(message)
  if not message then return end
  if type(message.close) == "function" then
    message:close()
    UIManager:setDirty("all", "full")
  else
    UIManager:close(message)
  end
end

-- A failure the user must notice. The icon is the point: Ui.showErrorMessage's
-- branch without a manager to hand it to, which is the one actually taken here,
-- so without it every error in the plugin rendered as an ordinary notice while
-- the code claimed otherwise.
function SD.error(text, timeout)
  local message = InfoMessage:new{
    text = text,
    icon = "notice-warning",
    timeout = timeout or 5,
  }
  UIManager:show(message)
  return message
end

-- Something that worked, or a neutral notice. No icon, shorter timeout: a success
-- message that lingers reads as a warning the user cannot clear.
function SD.info(text, timeout)
  local message = InfoMessage:new{
    text = text,
    timeout = timeout or 3,
  }
  UIManager:show(message)
  return message
end

-- A yes/no question.
--
-- ConfirmBox closes ITSELF from its own callbacks -- OK, Cancel and any
-- other_buttons all end in UIManager:close(self) -- and none of those paths goes
-- through the caller. So do not treat the returned widget as owned by the caller,
-- and do not try to close it after a callback; it is already gone.
function SD.confirm(options)
  options = options or {}
  local box = ConfirmBox:new{
    text = options.text or "",
    title = options.title,
    ok_text = options.ok_text or _("OK"),
    ok_callback = options.ok_callback,
    cancel_text = options.cancel_text or _("Cancel"),
    cancel_callback = options.cancel_callback,
  }
  UIManager:show(box)
  return box
end

-- Offer to try a failed operation again.
--
-- The frame is deliberately impersonal -- "Could not complete X" -- with the
-- operation name as the object rather than the subject. Naming it as the subject
-- means the verb has to agree with it in every language, and these names are a
-- mix of singular and plural, so ten of z-library's fourteen locales produced
-- "Kommentare ist fehlgeschlagen" before the frame was rewritten this way.
--
-- The underlying error text is included rather than replaced: a caller that
-- collapses every failure into one sentence cannot tell a DNS failure from a
-- dropped connection, and the user cannot either. Nothing here claims the failure
-- was temporary, because for a walled server or a wrong host it is not, and
-- "temporary" invites a retry that cannot work.
function SD.retry(err, operation_name, retry_callback, cancel_callback)
  return SD.confirm{
    text = string.format(
      _("Could not complete \"%s\": %s Would you like to retry?"),
      tostring(operation_name), tostring(err)),
    ok_text = _("Retry"),
    cancel_text = _("Cancel"),
    ok_callback = retry_callback,
    cancel_callback = cancel_callback,
  }
end

return SD