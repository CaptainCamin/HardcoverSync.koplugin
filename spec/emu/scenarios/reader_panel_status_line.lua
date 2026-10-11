--[[--
The reader panel offers the progress switch only where
it does something. One panel per status: Currently Reading, Want to Read, not on a shelf, not
checked yet, Finished and Did not finish. The book and the library are stand-ins; the menu and
the panel are the real thing.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local fixtures = require("fixtures")

local HARDCOVER = { READING = 2, TO_READ = 1, FINISHED = 3, DNF = 5 }

local cases = {
  {
    key = "reading",
    book_status = { id = 501, status_id = HARDCOVER.READING, user_book_reads = { { progress_pages = 120 } } },
    shelf = "On your 'Currently Reading' shelf",
    switch = true, note = false, progress = true,
  },
  {
    key = "want_to_read",
    book_status = { id = 502, status_id = HARDCOVER.TO_READ, user_book_reads = {} },
    shelf = "On your 'Want to Read' shelf",
    switch = true, note = true, progress = false,
  },
  {
    key = "not_on_shelf",
    book_status = { not_on_shelf = true, user_book_reads = {} },
    shelf = "Not on a shelf",
    switch = true, note = true, progress = false,
  },
  {
    key = "not_checked",
    book_status = { user_book_reads = {} },
    shelf = "Shelf not checked yet",
    switch = true, note = false, progress = false,
  },
  {
    key = "finished",
    book_status = { id = 503, status_id = HARDCOVER.FINISHED, user_book_reads = { { progress_pages = 387 } } },
    shelf = "On your 'Read' shelf",
    switch = false, note = false, progress = true,
  },
  {
    -- no page was ever saved, so the panel must not claim "Page 0 of 387" (nor may Want to Read, no shelf, or unchecked)
    key = "did_not_finish",
    book_status = { id = 504, status_id = HARDCOVER.DNF, user_book_reads = {} },
    shelf = "On your 'Did Not Finish' shelf",
    switch = false, note = false, progress = false,
  },
}

return {
  name = "reader_panel_status_line",

  run = function(emu)
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")

    for _, case in ipairs(cases) do
      local settings = {
        bookLinked = function() return true end,
        getLinkedTitle = function() return "The Dispossessed" end,
        getLinkedBookId = function() return 328491 end,
        getLinkedEditionId = function() return nil end,
        getLinkedEditionFormat = function() return nil end,
        pages = function() return 387 end,
        syncEnabled = function() return true end,
        setSync = function() end,
        readSetting = function() return nil end,
      }
      local menu = HardcoverMenu:new({
        settings = settings,
        enabled = true,
        ui = {
          document = { file = "/books/x.epub", getPageCount = function() return 387 end },
          doc_props = { display_title = "x" },
        },
        state = { book_status = case.book_status },
        cache = { cacheUserBook = function() end, updateBookStatus = function() end },
        -- nothing waiting to be sent for this book
        sync_queue = {
          pendingCount = function() return 0 end,
          hasPending = function() return false end,
          get = function() return nil end,
        },
        auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
                 statusText = function() return "Signed in" end },
        dialog_manager = { maybeConfirm = function(_, o) o.ok_callback() end },
        hardcover = {},
      })

      menu:showReaderPanel()
      emu:pump()
      emu:screenNodes() -- paint first
      local text = emu:screenText()

      assert(not text:find("shelf", 1, true), case.key .. ": the panel names no shelf")
      assert((text:find("Read again", 1, true) ~= nil) == (case.key == "finished" or case.key == "did_not_finish"),
        case.key .. ": Read again is offered for a finished book only")
      assert(text:find("Update Hardcover as I read", 1, true) ~= nil == case.switch,
        case.key .. ": switch shown is " .. tostring(case.switch))
      assert(text:find("When on, reading moves it to Currently Reading.", 1, true) ~= nil == case.note,
        case.key .. ": reading-moves note shown is " .. tostring(case.note))
      if case.progress then
        assert(text:find("Page ", 1, true) ~= nil, case.key .. ": page line is missing")
      else
        assert(not text:find("Page 0", 1, true), case.key .. ": claims 'Page 0' with no saved page")
      end

      emu:shot("reader_panel_status_" .. case.key)
      emu:closeAll()
      -- a sheet only paints its own rows, so wipe the screen or the last, taller one shows through
      Device.screen.bb:fill(Blitbuffer.COLOR_WHITE)
    end
  end,
}
