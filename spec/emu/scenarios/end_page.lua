--[[--
The end page: a book reached its end and is not yet Read, then the same page for a Read book
with its change still waiting to be sent.
]]

local fixtures = require("fixtures")

local function build(emu, queued)
  local state = { book_status = { id = 1, status_id = 2, rating = 4 } }
  local settings = {
    getLinkedTitle = function() return "The Left Hand of Darkness" end,
    getLinkedBookId = function() return 103 end,
  }
  fixtures.install({ settings = fixtures.real_settings(emu) })
  local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
  return HardcoverMenu:new({
    settings = settings, enabled = true,
    ui = { document = { file = "/books/x.epub" }, doc_props = { display_title = "x" } },
    state = state,
    cache = { updateBookStatus = function() end },
    sync_queue = { get = function() return queued and { status_id = 3 } or nil end },
    dialog_manager = {},
  })
end

return {
  name = "end_page",

  run = function(emu)
    local menu = build(emu, false)
    menu:showEndPage()
    emu:pump()
    emu:expectText("You've reached the end")
    emu:expectText("The Left Hand of Darkness")
    emu:expectText("Currently Reading")
    emu:expectText("Mark as Read")
    emu:expectText("Keep as Currently Reading")
    emu:expectNoButtonOverlap()
    emu:shot("end_page")

    local queued = build(emu, true)
    queued:showEndPage()
    emu:pump()
    emu:expectText("waiting to send")
    emu:expectText("Done")
    emu:shot("end_page_waiting")
  end,
}
