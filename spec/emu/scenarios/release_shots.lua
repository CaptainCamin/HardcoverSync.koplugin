--[[--
Screenshots for a release post: the reader panel over a made-up book (so it is
obvious what the panel sits on). The book, its author and its prose are invented.
]]

local fixtures = require("fixtures")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local PAGES = {
  "The ferry did not run on the day of the surveyors, which was how Ines came to be rowing, and why the salt-wives remembered her afterward as the girl who arrived by water instead of by the road.",
  "She had been told to expect a flat grey coast. What she found was a country made entirely of edges: pans of evaporated brine ruled into squares, causeways no wider than a cart, and a sky so large and so empty that the lighthouse seemed less like a warning than an apology.",
  "\"You are the cartographer,\" said the woman at the landing. It was not a question. She looked at the oilcloth tube strapped across Ines's back, then at her hands, which were the hands of someone who had never carried anything heavier than a pen.",
  "\"I am the assistant,\" Ines said. \"The cartographer is ill, and the survey cannot wait for the tide tables.\"",
  "The woman laughed, a short dry sound, like a shutter closing. \"Nothing here waits for the tide tables,\" she said. \"It is the other way around.\"",
  "They walked inland along the causeway while the light went from white to brass. Ines counted the pans as she passed them and stopped at forty, because the numbers had begun to feel like a kind of trespass.",
}

return {
  name = "release_shots",

  run = function(emu)
    local settings = {
      bookLinked = function() return true end,
      getLinkedTitle = function() return "The Salt Cartographer" end,
      getLinkedBookId = function() return 1 end,
      getLinkedEditionId = function() return nil end,
      getLinkedEditionFormat = function() return nil end,
      pages = function() return 387 end,
      syncEnabled = function() return true end,
      setSync = function() end,
      readSetting = function() return nil end,
    }
    fixtures.install({ settings = fixtures.real_settings(emu) })

    -- the page being read, behind everything
    local w, h = Screen:getWidth(), Screen:getHeight()
    local margin = Screen:scaleBySize(34)
    local body = VerticalGroup:new { align = "left" }
    table.insert(body, VerticalSpan:new { width = Screen:scaleBySize(26) })
    table.insert(body, TextWidget:new {
      text = "The Salt Cartographer", face = Font:getFace("cfont", 17), max_width = w - 2 * margin,
      fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    })
    table.insert(body, VerticalSpan:new { width = Screen:scaleBySize(26) })
    for _, para in ipairs(PAGES) do
      table.insert(body, TextBoxWidget:new {
        text = para, face = Font:getFace("cfont", 21), width = w - 2 * margin,
        alignment = "justify", line_height = 0.3,
      })
      table.insert(body, VerticalSpan:new { width = Screen:scaleBySize(14) })
    end
    local page = require("ui/widget/container/topcontainer"):new {
      dimen = require("ui/geometry"):new { x = 0, y = 0, w = w, h = h },
      require("ui/widget/horizontalgroup"):new {
        require("ui/widget/horizontalspan"):new { width = margin }, body },
    }
    local backdrop = FrameContainer:new {
      width = w, height = h, background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, margin = 0,
      page,
    }
    page = backdrop
    UIManager:show(page)
    emu:pump()

    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
    local menu = HardcoverMenu:new({
      settings = settings,
      enabled = true,
      ui = { document = { file = "/books/salt.epub" }, doc_props = { display_title = "The Salt Cartographer" } },
      state = { book_status = { id = 1, status_id = 2, rating = 4.5,
        user_book_reads = { { progress_pages = 142 } } } },
      cache = { cacheUserBook = function() end },
      sync_queue = { pendingCount = function() return 0 end, hasPending = function() return false end },
      auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
               statusText = function() return "Signed in" end },
      dialog_manager = {}, hardcover = {},
    })
    menu:showReaderPanel()
    emu:pump()
    emu:expectText("The Salt Cartographer")
    emu:shot("release_reader_panel")
    emu:closeAll()
  end,
}
