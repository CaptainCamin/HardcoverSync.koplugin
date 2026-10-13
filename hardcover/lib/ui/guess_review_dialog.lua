-- Asks, one book at a time, whether a guessed link (made by "Link all books on this device" from a
-- title and author) is right. "Right" keeps the link and drops the guess mark; "Wrong" forgets the
-- link. "Decide later" (or backing out) leaves the guess as it is.

local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")

local BulkLink = require("hardcover/lib/bulk_link")
local Picker = require("hardcover/lib/ui/picker")

local GuessReviewDialog = {}

-- opts: settings (HardcoverSettings), on_done(kept, undone) when the books run out.
function GuessReviewDialog.show(opts)
  local settings = opts.settings
  local kept, undone, skipped, skipped_count = 0, 0, {}, 0
  local total = #BulkLink.guessedBooks(settings:readSetting("books"))

  local function next_one()
    local pick
    for _i, guess in ipairs(BulkLink.guessedBooks(settings:readSetting("books"))) do
      if not skipped[guess.file] then
        pick = guess
        break
      end
    end
    if not pick then
      if opts.on_done then opts.on_done(kept, undone) end
      return
    end

    local picker
    local function answer(config, counter)
      return function()
        UIManager:close(picker)
        settings:updateBookSetting(pick.file, config, true)
        if counter == "kept" then kept = kept + 1 else undone = undone + 1 end
        next_one()
      end
    end
    picker = Picker.new {
      title = T(_("%1 of %2\n\n%3\n\nGuessed to be \"%4\" on Hardcover.\n\nIs that the right book?"),
        tostring(kept + undone + skipped_count + 1), tostring(total),
        pick.name, pick.title or "?"),
      rows = {
        { text = _("Right, keep the link"), callback = answer(BulkLink.confirmGuessConfig(), "kept") },
        { text = _("Wrong, unlink it"), callback = answer(BulkLink.undoGuessConfig(), "undone") },
        {
          text = _("Decide later"),
          callback = function()
            UIManager:close(picker)
            skipped[pick.file] = true
            skipped_count = skipped_count + 1
            next_one()
          end,
        },
      },
      close_callback = function()
        skipped[pick.file] = true
        skipped_count = skipped_count + 1
        next_one()
      end,
    }
    UIManager:show(picker)
  end

  next_one()
end

return GuessReviewDialog
