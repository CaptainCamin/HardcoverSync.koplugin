-- Tells the reader which Hardcover book the one they just opened was matched to, and lets them
-- correct it: Hardcover can match the wrong book, and the link decides where progress goes.
--
-- A dialog rather than a snackbar: this is a system event (the reader did nothing), and the match is
-- something to check, not a confirmation of a tap. It asks for no decision to move on: "Keep" (or a
-- tap outside, or Back) leaves the link as made. "Wrong book?" opens a sheet to pick another book or
-- to unlink.

local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")

local Dialog = require("hardcover/lib/ui/components/dialog")
local Picker = require("hardcover/lib/ui/picker")

local AutoLinkDialog = {}

-- opts: book ({ title }), on_change() to pick a different book, on_unlink() to forget the link.
function AutoLinkDialog.show(opts)
  local function wrong()
    local picker
    local function choose(callback)
      return function()
        UIManager:close(picker)
        if callback then callback() end
      end
    end
    picker = Picker.new {
      title = _("Not the right book?"),
      rows = {
        { text = _("Choose a different book"), callback = choose(opts.on_change) },
        { text = _("Unlink this book"), callback = choose(opts.on_unlink) },
      },
    }
    UIManager:show(picker)
  end

  return Dialog.show {
    title = _("Linked to Hardcover"),
    text = T(_("\"%1\" is the match for this book."), opts.book.title or "?"),
    buttons = {
      { label = _("Keep"), primary = true },
      { label = _("Wrong book?"), callback = wrong },
    },
  }
end

return AutoLinkDialog
