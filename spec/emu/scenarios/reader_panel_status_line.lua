--[[--
The reader panel says where the book is, in words, and offers the progress switch only where
it does something. One panel per status: Currently Reading, Want to Read, not on a shelf, not
checked yet, Finished and Did not finish. The book and the library are stand-ins; the menu and
the panel are the real thing.
]]

local fixtures = require("fixtures")

local HARDCOVER = { READING = 2, TO_READ = 1, FINISHED = 3, DNF = 5 }

local cases = {
  {
    key = "paused",
    book_status = { id = 505, status_id = 4, user_book_reads = { { progress_pages = 120 } } },
    shelf = "Paused", line = "Page 120 of 387",
  },
  {
    key = "reading",
    book_status = { id = 501, status_id = HARDCOVER.READING, user_book_reads = { { progress_pages = 120 } } },
    shelf = nil, -- no shelf line for Currently Reading
    line = "Page 120 of 387",
    switch = true, note = false,
  },
  {
    key = "want_to_read",
    book_status = { id = 502, status_id = HARDCOVER.TO_READ, user_book_reads = {} },
    shelf = "Want to Read",
    line = "387 pages",
    switch = false, note = false, hint = true,
  },
  {
    key = "not_on_shelf",
    book_status = { not_on_shelf = true, user_book_reads = {} },
    shelf = "Not on a shelf",
    line = "387 pages",
    switch = false, note = false, hint = true,
  },
  {
    key = "not_checked",
    book_status = { user_book_reads = {} },
    shelf = "Shelf not checked yet",
    line = "387 pages",
    switch = false, note = false, hint = true,
  },
  {
    key = "finished",
    book_status = { id = 503, status_id = HARDCOVER.FINISHED, user_book_reads = { { progress_pages = 387 } } },
    shelf = "Read",
    line = "Page 387 of 387",
    switch = false, note = false,
  },
  {
    -- no page was ever saved, so the panel says how long the book is and must not claim "Page 0 of 387" (nor may Want to Read, no shelf, or unchecked)
    key = "did_not_finish",
    book_status = { id = 504, status_id = HARDCOVER.DNF, user_book_reads = {} },
    shelf = "Did Not Finish",
    line = "387 pages",
    switch = false, note = false,
  },
  {
    -- tracking off: the switch comes back for any book, and says how to update by hand
    key = "want_to_read_tracking_off",
    sync = false,
    book_status = { id = 502, status_id = HARDCOVER.TO_READ, user_book_reads = {} },
    shelf = "Want to Read",
    line = "387 pages",
    switch = true, note = true,
  },
  {
    key = "not_on_shelf_tracking_off",
    sync = false,
    book_status = { not_on_shelf = true, user_book_reads = {} },
    shelf = "Not on a shelf",
    line = "387 pages",
    switch = true, note = true,
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
        syncEnabled = function() return case.sync ~= false end,
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

      if case.shelf then
        assert(text:find(case.shelf, 1, true), case.key .. ": status line says '" .. case.shelf .. "'")
      else
        assert(not text:find(" shelf", 1, true) and not text:find("Not on a shelf", 1, true),
          case.key .. ": has a shelf line, which Currently Reading leaves out")
      end
      assert(text:find(case.line, 1, true), case.key .. ": line under the title says '" .. case.line .. "'")
      local model = menu.reader_panel.opts.model()
      assert(#model.actions == 5, "linked books must keep five action slots")
      assert(model.actions[1].enabled == (case.book_status.status_id == HARDCOVER.READING), "progress availability disagrees with reading status")
      for _, gone in ipairs({ "Update Hardcover as I read", "Change status to update progress.", "asked to start reading", "Cancel", "Close" }) do
        assert(not text:find(gone, 1, true), case.key .. ": obsolete text " .. gone)
      end
      if case.key == "did_not_finish" then
        emu:expectText("You didn't finish this book.")
        emu:expectText("Start over")
      end
      assert(not text:find("Page 0", 1, true), case.key .. ": claims 'Page 0' with no saved page")

      emu:shot("reader_panel_status_" .. case.key)
      emu:closeAll()
    end
  end,
}
