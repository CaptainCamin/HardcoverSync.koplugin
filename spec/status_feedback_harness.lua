-- Status changes kept offline must not be reported as already saved to Hardcover.

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local KB = dofile(PLUGIN .. "/spec/sync_regressions/lib.lua")
KB.load_main()

local dialogs = require("hardcover/lib/ui/status_dialogs")
local Background = require("hardcover/lib/background")
local NetworkManager = require("ui/network/manager")
local messages = {}
dialogs.info = function(message) messages[#messages + 1] = message end
Background.run = function(fn) fn() end

local app = KB.new_app { state = {} }
app.markFinished = function() return true end
app.syncFileUpdates = function() return true end
app.effectiveStatusId = function() return nil end
app.cache = { updateBookStatus = function() end }

local r = KB.support.reporter()
local check = r.test

check("marking a book finished offline promises to send it when connected", function()
  KB.network.connected = false
  assert(app:markFinishedAndSay("/book.epub", "end_chosen"))
  assert(messages[#messages] == "You're offline. Your status is kept and will be sent when you're connected.",
    tostring(messages[#messages]))
end)

check("a status update from document settings uses the same offline wording", function()
  KB.network.connected = false
  app:onDocSettingsItemsChanged("/book.epub", { summary = { status = "complete" } })
  assert(messages[#messages] == "You're offline. Your status is kept and will be sent when you're connected.",
    tostring(messages[#messages]))
end)

check("online status feedback keeps its saved wording", function()
  KB.network.connected = true
  assert(app:markFinishedAndSay("/book.epub", "end_chosen"))
  assert(messages[#messages] == "Hardcover status saved", tostring(messages[#messages]))
end)

r.finish()
