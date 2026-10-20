-- BUG (guarded against): shelf and list changes made offline from a book's details wait in
-- their own queues, and flushSyncQueue returns early unless something it knows about is
-- waiting -- so a queue it did not know about is never sent, whatever the connection does.
--
-- Expected: with ONLY a shelf change (or ONLY a list change) waiting, the connection coming
-- back sends it exactly once, tells the screens (shelfSent / listChangeSent), and a second
-- connect sends nothing more.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
local App = KB.load_main()
local User = require("hardcover/lib/user")
User.settings = { readSetting = function() return 1 end, updateSetting = function() end }
local Api = require("hardcover/lib/hardcover_api")
local ShelfQueue = require("hardcover/lib/shelf_queue")
local ListQueue = require("hardcover/lib/list_queue")

print("\n== shelf and list changes made offline are sent when the connection is back ==")

local writes
Api.updateUserBook = function(_, book_id, status_id, _, edition_id)
  writes[#writes + 1] = { "updateUserBook", book_id, status_id, edition_id }
  return { id = 77, status_id = status_id }
end
Api.removeUserBook = function(_, id) writes[#writes + 1] = { "removeUserBook", id } return { id = id } end
Api.addToList = function(_, book_id, list_id, position)
  writes[#writes + 1] = { "addToList", book_id, list_id, position }
  return { id = 88 }
end
Api.removeFromList = function(_, id) writes[#writes + 1] = { "removeFromList", id } return { id = id } end

local function newApp(shelf_queue, list_queue, told)
  return KB.new_app {
    state = { book_status = {} },
    ui = {},
    settings = { readSetting = function() return false end, syncEnabled = function() return false end },
    sync_queue = {
      hasPending = function() return false end,
      pendingCount = function() return 0 end,
      filepaths = function() return {} end,
      flush = function() return true end,
    },
    shelf_queue = shelf_queue,
    list_queue = list_queue,
    dialog_manager = {
      shelfSent = function(_, op, ub) told[#told + 1] = { "shelfSent", op.book_id, ub and ub.id } end,
      listChangeSent = function(_, op) told[#told + 1] = { "listChangeSent", op.list_id, op.book_id } end,
    },
    wifi = { withWifi = function(_, fn) fn() end },
  }
end

local function queues()
  local settings = KB.fakeSettings()
  return ShelfQueue:new { settings = settings }, ListQueue:new { settings = settings }
end

KB.check("only a shelf change is waiting: it is sent once, the screens are told", function()
  writes = {}
  local told = {}
  local shelf, list = queues()
  shelf:queueStatus(1, 100, 3, { edition_id = 5 })
  KB.network.connected = true
  local app = newApp(shelf, list, told)
  app:onNetworkConnected()
  KB.eq(#writes, 1, "writes")
  KB.eq(writes[1][1], "updateUserBook"); KB.eq(writes[1][2], 100); KB.eq(writes[1][3], 3); KB.eq(writes[1][4], 5)
  KB.eq(#told, 1, "screens told"); KB.eq(told[1][1], "shelfSent"); KB.eq(told[1][3], 77)
  KB.eq(shelf:count(), 0)
  app:onNetworkConnected()
  KB.eq(#writes, 1, "sent again on the next connect")
end)

KB.check("only a list change is waiting: it is sent once, the screens are told", function()
  writes = {}
  local told = {}
  local shelf, list = queues()
  list:queueAdd(1, 100, 6, 4, {})
  list:queueRemove(1, 101, 6, 91, {})
  KB.network.connected = true
  local app = newApp(shelf, list, told)
  app:onNetworkConnected()
  KB.eq(#writes, 2, "writes")
  KB.eq(writes[1][1], "addToList"); KB.eq(writes[1][4], 4)
  KB.eq(writes[2][1], "removeFromList"); KB.eq(writes[2][2], 91)
  KB.eq(#told, 2); KB.eq(told[1][1], "listChangeSent")
  KB.eq(list:count(), 0)
  app:onNetworkConnected()
  KB.eq(#writes, 2, "sent again on the next connect")
end)

KB.check("a refused change is held, the user is told once, and nothing else is blocked", function()
  writes = {}
  local told = {}
  local shelf, list = queues()
  shelf:queueStatus(1, 100, 3, {})
  shelf:queueStatus(1, 101, 1, {})
  local real = Api.updateUserBook
  Api.updateUserBook = function(_, book_id, status_id)
    if book_id == 100 then return nil, "Book not found" end
    return real(_, book_id, status_id)
  end
  KB.network.connected = true
  local app = newApp(shelf, list, told)
  for _ = 1, 3 do app:onNetworkConnected() end
  Api.updateUserBook = real
  KB.eq(shelf:get(100).held, true)
  KB.eq(shelf:get(101), nil, "the other change was blocked")
  KB.eq(#told, 1)
end)

KB.finish("shelf and list changes made offline must be sent when the connection is back")
