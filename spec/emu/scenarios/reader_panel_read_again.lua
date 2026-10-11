--[[--
A finished book's panel offers "Read again" beside its shelf line. Tapping it asks first, and then
the page goes to the sync queue as a re-read: sent at once when online, and kept for later when
offline. The queue, the cache and the network are stand-ins; the menu and the panel are the real
thing.
]]

local fixtures = require("fixtures")

local FINISHED, READING = 3, 2

return {
  name = "reader_panel_read_again",

  run = function(emu)
    fixtures.install({ settings = fixtures.real_settings(emu) })
    local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")
    local Network = require("hardcover/lib/network")
    local connected_before = Network.connected

    local function tapText(text)
      local node = emu:expectText(text)
      emu:tapExpecting(node.x + math.floor(node.w / 2), node.y + math.floor(node.h / 2))
    end

    for _, online in ipairs({ false, true }) do
      Network.connected = function() return online end
      local calls = {}

      local menu = HardcoverMenu:new({
        settings = {
          bookLinked = function() return true end,
          getLinkedTitle = function() return "The Dispossessed" end,
          getLinkedBookId = function() return 328491 end,
          getLinkedEditionId = function() return nil end,
          getLinkedEditionFormat = function() return nil end,
          pages = function() return 387 end,
          syncEnabled = function() return true end,
          setSync = function() end,
          readSetting = function() return nil end,
        },
        enabled = true,
        ui = {
          document = { file = "/books/x.epub", getPageCount = function() return 387 end },
          doc_props = { display_title = "x" },
          getCurrentPage = function() return 100 end,
        },
        page_mapper = { getMappedPage = function(_, page) return page end },
        state = { book_status = { id = 503, status_id = FINISHED,
          user_book_reads = { { id = 900, progress_pages = 387, edition_id = 3 } } } },
        cache = {
          queueMeta = function() return { book_id = 328491, edition_id = 3, user_book_id = 503 } end,
          applyLocalStatus = function(_, _, status) calls.local_status = status end,
          applyLocalPage = function(_, page) calls.local_page = page end,
          cacheUserBook = function() calls.refreshed = true end,
          updateBookStatus = function() end,
        },
        sync_queue = {
          pendingCount = function() return 0 end,
          hasPending = function() return false end,
          get = function() return nil end,
          startReread = function(_, _, payload) calls.reread_page = payload.mapped_page end,
          flush = function() calls.flushed = true return true end,
        },
        auth = { usingOAuth = function() return true end, needsReauth = function() return false end,
                 statusText = function() return "Signed in" end },
        dialog_manager = { maybeConfirm = function(_, o) o.ok_callback() end },
        hardcover = {},
      })

      menu:showReaderPanel()
      emu:pump()
      emu:screenNodes() -- paint first: tap ranges are only real once painted
      assert(emu:screenText():find("On your 'Read' shelf", 1, true), "the shelf line is missing")
      emu:shot(online and "reader_panel_read_again_online" or "reader_panel_read_again_offline")

      tapText("Read again")
      emu:pump()
      emu:screenNodes()
      assert(emu:screenText():find("Read this book again?", 1, true), "Read again did not ask first")
      tapText("Start reading again")
      emu:pump()

      assert(calls.reread_page == 100, (online and "online" or "offline") .. ": the re-read did not queue the page")
      if online then
        assert(calls.flushed, "online: the re-read was not sent at once")
        assert(calls.refreshed, "online: the book was not read back after Hardcover had the new read")
        assert(calls.local_status == nil, "online: the status changed before Hardcover confirmed it")
      else
        assert(not calls.flushed, "offline: the re-read was sent with no connection")
        assert(calls.local_status == READING, "offline: the book does not show as Currently Reading")
        assert(calls.local_page == 100, "offline: the new read's page is not shown")
      end

      emu:closeAll()
    end

    Network.connected = connected_before
  end,
}
