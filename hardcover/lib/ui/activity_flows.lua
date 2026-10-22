-- Your journal in the Library's Activity tab, as methods of DialogManager:
-- your status changes, notes, quotes and reviews on Hardcover, newest first.
--
-- What was last shown is kept on the device (activity_store.lua), so the tab opens at once with it,
-- offline too, with a note saying when it is from. Online, one request brings the newest page and
-- replaces it. "Load more" asks for the next page, by time (see hardcover/lib/feed.lua), online only.
-- Notes, quotes and reviews still waiting to be sent (journal_queue, review_queue) come first, marked
-- "Waiting to send".
--
-- Your note, quote or review opens in full with Edit and Delete along the bottom. Both work offline:
-- the change waits in the same queues as new writing (an entry Hardcover has gets a change or a
-- delete op, one not sent yet is changed or dropped where it waits), Activity shows it at once, Sync
-- lists it, and the saved copy takes it once Hardcover has (journalChangeSent, reviewChangeSent).
-- Copied onto the class by install(), like list_flows.lua.

local _ = require("gettext")
local T = require("ffi/util").template

local Live = require("hardcover/lib/ui/live")

local Api = require("hardcover/lib/hardcover_api")
local Feed = require("hardcover/lib/feed")
local Network = require("hardcover/lib/network")
local Reviews = require("hardcover/lib/reviews")
local User = require("hardcover/lib/user")

local AuthScope = require("hardcover/lib/ui/auth_scope")
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")

local Flows = {}

local function trim(text)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- After a change is kept: say so, and send it now if there is a connection.
local function kept(self, online_text, offline_text)
  if Network.connected() then
    StatusDialogs.info(online_text)
    if self.flush_goals then self.flush_goals() end
  else
    StatusDialogs.info(offline_text)
  end
end

-- What writeReview needs to change the review an Activity entry shows.
local function reviewDetail(entry)
  return {
    book = { book_id = entry.book_id, title = entry.title },
    user_book_id = entry.user_book_id or Feed.idOf(entry),
    user_review = entry.text,
    review_spoilers = entry.spoilers == true,
  }
end

-- What a tap on a row opens: the book for a status change, the whole text for the rest, with Edit
-- and Delete when it is yours. `changed` is called after either, so the tab shows the change.
function Flows:openActivityEntry(entry, changed)
  if entry.kind == "status" then
    if entry.book_id then self:showBookDetail(entry.book_id) end
    return
  end
  local UIManager = require("ui/uimanager")
  local mine = entry.waiting or (entry.user_id ~= nil and tonumber(entry.user_id) == tonumber(User:getId()))
  local screen
  local function done()
    UIManager:close(screen)
    if changed then changed() end
  end
  screen = require("hardcover/lib/ui/text_screen"):new {
    title = _("Activity"),
    heading = Feed.heading(entry),
    text = entry.text,
    buttons = mine and {
      { label = _("Edit"), callback = function() self:editActivityEntry(entry, done) end },
      { label = _("Delete"), callback = function() self:deleteActivityEntry(entry, done) end },
    } or nil,
  }
  UIManager:show(screen, "full")
  return screen
end

-- Change the text of your note, quote or review. A review goes through the review form.
function Flows:editActivityEntry(entry, done)
  if entry.kind == "review" then
    return self:writeReview({ detail = reviewDetail(entry) }, function() done() end)
  end
  local queue = self.journal_queue
  if not queue then return end
  local UIManager = require("ui/uimanager")
  local quote = entry.kind == "quote"
  local input
  input = require("hardcover/lib/ui/components/input_dialog"):new {
    title = quote and _("Edit quote") or _("Edit note"),
    input = entry.text or "",
    allow_newline = true,
    lines = 6,
    buttons = {
      { label = _("Cancel"), callback = function() UIManager:close(input) end },
      { label = _("Save"), primary = true, callback = function()
          local text = trim(input:getInputText())
          if text == "" then
            StatusDialogs.info(quote and _("A quote can't be empty. Use Delete to remove it.")
              or _("A note can't be empty. Use Delete to remove it."))
            return
          end
          UIManager:close(input)
          if text == entry.text then return end
          local ok
          if entry.queue_id then
            ok = queue:editWaiting(entry.queue_id, text)
          else
            ok = queue:change("update", { user_id = User:getId(), journal_id = Feed.idOf(entry),
              book_id = entry.book_id, event = entry.kind, text = text, title = entry.title }) ~= nil
          end
          if not ok then
            StatusDialogs.info(_("The change could not be saved."))
            return
          end
          kept(self, quote and _("Quote saved.") or _("Note saved."),
            _("You're offline. Your change is kept and will be sent when you're connected."))
          done()
        end },
    },
  }
  UIManager:show(input)
  if input.onShowKeyboard then input:onShowKeyboard() end
end

-- Delete your note, quote or review, after asking. One not sent yet is dropped from where it waits.
function Flows:deleteActivityEntry(entry, done)
  local review = entry.kind == "review"
  local unsent = entry.queue_id ~= nil or tostring(entry.key):find("^waiting:review:") ~= nil
  local title
  if review then
    title = unsent and _("Discard your review?") or _("Delete your review?")
  elseif entry.kind == "quote" then
    title = unsent and _("Discard this quote?") or _("Delete this quote?")
  else
    title = unsent and _("Discard this note?") or _("Delete this note?")
  end
  StatusDialogs.confirm {
    title = title,
    text = unsent and _("It has not been sent to Hardcover yet.") or _("It is removed from Hardcover."),
    ok_text = unsent and _("Discard") or _("Delete"),
    ok_callback = function()
      if review then
        local queue = self.review_queue
        if not queue then return end
        local detail = reviewDetail(entry)
        if unsent then
          queue:cancel(detail.user_book_id)
          StatusDialogs.info(_("Review discarded."))
        else
          queue:queue(detail.user_book_id, "", false, entry.title)
          kept(self, _("Removing your review."),
            _("You're offline. Removing your review is kept and will be sent when you're connected."))
        end
      else
        local queue = self.journal_queue
        if not queue then return end
        if unsent then
          queue:cancel(entry.queue_id)
          StatusDialogs.info(entry.kind == "quote" and _("Quote discarded.") or _("Note discarded."))
        elseif queue:change("delete", { user_id = User:getId(), journal_id = Feed.idOf(entry),
            book_id = entry.book_id, event = entry.kind, title = entry.title }) then
          kept(self, entry.kind == "quote" and _("Quote deleted.") or _("Note deleted."),
            _("You're offline. The delete is kept and will be sent when you're connected."))
        else
          StatusDialogs.info(_("The change could not be saved."))
          return
        end
      end
      done()
    end,
  }
end

-- Hardcover took a change to a note or quote: the saved copy shows it, offline too.
function Flows:journalChangeSent(op)
  local store = self.activity_store
  if not (store and type(op) == "table" and op.action) then return end
  local key = tostring(op.event) .. ":" .. tostring(op.journal_id)
  if op.action == "delete" then
    store:change(User:getId(), key, nil)
  elseif type(op.text) == "string" then
    local excerpt, truncated = Reviews.excerpt(op.text)
    store:change(User:getId(), key, { text = op.text, excerpt = excerpt, truncated = truncated })
  end
end

-- Hardcover took a review: the saved copy shows the new text, or loses a removed review.
function Flows:reviewChangeSent(user_book_id, text, spoilers)
  local store = self.activity_store
  if not store or user_book_id == nil then return end
  local key = "review:" .. tostring(user_book_id)
  if type(text) ~= "string" or not text:match("%S") then
    store:change(User:getId(), key, nil)
  else
    local excerpt, truncated = Reviews.excerpt(text)
    store:change(User:getId(), key, { text = text, excerpt = excerpt, truncated = truncated, spoilers = spoilers == true })
  end
end

-- Hardcover's entries as changed on this device, under what it does not have yet.
function Flows:pendingActivity(entries, user_id)
  return Feed.withPending(entries, self.journal_queue and self.journal_queue:list() or nil,
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
  -- what Hardcover has, as far as the tab knows: the saved copy, then the pages it brings
  local state = { entries = saved and saved.entries or {}, cursor = nil }
  local shown = self:pendingActivity(state.entries, me_id)

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
    select_cb = function(entry)
      self:openActivityEntry(entry, function()
        if Live.shown(dialog) then dialog:setEntries(self:pendingActivity(state.entries, me_id), dialog.has_more) end
      end)
    end,
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
    dialog:setEntries(self:pendingActivity(state.entries, me_id), more)
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

-- The journal of one book, opened from the reader panel: the same entries as Activity, for this
-- book only, on a screen of its own. Offline it shows what Activity has saved for the book and
-- what is waiting to send for it (a waiting review is known by the book's title, `title`).
function Flows:showBookJournal(book_id, title)
  self:screens():discard("book_journal")

  local online = Network.connected()
  local missing_journal = online and AuthScope.missing("read:journal")
  local me_id = User:getId()
  local store = self.activity_store
  local saved = store and store:get(me_id)

  local function ofBook(entries)
    local out = {}
    for _i, e in ipairs(entries or {}) do
      if e.book_id == tonumber(book_id) or (e.waiting and e.kind == "review" and title and e.title == title) then
        out[#out + 1] = e
      end
    end
    return out
  end
  local function withWaiting(entries)
    return ofBook(self:pendingActivity(entries, me_id))
  end
  local shown = withWaiting(ofBook(saved and saved.entries))

  local message
  if missing_journal then
    message = _("The journal needs access to your reading journal. Sign out and sign back in to allow it.")
  elseif #shown == 0 then
    message = online and _("Loading journal\226\128\166") or _("The journal needs an internet connection the first time.")
  end
  local screen
  screen = require("hardcover/lib/ui/journal_screen"):new {
    message = message, entries = shown,
    select_cb = function(entry) self:openActivityEntry(entry) end,
  }
  self:screens():track("book_journal", screen)
  require("ui/uimanager"):show(screen, "full")
  if missing_journal then return screen end

  if not online then
    if saved then
      StatusDialogs.info(T(_("Offline: showing your journal as of %1."), os.date("%b %d", saved.saved_at or os.time())))
    end
    return screen
  end

  local state = { entries = {}, cursor = nil }
  local function fetch(before, callback)
    Api:getFeedAsync({ me_id = me_id, mine = true, book_id = book_id, before = before, limit = Feed.PAGE_SIZE },
      function(page, err)
        if not page then
          return callback(nil, { message = string.format(_("Journal: %s"), StatusDialogs.describe(err)) })
        end
        callback(page, err)
      end)
  end

  local function show(more)
    local all = withWaiting(state.entries)
    if #all == 0 then
      screen:setMessage(_("Nothing in the journal for this book yet. Your status changes, notes, quotes and reviews of it will appear here."))
    else
      screen:setEntries(all, more)
    end
  end

  screen.body.more_cb = function()
    fetch(state.cursor, function(page, err)
      if not Live.shown(screen) then return end
      if not page then
        screen:setLoading(false)
        StatusDialogs.retry(err, _("Loading more of the journal"), function() screen:loadMore() end, function() end)
        return
      end
      local all, added = Feed.append(state.entries, page.entries)
      state.entries = all
      state.cursor = page.cursor or state.cursor
      show(page.more and added > 0)
    end)
  end

  fetch(nil, function(page, err)
    if not Live.shown(screen) then return end
    if not page then
      -- what is on screen from the device stays; failing to check it is not worth interrupting for
      if #shown == 0 then screen:setMessage(_("Couldn't load the journal.")) end
      return
    end
    state.entries = page.entries
    state.cursor = page.cursor
    show(page.more)
  end)
  return screen
end

-- Copy the flows onto the class.
local function install(class)
  for name, fn in pairs(Flows) do
    class[name] = fn
  end
end

return { install = install }
