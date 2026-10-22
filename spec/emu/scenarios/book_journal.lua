--[[--
The open book's journal, reached from the reader panel's Journal button: only this book's entries
(the request carries the book's id), a quote opening in full, and the offline message.

Screens: book_journal, book_journal_offline.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")

return {
  name = "book_journal",

  run = function(emu)
    local Feed = require("hardcover/lib/feed")
    local requests = {}
    local settings = fixtures.real_settings(emu)
    fixtures.install({
      settings = settings,
      overrides = {
        getFeed = function(_, opts)
          requests[#requests + 1] = opts
          return Feed.parse({
            journals = { { id = 1, event = "quote", entry = "Fear is the mind-killer.", user_id = fixtures.USER_ID,
              created_at = "2026-10-20T10:00:00+00:00", metadata = { position = { type = "pages", value = 12 } },
              user = { name = "Dana" }, book = { id = 328491, title = "Dune" } } },
          }, opts.limit)
        end,
      },
    })

    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new { settings = settings }

    manager:showBookJournal(328491)
    emu:pump()
    local screen = UIManager:getTopmostVisibleWidget()
    assert(screen and screen.name == "hardcover_journal_screen", "the journal did not open: " .. tostring(screen and screen.name))
    assert(#requests == 1 and requests[1].book_id == 328491 and requests[1].mine == true,
      "the journal should ask for this book's own entries only")
    emu:expectText("Journal")
    emu:expectText("Fear is the mind-killer")
    emu:shot("book_journal")
    screen:onClose()
    emu:pump()
  end,
}
