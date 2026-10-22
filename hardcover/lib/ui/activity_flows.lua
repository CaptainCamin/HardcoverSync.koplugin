-- Your journal in the Library's Activity tab, as methods of DialogManager:
-- your status changes, notes, quotes and reviews on Hardcover, newest first.
--
-- Show-then-fetch: the tab opens at once saying it is loading, then one request fills it.
-- "Load more" asks for the next page, by time (see hardcover/lib/feed.lua). Nothing is saved on the device yet, so offline the tab says it needs a
-- connection. Copied onto the class by install(), like list_flows.lua.

local _ = require("gettext")

local Live = require("hardcover/lib/ui/live")

local Api = require("hardcover/lib/hardcover_api")
local Feed = require("hardcover/lib/feed")
local Network = require("hardcover/lib/network")
local User = require("hardcover/lib/user")

local AuthScope = require("hardcover/lib/ui/auth_scope")
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")

local Flows = {}

-- What a tap on a row opens: the book for a status change, the whole text for the rest.
function Flows:openActivityEntry(entry)
  if entry.kind == "status" then
    if entry.book_id then self:showBookDetail(entry.book_id) end
    return
  end
  local UIManager = require("ui/uimanager")
  UIManager:show(require("hardcover/lib/ui/text_screen"):new {
    title = _("Activity"),
    heading = Feed.heading(entry),
    text = entry.text,
  }, "full")
end

function Flows:showActivity(host)
  self:screens():discard("activity")

  local online = Network.connected()
  -- Journal reads require an explicit permission, even when library reads work.
  local missing_journal = AuthScope.missing("read:journal")
  local message
  if not online then
    message = _("Activity needs an internet connection.")
  elseif missing_journal then
    message = _("Activity needs access to your reading journal. Sign out and sign back in to allow it.")
  else
    message = _("Loading activity\226\128\166")
  end
  local dialog
  dialog = require("hardcover/lib/ui/activity_body"):new {
    shell = host and host.shell, width = host and host.width, height = host and host.height,
    parent = host and host.parent,
    message = message,
    select_cb = function(entry) self:openActivityEntry(entry) end,
  }
  self:openScreen("activity", dialog, host)
  if not online or missing_journal then return dialog end

  local state = { entries = {}, cursor = nil }
  local me_id = User:getId()

  -- Every page is restricted to the signed-in reader, including Load more.
  local function fetch(before, callback)
    Api:getFeedAsync({ me_id = me_id, mine = true, before = before, limit = Feed.PAGE_SIZE },
      function(page, err)
        if not page then
          return callback(nil, { message = string.format(_("Activity feed: %s"), StatusDialogs.describe(err)) })
        end
        callback(page, err)
      end)
  end

  dialog.more_cb = function()
    fetch(state.cursor, function(page, err)
      if not Live.shown(dialog) then return end
      if not page then
        dialog:setLoading(false)
        StatusDialogs.retry(err, _("Loading more activity"), function() dialog:loadMore() end, function() end)
        return
      end
      local all, added = Feed.append(state.entries, page.entries)
      state.entries = all
      state.cursor = page.cursor or state.cursor
      -- a page of nothing new (entries sharing one moment) cannot move on: stop asking
      dialog:setEntries(all, page.more and added > 0)
    end)
  end

  fetch(nil, function(page, err)
    if not Live.shown(dialog) then return end
    if not page then
      StatusDialogs.retry(err, _("Loading activity"),
        function()
          self:showActivity(host and { shell = host.shell, width = host.width, height = host.height,
            id = host.id, parent = host.parent, remount = true })
        end,
        self:loadFailed(dialog, host, _("Couldn't load activity.")))
      return
    end
    state.entries = page.entries
    state.cursor = page.cursor
    dialog:setEntries(page.entries, page.more)
  end)
  return dialog
end

-- Copy the flows onto the class.
local function install(class)
  for name, fn in pairs(Flows) do
    class[name] = fn
  end
end

return { install = install }
