-- Your journal in the Library's Activity tab, as methods of DialogManager:
-- your status changes, notes, quotes and reviews on Hardcover, newest first.
--
-- What was last shown is kept on the device (activity_store.lua), so the tab opens at once with it,
-- offline too, with a note saying when it is from. Online, one request brings the newest page and
-- replaces it. "Load more" asks for the next page, by time (see hardcover/lib/feed.lua), online only.
-- Notes, quotes and reviews still waiting to be sent (journal_queue, review_queue) come first, marked
-- "Waiting to send". Copied onto the class by install(), like list_flows.lua.

local _ = require("gettext")
local T = require("ffi/util").template

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

-- What you wrote that is still on the device, to show above what Hardcover has.
function Flows:waitingActivity(user_id)
  return Feed.waiting(self.journal_queue and self.journal_queue:list() or nil,
    self.review_queue and self.review_queue:list() or nil, user_id)
end

function Flows:showActivity(host)
  self:screens():discard("activity")

  local online = Network.connected()
  -- Journal reads require an explicit permission, even when library reads work.
  local missing_journal = online and AuthScope.missing("read:journal")
  local me_id = User:getId()
  local store = self.activity_store
  local saved = store and store:get(me_id)
  local shown = Feed.withWaiting(self:waitingActivity(me_id), saved and saved.entries)

  local message
  if missing_journal then
    message = _("Activity needs access to your reading journal. Sign out and sign back in to allow it.")
  elseif #shown == 0 and not saved then
    message = online and _("Loading activity\226\128\166") or _("Activity needs an internet connection the first time.")
  end
  local dialog
  dialog = require("hardcover/lib/ui/activity_body"):new {
    shell = host and host.shell, width = host and host.width, height = host and host.height,
    parent = host and host.parent,
    message = message,
    -- Load more appears once Hardcover has answered: a page asked for before then would be
    -- replaced by the first page when it arrives
    entries = shown, has_more = false,
    select_cb = function(entry) self:openActivityEntry(entry) end,
  }
  self:openScreen("activity", dialog, host)
  -- saved, and there was nothing in it: say so, as an empty answer does
  if not message and #shown == 0 then dialog:setEntries({}, false) end
  if missing_journal then return dialog end

  if not online then
    if saved then
      StatusDialogs.info(T(_("Offline: showing your activity as of %1."), os.date("%b %d", saved.saved_at or os.time())))
    elseif #shown > 0 then
      StatusDialogs.info(_("Offline: showing what is waiting to send. The rest needs a connection."))
    end
    return dialog
  end

  local state = { entries = {}, cursor = nil }

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

  -- show (and keep) what is held now, under what is still waiting to send
  local function show(more)
    if store then store:put(me_id, state.entries, more) end
    dialog:setEntries(Feed.withWaiting(self:waitingActivity(me_id), state.entries), more)
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
      show(page.more and added > 0)
    end)
  end

  fetch(nil, function(page, err)
    if not Live.shown(dialog) then return end
    if not page then
      -- what is saved is still on screen: failing to check it is not worth interrupting for
      if saved then return end
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
    show(page.more)
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
