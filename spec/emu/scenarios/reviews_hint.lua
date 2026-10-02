--[[--
Reviews when the sign-in predates the read:users scope: every reviewer is "A reader",
so the screen says why and how to get the names. With the scope the note is absent
(covered by the reviews scenario, which has names and no note).
]]

local fixtures = require("fixtures")
local Reviews = require("hardcover/lib/reviews")

return {
  name = "reviews_hint",

  run = function(emu)
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local rows = Reviews.normalizeAll({
      { id = 1, rating = 4, review_raw = "Loved it.", review_has_spoilers = false, likes_count = 3 },
      { id = 2, rating = 3, review_raw = "Fine.", review_has_spoilers = false, likes_count = 1 },
    })
    local dialog = require("hardcover/lib/ui/reviews_dialog"):new {
      message = nil,
      summary = { title = "The Dispossessed", rating = 4.3, count = 120 },
      hint = "Names are hidden: sign out and back in to see them.",
      fetch_page = function(_, _, cb) cb({}, nil, 0) end,
    }
    require("ui/uimanager"):show(dialog)
    dialog:addPage(rows, #rows, 0)
    emu:pump()
    emu:expectText("A reader")
    emu:expectText("Names are hidden")
    emu:shot("reviews_hint")
    emu:closeAll()
  end,
}
