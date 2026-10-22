-- The Activity tab of the Library, as methods of DialogManager: what you and the readers you follow
-- lately did on Hardcover (status changes, notes, quotes, reviews), newest first.
--
-- Show-then-fetch: the tab opens at once saying it is loading, then one request (two the first time:
-- who you follow, then the page) fills it. "Load more" asks for the next page, by time (see
-- hardcover/lib/feed.lua). Nothing is saved on the device yet, so offline the tab says it needs a
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
  -- Older OAuth sign-ins predate the social scopes. The rest of the plugin can still
  -- work with such a token, but Activity cannot read follows, journal entries or reviews.
  local missing_social = AuthScope.missing("read:social") or AuthScope.missing("read:users")
  local message
  if not online then
    message = _("Activity needs an internet connection.")
  elseif missing_social then
    message = _("Activity needs access to social activity. Sign out and sign back in to allow it.")
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
  if not online or missing_social then return dialog end

  local state = { followed = nil, entries = {}, cursor = nil }
  local me_id = User:getId()

  -- one page at or before `before` (nil: the newest); callback(page, err). Who is followed is
  -- asked once and kept for the later pages.
  local function fetch(before, callback)
    local function ask(ids)
      Api:getFeedAsync({ me_id = me_id, user_ids = ids, before = before, limit = Feed.PAGE_SIZE },
        function(page, err)
          if not page then
            return callback(nil, { message = string.format(_("Activity feed: %s"), StatusDialogs.describe(err)) })
          end
          callback(page, err)
        end)
    end
    if state.followed then return ask(state.followed) end
    Api:getFollowedIdsAsync(function(ids, err)
      if not ids then
        return callback(nil, { message = string.format(_("Followed readers: %s"), StatusDialogs.describe(err)) })
      end
      state.followed = ids
      ask(ids)
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
