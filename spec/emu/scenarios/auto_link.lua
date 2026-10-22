--[[--
The dialog shown when a book is matched to Hardcover automatically: Keep, or "Wrong book?" for a
sheet to choose another book or unlink.
]]

local function tapText(emu, text)
  local n = emu:expectText(text)
  emu:tap(n.x + 5, n.y + 5)
  emu:pump()
end

return {
  name = "auto_link",

  run = function(emu)
    local changed, unlinked
    require("hardcover/lib/ui/auto_link_dialog").show {
      book = { title = "Dune" },
      on_change = function() changed = true end,
      on_unlink = function() unlinked = true end,
    }
    emu:pump()
    emu:expectText("Linked to Hardcover")
    emu:expectText("Dune")
    emu:shot("auto_link")

    tapText(emu, "Wrong book?")
    emu:expectText("Not the right book?")
    emu:shot("auto_link_wrong")

    tapText(emu, "Unlink this book")
    assert(unlinked and not changed, "unlink callback ran")
    emu:closeAll()
  end,
}
