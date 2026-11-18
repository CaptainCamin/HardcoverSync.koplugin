--[[--
Home's currently-reading card at zero progress (issue #317): the bar and the percent line stay
(at 0), so the card keeps its height and the sync box below it never moves.

Screens: home_zero_progress, home_with_progress.
]]

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")
local HomeBody = require("hardcover/lib/ui/home_body")

local function note_y(emu)
  for _, node in ipairs(emu:screenNodes()) do
    if node.text == "All synced" then return node.y end
  end
  error("no sync box on Home")
end

return {
  name = "home_zero_progress",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })

    local function entry(progress)
      return { { book_id = 103, title = "The Left Hand of Darkness", authors = "Ursula K. Le Guin",
        progress_pages = progress, edition_pages = 300 } }
    end

    -- no progress yet: the server has no page for the book
    local body = HomeBody:new { entries = entry(nil), rows = {}, open_book_cb = function() end }
    UIManager:show(body)
    emu:pump()
    emu:expectText("0% · page 0 of 300")
    emu:expectNoButtonOverlap()
    emu:shot("home_zero_progress")
    local zero_y = note_y(emu)

    -- an explicit 0 says the same
    body:setReading(entry(0))
    emu:pump()
    emu:expectText("0% · page 0 of 300")
    assert(note_y(emu) == zero_y, "the sync box moved between no progress and page 0")

    -- exact boundary: 29 of 100 must say 29%, not 28% (float 29/100*100 < 29)
    body:setReading({ { book_id = 103, title = "The Left Hand of Darkness", authors = "Ursula K. Le Guin",
      progress_pages = 29, edition_pages = 100 } })
    emu:pump()
    emu:expectText("29% · page 29 of 100")

    -- over 100%: the percent clamps to 100, agreeing with the bar
    body:setReading({ { book_id = 103, title = "The Left Hand of Darkness", authors = "Ursula K. Le Guin",
      progress_pages = 350, edition_pages = 300 } })
    emu:pump()
    emu:expectText("100% · page 350 of 300")

    -- with progress: the same card height, the sync box in the same place
    body:setReading(entry(186))
    emu:pump()
    emu:expectText("62% · page 186 of 300")
    emu:shot("home_with_progress")
    assert(note_y(emu) == zero_y, "the card shrank at zero progress and moved the sync box")
    emu:closeAll()
  end,
}
