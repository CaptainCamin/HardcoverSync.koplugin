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
-- the panel has been covered by a message. (No forced full-panel flash here: it
-- would black out the screen on every "Loading..." that closes.)
function SD.close(message)
  if not message then return end
  if type(message.close) == "function" then
    message:close()
  else
    UIManager:close(message)
  end
end

-- A failure the user must notice. A snackbar (MMD): a short line along the bottom edge after
-- something the reader did, that goes away on its own.
function SD.error(text, timeout)
  require("hardcover/lib/ui/components/snackbar").show { message = text, timeout = timeout or 5 }
end

-- Something that worked, or a neutral notice. Same snackbar, a little shorter.
function SD.info(text, timeout)
  require("hardcover/lib/ui/components/snackbar").show { message = text, timeout = timeout or 3 }
end

-- A yes/no question, as an MMD dialog: a title that says what it is about, one short text, the
-- other button outlined on the left and the answer filled on the right.
--
-- options { title, text, ok_text, ok_callback, cancel_text, cancel_callback }. With no cancel_text
-- the dialog has one button, for a notice that only needs acknowledging. Both callbacks run after the
-- dialog has closed, so the caller never closes it.
function SD.confirm(options)
  options = options or {}
  local buttons = {}
  if options.cancel_text ~= false then
    buttons[#buttons + 1] = { label = options.cancel_text or _("Cancel"), callback = options.cancel_callback }
  end
  buttons[#buttons + 1] = { label = options.ok_text or _("OK"), primary = true, callback = options.ok_callback }
  local title, text = options.title, options.text
  if not title then
    if text and #text <= 60 and not text:find("\n") then
      title, text = text, nil -- "Sign out of Hardcover?" says it all
    else
      title = options.ok_text or _("Are you sure?")
    end
  end
  return require("hardcover/lib/ui/components/dialog").show {
    title = title,
    text = text,
    buttons = buttons,
    on_dismiss = options.cancel_callback,
  }
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
-- Turn whatever a failed call handed back into text a person can read.
--
-- The API reports failure as nil plus an error *table* (for example
-- { completed = false } when there was no connection or the request was
-- cancelled), and tostring() of that prints "table: 0x...". Strings pass
-- through; known shapes get a sentence; anything else a generic one.
function SD.describe(err)
  if type(err) == "string" and err ~= "" then
    return err
  end
  if type(err) == "table" then
    if type(err.message) == "string" then return err.message end
    if err.completed == false then return _("no response from Hardcover") end
    if err.status then return string.format(_("Hardcover returned an error (%s)"), tostring(err.status)) end
  end
  return _("no response")
end

function SD.retry(err, operation_name, retry_callback, cancel_callback)
  return SD.confirm{
    title = _("Something went wrong"),
    text = string.format(
      _("Could not complete \"%s\": %s Would you like to retry?"),
      tostring(operation_name), SD.describe(err)),
    ok_text = _("Retry"),
    cancel_text = _("Cancel"),
    ok_callback = retry_callback,
    cancel_callback = cancel_callback,
  }
end

return SD