-- The book details screen's flows and the reviews screen, as methods of DialogManager:
-- opening a book (saved copy offline, retry on failure), moving it between shelves,
-- rating it, putting it on lists, and the series and similar-books strips that arrive
-- after the screen is up.
--
-- They are written as methods (`self` is the DialogManager) and copied onto the class by
-- install(), so callers and tests are unchanged: `manager:chooseShelf(dialog)` still
-- works. The decisions are in book_actions.lua, lists.lua and recommendations.lua; this
-- is the orchestration that shows dialogs and sends requests.

local _ = require("gettext")
local T = require("ffi/util").template
local logger = require("logger")

local UIManager = require("ui/uimanager")
local Live = require("hardcover/lib/ui/live")

local Api = require("hardcover/lib/hardcover_api")
local Background = require("hardcover/lib/background")
local BookActions = require("hardcover/lib/book_actions")
local DeviceSearch = require("hardcover/lib/device_search")
local Home = require("hardcover/lib/home")
local Lists = require("hardcover/lib/lists")
local Network = require("hardcover/lib/network")
local OnDevice = require("hardcover/lib/on_device")
local Recommendations = require("hardcover/lib/recommendations")
local Reviews = require("hardcover/lib/reviews")
local ReviewText = require("hardcover/lib/review_text")
local Shelf = require("hardcover/lib/shelf")
local User = require("hardcover/lib/user")
local BookSources = require("hardcover/lib/book_sources")

local AuthScope = require("hardcover/lib/ui/auth_scope")
local StatusDialogs = require("hardcover/lib/ui/status_dialogs")

local scopeMissing = AuthScope.missing

local Flows = {}

--
-- Fetch and display full details for one book.
--
-- Show-then-fetch, same reason as showShelf: the detail used to be fetched
-- before the dialog existed, so a failure showed an error in place of a screen
-- and an offline tap did nothing at all.
--
-- `opts.refresh`: fetch everything again, even what the device has (the screen's reload
-- icon).
function Flows:showBookDetail(book_id, edition_id, opts)
  opts = opts or {}
  local dialog
  local on_device_file = self:deviceFile(book_id)
  dialog = require("hardcover/lib/ui/book_detail_dialog"):new {
    detail = nil,
    loading = true,
    -- the details on screen go along, so the reviews can say which book and how it is rated
    on_reviews = function(d) self:showReviews(book_id, Reviews.summary(d and d.detail)) end,
    -- the book is on this device (a file the plugin linked to it): Open. Otherwise the file search
    -- below, which is for looking further.
    on_open = on_device_file and function(d) self:openOnDevice(d, on_device_file) end or nil,
    -- KOReader's file search, with the title filled in (it is in the file manager and the reader)
    on_find = not on_device_file and DeviceSearch.available(self.ui) and function(d) self:findOnDevice(d) end or nil,
    -- only when the chosen download plugin is there: no button that does nothing
    on_zlibrary = not on_device_file and BookSources.available(self.ui, self:bookSourceChoice())
      and function(d) self:searchBookSource(d) end or nil,
    source_label = BookSources.label(self.ui, self:bookSourceChoice()),
    on_shelf = function(d) self:chooseShelf(d) end,
    -- your own review: works offline, the review waits to be sent
    on_review = function(d) self:writeReview(d) end,
    -- tapping your rating: works offline, the rating waits to be sent
    on_rating = function(d, stars) self:rateBook(d, stars) end,
    -- only when signed in with OAuth (the write scope is an OAuth thing)
    on_lists = self:canChooseLists() and function(d) self:chooseLists(d) end or nil,
    -- only for the book that is open in the reader: its link is what changes
    on_edition = self:canChangeEdition(book_id) and function(d) self:chooseEdition(d, book_id) end or nil,
    -- the reload icon: everything fetched again, the escape hatch for anything kept that
    -- has gone out of date
    on_refresh = function()
      if not Network.connected() then
        StatusDialogs.info(_("Refreshing needs an internet connection."))
        return
      end
      UIManager:close(dialog)
      self:showBookDetail(book_id, edition_id, { refresh = true })
    end,
  }

  -- the latest details screen, for a change that is sent while it is up (see shelfSent)
  self:openScreen("book", dialog)

  local user_id = User:getId()
  -- What is saved about the book, shown when the network cannot supply it: its details
  -- as last fetched, or its row from a saved list (book_store.lua), with your status and
  -- rating from the saved shelf it is on; else just the shelf's row. Looked up only when
  -- it is needed (offline, or the fetch failed): the shelf lookup reads the whole
  -- saved-shelves file, which is megabytes for a big library.
  local looked_up, found
  local function saved_detail()
    if not looked_up then
      looked_up = true
      local entry = self:findShelfEntry(user_id, book_id)
      local stored = self.book_store and self.book_store:detail(book_id, edition_id)
      if stored then
        stored.user_book_id = entry and entry.user_book_id
        stored.status_id = entry and entry.status_id
        stored.user_rating = entry and entry.user_rating
        found = stored
      elseif entry then
        found = Shelf.detailFromEntry(entry)
      end
    end
    return found
  end

  local function showSaved()
    local detail = saved_detail()
    dialog:setDetail(self:withPending(detail))
    StatusDialogs.info(_("Offline: showing saved details"))
    -- the saved series, if there is one (offline nothing is fetched)
    if detail and detail.book then self:loadSeries(dialog, detail.book, user_id) end
  end

  if not Network.connected() then
    if saved_detail() then
      showSaved()
    else
      StatusDialogs.retry(_("no internet connection"), _("Loading book details"),
        function()
          UIManager:close(dialog)
          self:showBookDetail(book_id, edition_id)
        end,
        function() UIManager:close(dialog) end)
    end
    return dialog
  end

  -- A book whose details the device has, and that is done changing (or was fetched this
  -- week), opens from the device at once: no loading line, no request for the book.
  -- Your status and rating come from the saved shelves, which Home keeps checked, and
  -- the similar-books request brings them (and the community numbers) up to date. Only
  -- when every shelf is saved can a book on none of them be taken as not in the library.
  local shelves = self:shelves()
  local settled = not opts.refresh and self.book_store and shelves
    and shelves:synced(user_id, Home.statusIds()) and self.book_store:settledDetail(book_id, edition_id)
  if settled then
    local m = shelves:member(user_id, book_id)
    settled.user_book_id = m and m.user_book_id
    settled.status_id = m and m.status_id
    settled.user_rating = m and m.rating
    dialog.similar_card = Recommendations.loadingCard(settled.book and settled.book.title)
    dialog:setDetail(self:withPending(settled))
    self:loadSeries(dialog, settled.book, user_id, function() self:loadSimilar(dialog, book_id) end)
    return dialog
  end

  local loading = StatusDialogs.loading(_("Loading book details…"))

  Api:getBookDetailAsync(book_id, user_id, edition_id, function(detail)
    StatusDialogs.close(loading)
    if not Live.shown(dialog) then return end

    if not detail then
      if saved_detail() then
        showSaved()
        return
      end

      StatusDialogs.retry(_("no response"), _("Loading book details"),
        function()
          UIManager:close(dialog)
          self:showBookDetail(book_id, edition_id)
        end,
        function() UIManager:close(dialog) end)
      return
    end

    -- kept, so the book opens offline with all of this next time
    if self.book_store then self.book_store:saveDetail(book_id, edition_id, detail) end

    -- the "Similar to" strip is there at once, empty and saying it is loading, so it is
    -- no surprise when the books arrive (and the page does not jump when they do)
    dialog.similar_card = Recommendations.loadingCard(detail.book and detail.book.title)
    dialog:setDetail(self:withPending(detail))

    -- one after the other: two requests in flight at once left one of them lost
    self:loadSeries(dialog, detail.book, user_id, function() self:loadSimilar(dialog, book_id) end,
      opts.refresh)
  end)

  return dialog
end

function Flows:bookSourceChoice()
  local ok, choice = pcall(function() return self.settings and self.settings:bookSource() end)
  return ok and choice or "auto"
end

--
-- Search for the book on screen in the chosen download plugin (Z-library, Anna's Archive or
-- Kindle Fetch: separate plugins, found by what they can do). Its own results screen opens
-- on top of this one.
function Flows:searchBookSource(dialog)
  local detail = dialog and dialog.detail
  -- the details carry authors as contributions: the summary joins them
  local summary = detail and detail.book and Shelf.detailSummary(detail) or {}
  local ok, why, label = BookSources.search(self.ui, { title = summary.title, authors = summary.authors },
    self:bookSourceChoice())
  if ok then return end

  if why == "not_installed" then
    StatusDialogs.info(T(_("The %1 plugin is not installed or not enabled."), label))
  elseif why == "no_title" then
    StatusDialogs.info(_("This book has no title to search for."))
  else
    StatusDialogs.info(T(_("Could not open the %1 search."), label))
  end
end

-- Look for the book on screen among the files on this device: KOReader's file search
-- opens on top of this screen with the title filled in, and the reader picks the folder.
-- The file of this book on the device (see on_device.lua), or nil.
function Flows:deviceFile(book_id)
  local ok, books = pcall(function() return self.settings and self.settings:readSetting("books") end)
  if not ok then return nil end
  local lfs = require("libs/libkoreader-lfs")
  return OnDevice.file(books, book_id, function(file) return lfs.attributes(file, "mode") == "file" end)
end

function Flows:openOnDevice(dialog, file)
  if dialog then UIManager:close(dialog) end
  OnDevice.open(self.ui, file)
end

function Flows:findOnDevice(dialog)
  local detail = dialog and dialog.detail
  local summary = detail and detail.book and Shelf.detailSummary(detail) or {}
  local ok, why = DeviceSearch.search(self.ui, { title = summary.title })
  if ok then return end

  if why == "no_title" then
    StatusDialogs.info(_("This book has no title to search for."))
  else
    StatusDialogs.info(_("Could not open the file search."))
  end
end

-- Other readers' reviews of a book, opened from its details screen.
--
-- Saved pages open immediately, offline too. Online, replace them with a fresh first page,
-- then save each page the reader asks for. Never mix old offsets with a refreshed ordering.
-- A failed refresh leaves the saved copy; a failed later page offers a retry.
--
function Flows:showReviews(book_id, summary)
  local store, user_id = self.review_store, User:getId()
  local saved = store and store:get(user_id, book_id)
  local online = Network.connected()
  if not online and not saved then
    StatusDialogs.info(_("No reviews saved for this book. Connect and open Reviews to save them."))
    return
  end
  local session = store and store:begin(user_id, book_id)
  summary = summary or (saved and saved.summary)
  local dialog
  local held = saved and saved.reviews or {}

  -- one page, normalised; callback(rows, err, raw_count)
  local function fetch_page(offset, limit, callback)
    if not Network.connected() then
      dialog.offline = true
      callback(nil, true)
      return
    end
    Api:getReviewsAsync(book_id, limit, offset, function(raw, err)
      local rows
      if raw then
        rows = Reviews.normalizeAll(raw)
        held = Reviews.appendPage(offset == 0 and {} or held, rows)
        if store then
          store:put(user_id, book_id, held, offset + #raw, Reviews.hasMore(#raw, limit), summary, session)
        end
      end
      -- Even a page that arrived after closing is worth keeping, but must not touch freed widgets.
      if not Live.shown(dialog) then return end

      if not raw then
        if offset == 0 and saved then
          dialog.loading = false
          dialog.cache_note = dialog.cache_note .. " " .. _("Could not refresh; showing saved reviews.")
          dialog:refresh()
          callback(nil, err or true)
          return
        end
        StatusDialogs.retry(err, _("Loading reviews"),
          function()
            if offset == 0 then
              dialog:setMessage(_("Loading reviews\226\128\166"))
              fetch_page(0, limit, function(rows, e, raw_count)
                if rows then dialog:addPage(rows, raw_count, 0) end
              end)
            else
              dialog:loadMore()
            end
          end,
          function()
            -- Without a saved copy the first page leaves nothing to look at.
            if offset == 0 then UIManager:close(dialog) end
          end)
        callback(nil, err or true)
        return
      end

      dialog.cache_note = nil
      dialog.offline = false
      callback(rows, nil, #raw)
    end)
  end

  -- Hardcover only names reviewers to apps that were granted read:users. A
  -- sign-in from before that scope was asked for (false; nil = cannot tell, as
  -- with a personal token) shows "A reader" for everyone, so say why.
  local hint
  if scopeMissing("read:users") then
    hint = _("Names are hidden: sign out and back in to see them.")
  end

  local message
  if not saved then
    message = _("Loading reviews\226\128\166")
  elseif #held == 0 and not saved.more then
    message = _("No reviews yet")
  end
  dialog = require("hardcover/lib/ui/reviews_dialog"):new {
    message = message,
    reviews = held,
    offset = saved and saved.offset or 0,
    has_more = saved and saved.more or false,
    offline = not online,
    loading = online,
    cache_note = saved and ((online and "" or _("Offline. "))
      .. T(_("Saved %1."), os.date("%Y-%m-%d %H:%M", saved.saved_at))) or nil,
    summary = summary,
    hint = hint,
    fetch_page = fetch_page,
  }
  self:openScreen(nil, dialog)

  if not online then return end
  fetch_page(0, Reviews.PAGE_SIZE, function(rows, _err, raw_count)
    dialog.loading = false
    if not rows then
      -- a failed first page: the retry above reloads it, or closes the screen
      return
    end
    dialog:addPage(rows, raw_count, 0)
  end)
end

-- Put the book on the details screen on a shelf, or take it off.
--
-- Online the change is sent at once and the screen is updated from the answer. Offline it
-- is kept in the shelf queue (shelf_queue.lua), shown at once and sent when the
-- connection is back. (Neither touches the sync queue, which is for reading progress.)
--
function Flows:chooseShelf(dialog)
  local detail = dialog.detail
  if not (detail and detail.book and detail.book.book_id) then return end

  if not Network.connected() and not self.shelf_queue then
    StatusDialogs.info(_("You are offline. Changing a shelf needs a connection."))
    return
  end

  local picker
  local rows = {}

  for _i, choice in ipairs(Shelf.statusChoices()) do
    local current = detail.status_id == choice.status_id
    rows[#rows + 1] = {
      -- the radio marks where the book is now; choosing it again does nothing
      text = _(choice.label),
      current = current,
      callback = function()
        UIManager:close(picker)
        if not current then
          self:saveShelf(dialog, choice.status_id)
        end
      end,
    }
  end

  -- a book put on a shelf offline has no library record yet, but is still removable
  local waiting = self.shelf_queue and self.shelf_queue:get(detail.book.book_id)
  if detail.user_book_id or (waiting and waiting.kind == "status") then
    rows[#rows + 1] = {
      text = _("Remove from library"),
      callback = function()
        UIManager:close(picker)
        StatusDialogs.confirm {
          text = string.format(_("Remove \"%s\" from your library? Your status, rating and reading history for it are deleted."),
            tostring(detail.book.title or "")),
          ok_text = _("Remove"),
          ok_callback = function() self:removeFromShelf(dialog) end,
        }
      end,
    }
  end

  picker = require("hardcover/lib/ui/picker").new {
    title = detail.status_id and _("Move to shelf") or _("Add to shelf"),
    rows = rows,
  }
  UIManager:show(picker)
end

-- Signed in with OAuth, so there is a sign-in whose scopes can say whether it may
-- change lists.
-- The edition is part of how a file is linked to a book, so the Edition button is for the book
-- open in the reader only (the details screen opened from a shelf or a list has no file to relink).
function Flows:canChangeEdition(book_id)
  if not (book_id and self.ui and self.ui.document and self.show_link_actions) then return false end
  return self.settings:getLinkedBookId() == book_id
end

-- Edition: the same list as the reader menu's link actions (change edition, link a different book,
-- unlink). When the list closes and the link has changed, the details are opened again for what the
-- file is linked to now.
function Flows:chooseEdition(dialog, book_id)
  local before_book, before_edition = self.settings:getLinkedBookId(), self.settings:getLinkedEditionId()
  self.show_link_actions(function()
    local book, edition = self.settings:getLinkedBookId(), self.settings:getLinkedEditionId()
    if book == before_book and edition == before_edition then return end
    UIManager:close(dialog)
    if book then self:showBookDetail(book, edition) else self:showBookDetail(book_id) end
  end)
end

function Flows:canChooseLists()
  local auth = Api.auth
  return auth ~= nil and auth:usingOAuth() and not auth:needsReauth()
end

local function listsNeedNewSignIn()
  StatusDialogs.info(_("Sign out and back in (Settings > Account) to add books to lists."), 6)
end

-- The lists screen, when it is open underneath, shows the new size of a list.
-- `unsent`: the change is waiting in the list queue, so the saved copy is not out of date
-- (it holds the change) and must not be downloaded over it. `count` may be nil (a change
-- that was sent later: the size is whatever the next download says).
function Flows:refreshListsScreen(list_id, count, unsent)
  -- the saved copy of the list is out of date now: the next look downloads it again
  if self.list_store and not unsent then self.list_store:markStale(User:getId(), list_id) end
  local screen = self:screens():open("lists")
  if not screen or count == nil then return end
  local changed = false
  for _i, row in ipairs(screen.mine or {}) do
    if row.id == list_id and row.count ~= count then
      row.count = count
      changed = true
    end
  end
  if changed then screen:rebuild() end
end

-- Put the book on the details screen on your lists, or take it off, one tick box
-- per list (a book can be on many).
--
-- Online only, like the shelf: each tap is sent at once. Which lists the book is on
-- comes from one request, kept on the details screen so opening the picker again
-- asks nothing. Where a "New list" row would go: first in the picker's rows (see
-- showListsPicker), creating the list with a name prompt, then adding the book.
--
function Flows:chooseLists(dialog)
  local detail = dialog.detail
  if not (detail and detail.book and detail.book.book_id) then return end

  -- a sign-in known to lack the scope would only fail: say what to do instead
  -- (nil, as with a personal token, is "cannot tell": try and see)
  if scopeMissing(Lists.WRITE_SCOPE) then
    listsNeedNewSignIn()
    return
  end

  if detail.lists then
    self:showListsPicker(dialog)
    return
  end

  if not Network.connected() then
    -- which lists the book is on, from the lists saved on the device
    local rows, left_out = self:savedBookLists(detail.book.book_id)
    if not rows then
      StatusDialogs.info(_("You are offline, and your lists are not saved on this device yet. Open them once online."), 5)
      return
    end
    if left_out > 0 then
      StatusDialogs.info(_("Lists that are not saved on this device are left out until you are online."), 4)
    end
    detail.lists = rows
    self:showListsPicker(dialog)
    return
  end

  local loading = StatusDialogs.loading(_("Loading your lists\226\128\166"))
  Api:getBookListsAsync(detail.book.book_id, function(rows, err)
    StatusDialogs.close(loading)
    if not Live.shown(dialog) then return end

    if not rows then
      StatusDialogs.retry(err, _("Loading your lists"),
        function() self:chooseLists(dialog) end,
        function() end)
      return
    end
    detail.lists = self:withPendingLists(rows, detail.book.book_id)
    self:showListsPicker(dialog)
  end)
end

-- Which of your lists hold the book, from the lists saved on the device (the offline
-- picker's rows, in Lists.membership's shape). A list put on or taken off while offline
-- is saved with the change, so it shows here. Returns rows and how many lists were left
-- out because the saved copy cannot say (never downloaded in full); nil when no list can
-- be shown at all.
function Flows:savedBookLists(book_id)
  local store = self.list_store
  if not store then return nil end
  local user_id = User:getId()
  local index = store:index(user_id)
  if not index then return nil end

  local rows, left_out = {}, 0
  for _i, list in ipairs(index.mine or {}) do
    local member = store:memberOf(user_id, list.id, book_id)
    if member == nil then
      left_out = left_out + 1
    else
      rows[#rows + 1] = {
        id = list.id, name = list.name, count = list.count, ranked = list.ranked, private = list.private,
        on = member and true or false, list_book_id = member and tonumber(member.list_book_id) or nil,
      }
    end
  end
  if #rows == 0 then return nil end
  return rows, left_out
end

-- Hardcover's word on which lists hold the book, with the changes still waiting to be sent
-- laid over it (the answer cannot know them yet).
function Flows:withPendingLists(rows, book_id)
  local queue = self.list_queue
  if not queue then return rows end
  for _i, r in ipairs(rows) do
    local op = queue:get(r.id, book_id)
    if op and op.kind == "add" and not r.on then
      Lists.markAdded(r, nil)
    elseif op and op.kind == "remove" and r.on then
      Lists.markRemoved(r)
    end
  end
  return rows
end

function Flows:showListsPicker(dialog)
  local detail = dialog.detail
  local book_id = detail.book.book_id
  local state = detail.lists
  if #state == 0 then
    StatusDialogs.info(_("You have no lists yet. Make one on hardcover.app and it will show up here."), 5)
    return
  end

  local Picker = require("hardcover/lib/ui/picker")
  local picker
  local open = true

  -- the details screen names the lists once the picker is done with them
  local function syncDetail()
    if Live.shown(dialog) then dialog:setLists(detail.lists) end
  end

  -- offline: kept in the list queue, shown at once, sent when the connection is back.
  -- Returns "queued", "undone" (it only cancelled a waiting change) or nil with a reason.
  local function applyOffline(r)
    local queue = self.list_queue
    local store = self.list_store
    if not (queue and store) then return nil, { message = _("you are offline") } end
    local user_id = User:getId()
    local info = { title = detail.book.title, list_name = r.name }
    local was_on = r.on
    if r.on then
      queue:queueRemove(user_id, book_id, r.id, r.list_book_id, info)
      store:removeMember(user_id, r.id, book_id)
      Lists.markRemoved(r)
    else
      queue:queueAdd(user_id, book_id, r.id, r.count, info)
      self:keepBookRow(detail)
      store:addMember(user_id, r.id, book_id)
      Lists.markAdded(r, nil)
    end
    self:refreshListsScreen(r.id, r.count, true)
    return Network.connected() and "undone" or "queued", was_on
  end

  -- Send one list's change; `finish(err)` is called once with nil when it went through.
  local function apply(r, finish)
    -- A change for this very list is still waiting: this undoes it (Hardcover never
    -- had it, so there is nothing to ask), whatever the connection.
    local waiting = self.list_queue and self.list_queue:get(r.id, book_id)
    if not Network.connected() or waiting then
      local outcome, extra = applyOffline(r)
      if not outcome then return finish(extra) end
      return finish(nil, outcome, extra)
    end

    local function sent()
      self:refreshListsScreen(r.id, r.count)
      finish(nil, "sent")
    end
    local plan = Lists.togglePlan(r)
    if plan == "add" then
      -- the end of the list: Lists.insertObject
      Api:addToListAsync(book_id, r.id, r.count, function(added, err)
        if not added then return finish(err or { message = _("no answer from Hardcover") }) end
        Lists.markAdded(r, added.id)
        sent()
      end)
      return
    end

    local function remove(list_book_id)
      Api:removeFromListAsync(list_book_id, function(removed, err)
        if not removed then return finish(err or { message = _("no answer from Hardcover") }) end
        Lists.markRemoved(r)
        sent()
      end)
    end
    if plan == "remove" then
      remove(r.list_book_id)
      return
    end
    -- added a moment ago and Hardcover's answer did not say which row it made:
    -- look it up (one request) rather than guess
    Api:getBookListsAsync(book_id, function(fresh, err)
      local outcome, list_book_id = Lists.resolveLookup(fresh, r.id)
      if outcome == "not_found" then return finish(err or { message = _("the list was not found") }) end
      if outcome == "already_off" then
        Lists.markRemoved(r) -- already off it
        return sent()
      end
      if outcome == "no_row_id" then return finish({ message = _("no answer from Hardcover") }) end
      remove(list_book_id)
    end)
  end

  -- One word for the whole batch, after the picker has closed.
  local function summarize(res)
    syncDetail()
    if #res.failed > 0 then
      if res.scope then
        listsNeedNewSignIn()
      else
        local names = {}
        for _i, f in ipairs(res.failed) do names[#names + 1] = string.format("\"%s\"", f.r.name) end
        StatusDialogs.error(string.format(_("Could not change %s: %s"), table.concat(names, ", "),
          StatusDialogs.describe(res.failed[1].err)))
      end
    elseif res.queued > 0 then
      StatusDialogs.info(res.queued == 1 and res.queued_only
        and string.format(res.queued_on and _("Offline: added to \"%s\". It will be sent when you're connected.")
          or _("Offline: removed from \"%s\". It will be sent when you're connected."), res.queued_only.name)
        or string.format(_("Offline: %d list changes will be sent when you're connected."), res.queued), 3)
    else
      StatusDialogs.info(_("Lists updated."), 2)
    end
  end

  -- Done: send every list whose tick differs from where it started, one summary at the end.
  local function done()
    if not open then return end
    open = false
    UIManager:close(picker)
    local todo = {}
    for _i, r in ipairs(state) do
      if (r.want and true or false) ~= (r.on and true or false) then todo[#todo + 1] = r end
    end
    if #todo == 0 then return syncDetail() end
    local res = { failed = {}, queued = 0 }
    local left = #todo
    for _i, r in ipairs(todo) do
      apply(r, function(err, outcome, was_on)
        if err then
          res.failed[#res.failed + 1] = { r = r, err = err }
          if Lists.isScopeError(err) then res.scope = true end
        elseif outcome == "queued" then
          res.queued, res.queued_only, res.queued_on = res.queued + 1, r, was_on == false
        end
        left = left - 1
        if left == 0 then summarize(res) end
      end)
    end
  end

  -- Back, the X or a tap outside: the ticks are thrown away, nothing was sent.
  local function discard()
    open = false
  end

  local function label(r)
    return Lists.pickerLabel(r)
  end
  local rows = {}
  for _i, r in ipairs(state) do
    r.want = r.on and true or false
    rows[#rows + 1] = {
      id = "list_" .. r.id,
      text = label(r),
      checked = r.want,
      callback = function()
        r.want = not r.want
        Picker.setRow(picker, "list_" .. r.id, label(r), true, r.want)
      end,
    }
  end
  rows[#rows + 1] = { text = _("Done"), primary = true, callback = done }

  picker = Picker.new { title = _("Add to lists"), rows = rows, close_callback = discard }
  UIManager:show(picker)
end

-- The saved shelves and counts that a change of status makes wrong.
function Flows:forgetShelves(old_status_id, new_status_id)
  if self.shelf_cache then
    self.shelf_cache:invalidate(User:getId(), BookActions.staleShelves(old_status_id, new_status_id))
  end
  require("hardcover/lib/bookshelf_sources").invalidate()
end

-- What was changed here and not sent yet (a shelf, a rating) shows in place of what is on record.
function Flows:withPending(detail)
  local shelf = self.shelf_queue
  if shelf and detail and detail.book then
    BookActions.withPendingShelf(detail, shelf:get(detail.book.book_id))
  end
  self:withPendingReview(detail)
  return self:withPendingRating(detail)
end

-- A review written offline and not yet sent shows in place of the one on record.
function Flows:withPendingReview(detail)
  local queue = self.review_queue
  local waiting = queue and detail and detail.user_book_id and queue:get(detail.user_book_id)
  return BookActions.withPendingReview(detail, waiting)
end

-- A rating set offline and not yet sent shows in place of the one on record.
function Flows:withPendingRating(detail)
  local queue = self.rating_queue
  local waiting = queue and detail and detail.user_book_id and queue:get(detail.user_book_id)
  return BookActions.withPendingRating(detail, waiting)
end

-- Rate the book on the details screen. The rating is shown at once and kept in
-- the rating queue, so it works without a connection; it is sent now if there is
-- one, or when the connection is back.
function Flows:rateBook(dialog, stars)
  local detail = dialog.detail
  local queue = self.rating_queue
  local gate = BookActions.ratingGate(detail, queue ~= nil)
  if gate == "no_book" then return end
  if gate == "needs_shelf" then
    StatusDialogs.info(_("Put this book on a shelf to rate it."))
    return
  end
  if gate == "unsent" then
    StatusDialogs.info(_("This book's shelf change has not been sent yet. You can rate it once it has."), 4)
    return
  end

  local rating = tonumber(detail.user_rating)
  require("hardcover/lib/ui/components/stepper_dialog").show {
    title = _("Set rating"),
    text = _("0 clears the rating."),
    value = stars or rating or 2.5, min = 0, max = 5, step = 0.5,
    on_save = function(value)
      queue:queue(detail.user_book_id, value, detail.book.title)
      if Live.shown(dialog) then dialog:setRating(value) end
      if Network.connected() then
        if self.flush_goals then self.flush_goals() end
      else
        StatusDialogs.info(_("You're offline. Your rating is kept and will be sent when you're connected."))
      end
    end,
  }
end

-- Write, change or remove your review on the details screen. The text is asked for first, then
-- whether it gives the story away; both are kept in the review queue, so it works without a
-- connection, and it is sent now if there is one, or when the connection is back. Empty text
-- removes the review. `on_kept(text, spoilers)` runs once it is kept (the Journal tab shows it at
-- once).
function Flows:writeReview(dialog, on_kept)
  local detail = dialog.detail
  local queue = self.review_queue
  local gate = BookActions.ratingGate(detail, queue ~= nil)
  if gate == "no_book" then return end
  if gate == "needs_shelf" then
    StatusDialogs.info(_("Put this book on a shelf to review it."))
    return
  end
  if gate == "unsent" then
    StatusDialogs.info(_("This book's shelf change has not been sent yet. You can review it once it has."), 4)
    return
  end

  local function keep(text, spoilers)
    queue:queue(detail.user_book_id, text, spoilers, detail.book.title)
    BookActions.withPendingReview(detail, { text = text, spoilers = spoilers })
    if Network.connected() then
      StatusDialogs.info(text == "" and _("Removing your review.") or _("Review saved."))
      if self.flush_goals then self.flush_goals() end
    else
      StatusDialogs.info(text == "" and _("You're offline. Removing your review is kept and will be sent when you're connected.")
        or _("You're offline. Your review is kept and will be sent when you're connected."))
    end
    if on_kept then on_kept(text, spoilers) end
  end

  local input
  input = require("hardcover/lib/ui/components/input_dialog"):new {
    title = _("Your review"),
    text = _("Leave it empty to remove your review."),
    input = detail.user_review or "",
    allow_newline = true,
    lines = 6,
    buttons = {
      { label = _("Cancel"), callback = function() UIManager:close(input) end },
      { label = _("Next"), primary = true, callback = function()
          local text = ReviewText.clean(input:getInputText())
          UIManager:close(input)
          if text == "" then
            if (detail.user_review or "") ~= "" then keep("", false) end
            return
          end
          local picker
          picker = require("hardcover/lib/ui/picker").new {
            title = _("Does it give away the story?"),
            rows = {
              { text = _("No spoilers"), current = not detail.review_spoilers,
                callback = function() UIManager:close(picker) keep(text, false) end },
              { text = _("Has spoilers"), current = detail.review_spoilers == true,
                callback = function() UIManager:close(picker) keep(text, true) end },
            },
          }
          UIManager:show(picker)
        end },
    },
  }
  UIManager:show(input)
  if input.onShowKeyboard then input:onShowKeyboard() end
end

-- A queued rating went through: the saved shelf shows the new one at once.
function Flows:ratingSent(_user_book_id, user_book)
  local shelves = self:shelves()
  if shelves and type(user_book) == "table" and user_book.book_id then
    shelves:rateBook(User:getId(), user_book.book_id, user_book.rating)
  end
  self:forgetShelves(user_book and user_book.status_id, nil)
end

-- The saved shelves and lists show a book from its saved row. A book opened with an edition
-- (from a search, say) is kept as details only, so give it a row now, or a change made
-- offline would be in the shelf or list but missing from its screen.
function Flows:keepBookRow(detail)
  local store = self.book_store
  local book = detail and detail.book
  if not (store and book and book.book_id) then return end
  if #store:missing({ book.book_id }) == 0 then return end
  local row = Shelf.normalizeEntry({ book = book })
  row.user_book_id, row.status_id, row.user_rating, row.date_added = nil, nil, nil, nil
  store:saveRows({ row })
end

-- Offline: the change is kept (shelf_queue.lua), the saved shelves and the screen show it
-- at once, and it is sent when the connection is back (see shelfSent).
function Flows:saveShelfOffline(dialog, status_id)
  local detail = dialog.detail
  local old_status_id = detail.status_id
  local request = BookActions.shelfRequest(detail, status_id)
  self:keepBookRow(detail)
  local op = self.shelf_queue:queueStatus(User:getId(), request.book_id, status_id, {
    user_book_id = detail.user_book_id, edition_id = request.edition_id, title = detail.book.title,
    from_status_id = old_status_id,
  })
  self:shelfChanged(request.book_id, old_status_id, status_id, op.user_book_id, true)
  if Live.shown(dialog) then dialog:setStatus(status_id, op.user_book_id) end
  StatusDialogs.info(_("Offline: the shelf change is kept and will be sent when you're connected."), 3)
end

function Flows:saveShelf(dialog, status_id)
  local detail = dialog.detail
  local old_status_id = detail.status_id
  local request = BookActions.shelfRequest(detail, status_id)

  if not Network.connected() and self.shelf_queue then
    self:saveShelfOffline(dialog, status_id)
    return
  end

  local loading = StatusDialogs.loading(_("Saving to your shelf…"))

  Api:updateUserBookAsync(request.book_id, request.status_id, nil, request.edition_id,
    function(user_book, err)
      StatusDialogs.close(loading)

      if not user_book then
        StatusDialogs.retry(err, _("Saving to your shelf"),
          function() self:saveShelf(dialog, status_id) end,
          function() end)
        return
      end

      -- the change happened whether or not the screen is still there; one waiting for
      -- this book from before would only undo it later
      if self.shelf_queue then self.shelf_queue:cancel(request.book_id) end
      self:shelfChanged(request.book_id, old_status_id, status_id, user_book.id or detail.user_book_id)
      if Live.shown(dialog) then
        dialog:setStatus(status_id, user_book.id or detail.user_book_id)
      end
    end)
end

function Flows:removeFromShelf(dialog)
  local detail = dialog.detail
  local old_status_id = detail.status_id
  local user_book_id = detail.user_book_id
  local book_id = detail.book and detail.book.book_id

  local waiting = self.shelf_queue and book_id and self.shelf_queue:get(book_id)
  -- offline, or a book that only went on a shelf offline (the connection may be back, but
  -- Hardcover has no record of it yet): kept, not sent
  if self.shelf_queue and book_id and (not Network.connected() or (not user_book_id and waiting)) then
    if not (user_book_id or waiting) then return end
    -- a book that only went on a shelf offline has nothing on Hardcover to remove
    local outcome = self.shelf_queue:queueRemove(User:getId(), book_id, user_book_id, detail.book.title, old_status_id)
    self:shelfChanged(book_id, old_status_id, nil, nil, true)
    if Live.shown(dialog) then dialog:setStatus(nil, nil) end
    if outcome == "dropped" then
      StatusDialogs.info(_("Taken off your shelf. It had not been sent, so nothing is left to send."), 3)
    else
      StatusDialogs.info(_("Offline: the removal is kept and will be sent when you're connected."), 3)
    end
    return
  end

  if not user_book_id then return end

  local loading = StatusDialogs.loading(_("Removing from your library…"))

  Api:removeUserBookAsync(user_book_id, function(removed, err)
    StatusDialogs.close(loading)

    if not removed then
      StatusDialogs.retry(err, _("Removing from your library"),
        function() self:removeFromShelf(dialog) end,
        function() end)
      return
    end

    if self.shelf_queue and book_id then self.shelf_queue:cancel(book_id) end
    self:shelfChanged(book_id, old_status_id, nil)
    if Live.shown(dialog) then
      dialog:setStatus(nil, nil)
    end
  end)
end

-- A shelf change made offline went through. The saved shelves are marked out of date
-- (the shelf the book left too: it is not in the queue's way any more), and the details
-- screen, if it is still up on that book, gets the library record the change made, which
-- rating needs.
function Flows:shelfSent(op, user_book)
  local user_id = User:getId()
  local shelves = self:shelves()
  if shelves and op.from_status_id then shelves:markStale(user_id, op.from_status_id) end
  local status_id = op.kind == "status" and op.status_id or nil
  local user_book_id = type(user_book) == "table" and tonumber(user_book.id) or nil
  self:shelfChanged(op.book_id, op.from_status_id, status_id, user_book_id)

  local screen = self:screens():open("book")
  local on = screen and screen.detail and screen.detail.book and screen.detail.book.book_id
  if on and tonumber(on) == tonumber(op.book_id) and screen.detail.status_id == status_id and status_id then
    screen:setStatus(status_id, user_book_id or screen.detail.user_book_id)
  end
end

-- A shelf or list change waiting to be sent was cancelled (Pending changes): the saved
-- shelves or list, the counts and the open details screen go back to what they were,
-- and the saved copies are marked out of date so Hardcover's word replaces them online.
-- `row.op` is the cancelled op.
function Flows:pendingUndone(row)
  local op = row.op or row.shelf_op
  if type(op) ~= "table" then return end
  local user_id = User:getId()

  -- a status set or a re-read started from the reader waits in the sync queue, with the shelf
  -- the book was on; a change queued before that was recorded cannot be put back
  if row.shelf_op and row.shelf_op.known == false then return end

  if row.kind == "shelf" or row.shelf_op then
    local now = op.kind == "status" and op.status_id or nil
    self:shelfChanged(op.book_id, now, op.from_status_id, op.user_book_id, true)
    local shelves = self:shelves()
    if shelves then
      if now then shelves:markStale(user_id, now) end
      if op.from_status_id then shelves:markStale(user_id, op.from_status_id) end
    end
    local screen = self:screens():open("book")
    local on = screen and screen.detail and screen.detail.book and screen.detail.book.book_id
    if on and tonumber(on) == tonumber(op.book_id) then
      screen:setStatus(op.from_status_id, op.user_book_id)
    end
    return
  end

  local store = self.list_store
  if row.kind == "list" and store then
    if op.kind == "add" then
      store:removeMember(user_id, op.list_id, op.book_id)
    else
      store:addMember(user_id, op.list_id, op.book_id)
    end
    local index = store:index(user_id)
    local count
    for _i, list in ipairs(index and index.mine or {}) do
      if list.id == op.list_id then count = list.count end
    end
    self:refreshListsScreen(op.list_id, count) -- marks the saved list out of date too
  end
end

-- A list change made offline went through: the saved copy of the list is out of date now
-- (its books' order and rows come from Hardcover), so the next look downloads it.
function Flows:listChangeSent(op, _result)
  self:refreshListsScreen(op.list_id, nil)
end

--
-- The "more in this series" card for a book's detail screen.
--
-- The screen is already showing the book; the rest of the series arrives in the
-- background and is added when it does. Tapping a row opens that book's details
-- on top of this one, so Close comes back here. Nothing is fetched offline (the
-- screen simply has no card) or for a book that is in no series.
--
-- How long a saved series is shown without asking Hardcover for it again.
local SERIES_FRESH_FOR = 7 * 24 * 3600

-- The series with your status and rating on each book from the saved shelves, which
-- are newer than the saved series (Home keeps them checked).
local function withShelfStatuses(self, series, user_id)
  local shelves = self:shelves()
  if not (shelves and shelves:synced(user_id, Home.statusIds())) then return series end
  local copy = {}
  for k, v in pairs(series) do copy[k] = v end
  copy.books = {}
  for i, b in ipairs(series.books or {}) do
    local row = {}
    for k, v in pairs(b) do row[k] = v end
    local m = shelves:member(user_id, b.book_id)
    row.status_id = m and m.status_id or nil
    row.rating = m and m.rating or nil
    copy.books[i] = row
  end
  return copy
end

-- `refresh`: ask Hardcover even if the series is saved (the screen's reload icon).
function Flows:loadSeries(dialog, book, user_id, when_done, refresh)
  local series_id = Shelf.seriesId(book)
  if not series_id then
    if when_done then when_done() end
    return
  end

  local function show(series)
    local card = series and Live.shown(dialog) and Shelf.seriesCard(series, book.book_id)
    if card then
      dialog:setSeries(card, function(book_id)
        self:showBookDetail(book_id)
      end)
    end
  end

  -- kept for a week, and shown offline
  local store = self.book_store
  local saved, saved_at
  if store then saved, saved_at = store:series(user_id, series_id) end
  local age = saved_at and ((store and store.now() or os.time()) - saved_at)
  local fresh = age and age >= 0 and age < SERIES_FRESH_FOR
  if saved and (not Network.connected() or (fresh and not refresh)) then
    show(withShelfStatuses(self, saved, user_id))
    if when_done then when_done() end
    return
  end

  if not Network.connected() then
    if when_done then when_done() end
    return
  end

  Background.run(function()
    local series = Api:getSeriesBooks(series_id, user_id)
    if series and store then store:putSeries(user_id, series_id, series) end

    -- failed, cancelled by a tap, or the screen was closed meanwhile: a saved copy will do
    show(series or (saved and withShelfStatuses(self, saved, user_id)))
    if when_done and Live.shown(dialog) then when_done() end
  end)
end

--
-- What the similar-books request said about the book on screen (see
-- Api:getSimilarBooks): your status and rating on it, kept on the saved shelves and
-- shown if they changed. The community numbers are kept for next time, but the screen
-- is not redrawn for them alone: they move a little every day, and a full redraw on
-- e-ink for that would be a flash for nothing.
--
function Flows:applyAbout(dialog, book_id, about)
  local detail = dialog.detail
  if type(about) ~= "table" or not (detail and detail.book) then return end
  local user_id = User:getId()

  if self.book_store then self.book_store:updateNumbers(book_id, about) end

  local mine = about.user_book
  local status_id = mine and tonumber(mine.status_id) or nil
  local user_book_id = mine and tonumber(mine.id) or nil
  -- a shelf change made here and not sent yet is what the screen shows, not Hardcover's
  -- older word
  local shelf_waiting = self.shelf_queue and self.shelf_queue:get(book_id)
  if not shelf_waiting and (status_id ~= detail.status_id or (status_id and user_book_id ~= detail.user_book_id)) then
    local shelves = self:shelves()
    if shelves then
      if status_id then
        shelves:moveBook(user_id, book_id, status_id, user_book_id)
      else
        shelves:removeBook(user_id, book_id)
      end
    end
    dialog:setStatus(status_id, user_book_id)
  end

  -- a rating set here and not sent yet stays on screen
  local waiting = self.rating_queue and user_book_id and self.rating_queue:get(user_book_id)
  local rating = mine and tonumber(mine.rating) or nil
  if status_id and waiting == nil and rating ~= dialog.detail.user_rating then
    local shelves = self:shelves()
    if shelves then shelves:rateBook(user_id, book_id, rating) end
    dialog:setRating(rating or 0)
  end
end

-- "Similar to <title>" on a book's details: Hardcover's ranking, fetched after the
-- screen is up (two requests, after the series) and shown as a strip of covers. An
-- empty ranking shows nothing. A failed or cancelled request is tried again by
-- Recommendations.retryPolicy; if it still fails the reader is told, so it is never
-- just missing.

function Flows:loadSimilar(dialog, book_id)
  -- (the placeholder is only there when the details were fetched online; the connection
  -- may have dropped since)
  if not Network.connected() then
    dialog:setSimilar(nil)
    return
  end
  local tries = 0
  local function attempt()
    tries = tries + 1
    Api:getSimilarBooksAsync(book_id, nil, User:getId(), function(entries, err, about)
      if not Live.shown(dialog) then return end
      if about then self:applyAbout(dialog, book_id, about) end
      if entries == nil then
        logger.warn("hardcover: similar books failed (try " .. tries .. ")", err)
        if Recommendations.retryPolicy(tries, err) == "retry" then
          UIManager:scheduleIn(2, function()
            if not Live.shown(dialog) then return end
            if Network.connected() then attempt() else dialog:setSimilar(nil) end
          end)
        else
          dialog:setSimilar(nil)
          StatusDialogs.info(_("Couldn't load similar books."))
        end
        return
      end
      local card = Recommendations.card(entries, dialog.detail and dialog.detail.book and dialog.detail.book.title)
      if not card then
        dialog:setSimilar(nil) -- no ranking for this book: the placeholder goes away
        return
      end
      dialog:setSimilar(card, function(id)
        self:showBookDetail(id)
      end)
    end)
  end
  attempt()
end

-- Copy the flows onto the class.
local function install(class)
  for name, fn in pairs(Flows) do
    class[name] = fn
  end
end

return { install = install }
