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
local logger = require("logger")

local UIManager = require("ui/uimanager")

local Api = require("hardcover/lib/hardcover_api")
local Background = require("hardcover/lib/background")
local BookActions = require("hardcover/lib/book_actions")
local DeviceSearch = require("hardcover/lib/device_search")
local Lists = require("hardcover/lib/lists")
local Network = require("hardcover/lib/network")
local Recommendations = require("hardcover/lib/recommendations")
local Reviews = require("hardcover/lib/reviews")
local Shelf = require("hardcover/lib/shelf")
local User = require("hardcover/lib/user")
local Zlibrary = require("hardcover/lib/zlibrary")

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
function Flows:showBookDetail(book_id, edition_id)
  local dialog = require("hardcover/lib/ui/book_detail_dialog"):new {
    detail = nil,
    loading = true,
    -- the details on screen go along, so the reviews can say which book and how it is rated
    on_reviews = function(d) self:showReviews(book_id, Reviews.summary(d and d.detail)) end,
    -- KOReader's file search, with the title filled in (it is in the file manager and the reader)
    on_find = DeviceSearch.available(self.ui) and function(d) self:findOnDevice(d) end or nil,
    -- only when the Z-library plugin is there: no button that does nothing
    on_zlibrary = Zlibrary.available(self.ui) and function(d) self:searchZlibrary(d) end or nil,
    on_shelf = function(d) self:chooseShelf(d) end,
    -- tapping your rating: works offline, the rating waits to be sent
    on_rating = function(d) self:rateBook(d) end,
    -- only when signed in with OAuth (the write scope is an OAuth thing)
    on_lists = self:canChooseLists() and function(d) self:chooseLists(d) end or nil,
    -- these open on top of the details, so closing them comes back here
    on_series = function(_, name) self:searchBooks(name) end,
    on_author = function(_, name) self:searchBooks(name) end,
    on_status = function(_, status_id) self:showShelf(status_id, Shelf.statusLabel(status_id)) end,
  }

  UIManager:show(dialog)

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
      local entry = self.shelf_cache and self.shelf_cache:findEntry(user_id, book_id)
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
    dialog:setDetail(self:withPendingRating(saved_detail()))
    StatusDialogs.info(_("Offline: showing saved details"))
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

  local loading = StatusDialogs.loading(_("Loading book details…"))

  Api:getBookDetailAsync(book_id, user_id, edition_id, function(detail)
    StatusDialogs.close(loading)
    if not UIManager:isWidgetShown(dialog) then return end

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
    dialog:setDetail(self:withPendingRating(detail))

    -- one after the other: two requests in flight at once left one of them lost
    self:loadSeries(dialog, detail.book, user_id, function() self:loadSimilar(dialog, book_id) end)
  end)

  return dialog
end

--
-- Search for the book on screen in the Z-library plugin (a separate plugin, found
-- by what it can do). Its own results screen opens on top of this one.
function Flows:searchZlibrary(dialog)
  local detail = dialog and dialog.detail
  -- the details carry authors as contributions: the summary joins them
  local summary = detail and detail.book and Shelf.detailSummary(detail) or {}
  local ok, why = Zlibrary.search(self.ui, { title = summary.title, authors = summary.authors })
  if ok then return end

  if why == "not_installed" then
    StatusDialogs.info(_("The Z-library plugin is not installed or not enabled."))
  elseif why == "no_title" then
    StatusDialogs.info(_("This book has no title to search for."))
  else
    StatusDialogs.info(_("Could not open the Z-library search."))
  end
end

-- Look for the book on screen among the files on this device: KOReader's file search
-- opens on top of this screen with the title filled in, and the reader picks the folder.
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
-- Nothing is fetched until this is called, and then one request per page of
-- ten (Reviews.PAGE_SIZE): the API allows 60 a minute. Show-then-fetch, like
-- the shelves: the list appears at once saying it is loading. Offline there is
-- nothing to wait for, so say so and open nothing. A failed page offers a retry
-- instead of a dead end.
--
function Flows:showReviews(book_id, summary)
  if not Network.connected() then
    StatusDialogs.info(_("Reviews need an internet connection"))
    return
  end

  local dialog

  -- one page, normalised; callback(rows, err, raw_count)
  local function fetch_page(offset, limit, callback)
    Api:getReviewsAsync(book_id, limit, offset, function(raw, err)
      if not UIManager:isWidgetShown(dialog) then return end

      if not raw then
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
            -- giving up on the first page leaves nothing to look at
            if offset == 0 then UIManager:close(dialog) end
          end)
        callback(nil, err or true)
        return
      end

      callback(Reviews.normalizeAll(raw), nil, #raw)
    end)
  end

  -- Hardcover only names reviewers to apps that were granted read:users. A
  -- sign-in from before that scope was asked for (false; nil = cannot tell, as
  -- with a personal token) shows "A reader" for everyone, so say why.
  local hint
  if scopeMissing("read:users") then
    hint = _("Names are hidden: sign out and back in to see them.")
  end

  dialog = require("hardcover/lib/ui/reviews_dialog"):new {
    message = _("Loading reviews\226\128\166"),
    summary = summary,
    hint = hint,
    fetch_page = fetch_page,
  }
  UIManager:show(dialog)

  fetch_page(0, Reviews.PAGE_SIZE, function(rows, _err, raw_count)
    if not rows then
      -- a failed first page: the retry above reloads it, or closes the screen
      return
    end
    dialog:addPage(rows, raw_count, 0)
  end)
end

-- Put the book on the details screen on a shelf, or take it off.
--
-- Online only: the change is sent at once and the screen is updated from the
-- answer, so offline there is nothing honest to show. (It does not touch the
-- offline sync queue, which is for reading progress.)
--
function Flows:chooseShelf(dialog)
  local detail = dialog.detail
  if not (detail and detail.book and detail.book.book_id) then return end

  if not Network.connected() then
    StatusDialogs.info(_("You are offline. Changing a shelf needs a connection."))
    return
  end

  local picker
  local rows = {}

  for _i, choice in ipairs(Shelf.statusChoices()) do
    local current = detail.status_id == choice.status_id
    rows[#rows + 1] = {
      -- a bullet marks where the book is now; choosing it again does nothing
      text = (current and "\226\128\162 " or "") .. _(choice.label),
      current = current,
      callback = function()
        UIManager:close(picker)
        if not current then
          self:saveShelf(dialog, choice.status_id)
        end
      end,
    }
  end

  if detail.user_book_id then
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

  rows[#rows + 1] = {
    text = _("Cancel"),
    callback = function() UIManager:close(picker) end,
  }

  picker = require("hardcover/lib/ui/picker").new {
    title = detail.status_id and _("Move to shelf") or _("Add to shelf"),
    rows = rows,
  }
  UIManager:show(picker)
end

-- Signed in with OAuth, so there is a sign-in whose scopes can say whether it may
-- change lists.
function Flows:canChooseLists()
  local auth = Api.auth
  return auth ~= nil and auth:usingOAuth() and not auth:needsReauth()
end

local function listsNeedNewSignIn()
  StatusDialogs.info(_("Sign out and back in (Settings > Account) to add books to lists."), 6)
end

-- The lists screen, when it is open underneath, shows the new size of a list.
function Flows:refreshListsScreen(list_id, count)
  -- the saved copy of the list is out of date now: the next look downloads it again
  if self.list_store then self.list_store:markStale(User:getId(), list_id) end
  local screen = self:screens():open("lists")
  if not screen then return end
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

  if not Network.connected() then
    StatusDialogs.info(_("You are offline. Changing a list needs a connection."))
    return
  end

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

  local loading = StatusDialogs.loading(_("Loading your lists\226\128\166"))
  Api:getBookListsAsync(detail.book.book_id, function(rows, err)
    StatusDialogs.close(loading)
    if not UIManager:isWidgetShown(dialog) then return end

    if not rows then
      StatusDialogs.retry(err, _("Loading your lists"),
        function() self:chooseLists(dialog) end,
        function() end)
      return
    end
    detail.lists = rows
    self:showListsPicker(dialog)
  end)
end

function Flows:showListsPicker(dialog)
  local detail = dialog.detail
  local book_id = detail.book.book_id
  local state = detail.lists
  if #state == 0 then
    StatusDialogs.info(_("You have no lists yet. Make one on hardcover.app and it will show up here."), 5)
    return
  end

  local picker
  local open = true

  -- the details screen names the lists once the picker is done with them
  local function syncDetail()
    if UIManager:isWidgetShown(dialog) then dialog:setLists(detail.lists) end
  end
  local function close()
    if not open then return end
    open = false
    UIManager:close(picker)
    syncDetail()
  end

  local function redraw(r)
    require("hardcover/lib/ui/picker").setRow(picker, "list_" .. r.id, Lists.pickerLabel(r), not r.busy)
  end
  local function changed(r)
    r.busy = nil
    redraw(r)
    self:refreshListsScreen(r.id, r.count)
    if not open then syncDetail() end -- the answer came after the picker was closed
  end
  -- the tick stays as it was; say why
  local function failed(r, err)
    r.busy = nil
    redraw(r)
    if Lists.isScopeError(err) then
      listsNeedNewSignIn()
    else
      StatusDialogs.error(string.format(_("Could not change \"%s\": %s"), r.name, StatusDialogs.describe(err)))
    end
  end

  local function toggle(r)
    if r.busy then return end
    if not Network.connected() then
      StatusDialogs.info(_("You are offline. Changing a list needs a connection."))
      return
    end
    r.busy = true
    redraw(r)

    local plan = Lists.togglePlan(r)
    if plan == "add" then
      -- the end of the list: Lists.insertObject
      Api:addToListAsync(book_id, r.id, r.count, function(added, err)
        if not added then return failed(r, err) end
        Lists.markAdded(r, added.id)
        changed(r)
      end)
      return
    end

    local function remove(list_book_id)
      Api:removeFromListAsync(list_book_id, function(removed, err)
        if not removed then return failed(r, err) end
        Lists.markRemoved(r)
        changed(r)
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
      if outcome == "not_found" then return failed(r, err or { message = _("the list was not found") }) end
      if outcome == "already_off" then
        Lists.markRemoved(r) -- already off it
        return changed(r)
      end
      if outcome == "no_row_id" then return failed(r, { message = _("no answer from Hardcover") }) end
      remove(list_book_id)
    end)
  end

  local rows = {}
  for _i, r in ipairs(state) do
    rows[#rows + 1] = {
      id = "list_" .. r.id,
      text = Lists.pickerLabel(r),
      callback = function() toggle(r) end,
    }
  end
  rows[#rows + 1] = { text = _("Done"), callback = close }

  picker = require("hardcover/lib/ui/picker").new {
    title = _("Add to lists"),
    rows = rows,
    close_callback = function()
      open = false
      syncDetail()
    end,
  }
  UIManager:show(picker)
end

-- The saved shelves and counts that a change of status makes wrong.
function Flows:forgetShelves(old_status_id, new_status_id)
  if not self.shelf_cache then return end
  self.shelf_cache:invalidate(User:getId(), BookActions.staleShelves(old_status_id, new_status_id))
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
function Flows:rateBook(dialog)
  local detail = dialog.detail
  local queue = self.rating_queue
  local gate = BookActions.ratingGate(detail, queue ~= nil)
  if gate == "no_book" then return end
  if gate == "needs_shelf" then
    StatusDialogs.info(_("Put this book on a shelf to rate it."))
    return
  end

  local rating = tonumber(detail.user_rating)
  local SpinWidget = require("ui/widget/spinwidget")
  UIManager:show(SpinWidget:new {
    ok_always_enabled = rating == nil,
    value = rating or 2.5,
    value_min = 0,
    value_max = 5,
    value_step = 0.5,
    value_hold_step = 2,
    precision = "%.1f",
    ok_text = _("Save"),
    title_text = _("Set Rating"),
    -- 0 clears the rating
    callback = function(spin)
      queue:queue(detail.user_book_id, spin.value, detail.book.title)
      if UIManager:isWidgetShown(dialog) then dialog:setRating(spin.value) end
      if Network.connected() then
        if self.flush_goals then self.flush_goals() end
      else
        StatusDialogs.info(_("You're offline. Your rating is kept and will be sent when you're connected."))
      end
    end,
  })
end

-- A queued rating went through: the saved shelves show the old one.
function Flows:ratingSent(_user_book_id, user_book)
  self:forgetShelves(user_book and user_book.status_id, nil)
end

function Flows:saveShelf(dialog, status_id)
  local detail = dialog.detail
  local old_status_id = detail.status_id
  local request = BookActions.shelfRequest(detail, status_id)

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

      -- the change happened whether or not the screen is still there
      self:forgetShelves(old_status_id, status_id)
      if UIManager:isWidgetShown(dialog) then
        dialog:setStatus(status_id, user_book.id or detail.user_book_id)
      end
    end)
end

function Flows:removeFromShelf(dialog)
  local detail = dialog.detail
  local old_status_id = detail.status_id
  local user_book_id = detail.user_book_id
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

    self:forgetShelves(old_status_id, nil)
    if UIManager:isWidgetShown(dialog) then
      dialog:setStatus(nil, nil)
    end
  end)
end

--
-- The "more in this series" card for a book's detail screen.
--
-- The screen is already showing the book; the rest of the series arrives in the
-- background and is added when it does. Tapping a row opens that book's details
-- on top of this one, so Close comes back here. Nothing is fetched offline (the
-- screen simply has no card) or for a book that is in no series.
--
function Flows:loadSeries(dialog, book, user_id, when_done)
  local series_id = Shelf.seriesId(book)
  if not series_id or not Network.connected() then
    if when_done then when_done() end
    return
  end

  Background.run(function()
    local series = Api:getSeriesBooks(series_id, user_id)

    -- failed, cancelled by a tap, or the screen was closed meanwhile
    local card = series and UIManager:isWidgetShown(dialog) and Shelf.seriesCard(series, book.book_id)
    if card then
      dialog:setSeries(card, function(book_id)
        self:showBookDetail(book_id)
      end)
    end
    if when_done and UIManager:isWidgetShown(dialog) then when_done() end
  end)
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
    Api:getSimilarBooksAsync(book_id, function(entries, err)
      if not UIManager:isWidgetShown(dialog) then return end
      if entries == nil then
        logger.warn("hardcover: similar books failed (try " .. tries .. ")", err)
        if Recommendations.retryPolicy(tries, err) == "retry" then
          UIManager:scheduleIn(2, function()
            if not UIManager:isWidgetShown(dialog) then return end
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
