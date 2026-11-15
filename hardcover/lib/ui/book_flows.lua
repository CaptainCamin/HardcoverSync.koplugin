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
local BookSyncState = require("hardcover/lib/book_sync_state")
local DeviceSearch = require("hardcover/lib/device_search")
local Home = require("hardcover/lib/home")
local Lists = require("hardcover/lib/lists")
local Network = require("hardcover/lib/network")
local PendingStatus = require("hardcover/lib/pending_status")
local ReadHistory = require("hardcover/lib/read_history")
local OnDevice = require("hardcover/lib/on_device")
local Recommendations = require("hardcover/lib/recommendations")
local Reviews = require("hardcover/lib/reviews")
local ReviewText = require("hardcover/lib/review_text")
local Shelf = require("hardcover/lib/shelf")
local _t = require("hardcover/lib/table_util")
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
    on_reviews = function(d)
      self:showReviews(book_id, Reviews.summary(d and d.detail),
        d and d.detail and self:reviewMine(d.detail, book_id) or nil, d)
    end,
    -- this book has a question waiting: one visible way to answer it here. The question is looked
    -- up when the note is tapped, so a decision that arrives with the details is the one shown.
    on_decision = function(d)
      local decision = d and d.sync_state and d.sync_state.decision
      if not decision then
        decision = self.sync_queue and self.sync_queue.decisionForBook
          and self.sync_queue:decisionForBook(book_id, User:getId())
      end
      if decision then self:reviewDecision(decision) end
    end,
    -- the reading row opens the history; the shelf chip changes the shelf, and the stars rate it
    on_reads = function(d) self:showReadHistory(d) end,
    state_opts = {
      queues = { sync_queue = self.sync_queue, rating_queue = self.rating_queue, review_queue = self.review_queue },
      book_id = book_id, user_id = User:getId(),
    },
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
    -- reads are user data, so they live in their own store rather than in the book's details
    if self.read_store and detail.reads then self.read_store:put(user_id, book_id, detail.reads) end

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

-- Answer the question about this book from its details screen: one question, and
-- Back or "Decide later" leaves it waiting.
function Flows:reviewDecision(decision)
  require("hardcover/lib/ui/sync_conflict_dialog").show {
    decision = decision,
    on_done = function(resolved, choice, outcome)
      if resolved == 0 then return end
      if outcome and outcome.kind == "shelf" then self:removalKept(outcome) end
      if outcome and outcome.kind == "combine" then
        self:combineReview(outcome)
        return
      end
      local offline = not Network.connected()
      StatusDialogs.info(offline and choice ~= "keep_hardcover"
        and _("Choice saved; will check Hardcover when connected.") or _("Choice saved."), 2)
      self:refreshBookState(decision.book_id)
      if not offline and self.flush_goals then self.flush_goals() end
    end,
  }
end

-- A review conflict answered with Combine: both versions open in the ordinary editor, each
-- under its own heading. The queue keeps the online text as this draft's baseline, so saving
-- it does not ask the same question again unless Hardcover changes once more.
function Flows:combineReview(outcome)
  local online = outcome.online or {}
  local device = outcome.device or {}
  local text = online.text == device.text and device.text
    or T(_("Hardcover:\n%1\n\nThis device:\n%2"), online.text or "", device.text or "")
  self:writeReview({
    detail = {
      user_book_id = outcome.user_book_id,
      book = { book_id = outcome.book_id, title = outcome.title },
      user_review = text,
      review_spoilers = online.spoilers == true or device.spoilers == true,
      review_known = true,
    },
  })
end

-- Keeping a book after a removal question: the queued removal had already taken it out
-- of the saved shelves. Put it back where Hardcover has it, with its rating, and clear
-- the unsent-removal marker so a later download cannot keep hiding it.
function Flows:removalKept(op)
  if type(op) ~= "table" or not tonumber(op.book_id) or not op.status_id then return end
  local user_id = User:getId()
  self:shelfChanged(op.book_id, nil, op.status_id, op.user_book_id, false)
  local shelves = self:shelves()
  if shelves and op.rating ~= nil then
    shelves:rateBook(user_id, op.book_id, op.rating)
  end
  local screen = self:screens():open("book")
  local on = screen and screen.detail and screen.detail.book and screen.detail.book.book_id
  if on and tonumber(on) == tonumber(op.book_id) then
    screen:setStatus(op.status_id, op.user_book_id)
    -- setStatus clears the rating with the shelf; the book was kept, so put its rating
    -- back too (a rating set offline and not sent is still what the reader chose).
    local waiting = self.rating_queue
      and self.rating_queue:get(op.user_book_id, op.book_id, user_id)
    if waiting ~= nil then
      screen:setRating(waiting)
    elseif op.rating ~= nil then
      screen:setRating(op.rating)
    end
  end
end

-- Hardcover confirmed values for the book open on its details screen. A removal baseline
-- must include edits it has accepted, but never the overlays of edits still waiting.
-- `opts.status` / `opts.rating` say which fields this answer settles; `opts.book_id` is for
-- an answer that names the library record but not the catalog book.
function Flows:rememberServerDetail(user_book, opts)
  if type(user_book) ~= "table" then return end
  opts = opts or {}
  local book_id = tonumber(opts.book_id or user_book.book_id)
  local screen = self:screens():open("book")
  local detail = screen and screen.detail
  local on = detail and detail.book and tonumber(detail.book.book_id)
  local base = detail and detail._server_base
  if not (book_id and on == book_id and base) then return end
  if opts.status and user_book.status_id ~= nil then
    base.status_id, base.status_known = tonumber(user_book.status_id), true
  end
  if opts.rating then
    -- updateRating answers with the rating as well, nil when it was cleared
    base.user_rating, base.rating_known = tonumber(user_book.rating), true
  end
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

-- The reader's own rating and review, for the combined reviews page: the details are already
-- overlaid with this device's pending rating and review, and the queue supplies their state.
function Flows:reviewMine(detail, book_id)
  local state = BookSyncState.forBook({
    sync_queue = self.sync_queue, rating_queue = self.rating_queue, review_queue = self.review_queue,
  }, book_id, detail.user_book_id, User:getId())
  local mine = {
    rating = detail.user_rating, text = detail.user_review, spoilers = detail.review_spoilers,
    posted_at = detail.review_posted_at and ReadHistory.dateText(detail.review_posted_at, 1) or nil,
    review_id = detail.review_id or detail.user_book_id,
    rating_state = state.rating_state, review_state = state.review_state,
  }
  if mine.review_state == _("Waiting to send") then mine.review_state = _("Saved on this device") end
  -- A spoiler clash stays warned about until the reader answers, whichever side asked for
  -- the warning.
  local review_decision = self.review_queue and self.review_queue.decisionForBook
    and self.review_queue:decisionForBook(book_id, User:getId(), detail.user_book_id)
  local conflict = review_decision and review_decision.entry and review_decision.entry.conflict
  if conflict and conflict.kind == "review"
      and (conflict.online.spoilers == true or conflict.proposed.spoilers == true) then
    mine.spoilers = true
  end
  return mine
end

-- Other readers' reviews of a book, opened from its details screen. The top of the page is the
-- reader's own rating and review, then the community list. Saved pages open immediately, offline
-- too. Online, replace them with a fresh first page, then save each page the reader asks for.
-- Never mix old offsets with a refreshed ordering. A failed refresh leaves the saved copy; a
-- failed later page offers a retry.
--
function Flows:showReviews(book_id, summary, mine, detail_dialog)
  local store, user_id = self.review_store, User:getId()
  local saved = store and store:get(user_id, book_id)
  local online = Network.connected()
  if not online and not saved and not mine then
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
    message = online and _("Loading reviews\226\128\166") or _("No community reviews saved.")
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
    mine = mine,
    on_rating = detail_dialog and function(stars)
      self:rateBook(detail_dialog, stars, function(value)
        if dialog then
          dialog:setMine({ rating = value, rating_state = _("Waiting to send") })
        end
      end)
    end or nil,
    on_review = detail_dialog and function()
      self:writeReview(detail_dialog, function(text, spoilers)
        if dialog then
          dialog:setMine({ text = text, spoilers = spoilers,
            review_state = text ~= "" and _("Saved on this device") or false })
        end
      end)
    end or nil,
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

-- The words for one queued read edit, at the start of its row: what will change and that it is
-- waiting. A question, a request in flight and a held older read keep the queue's own words.
local function readStateText(action)
  if action.kind == "remove_read" then return _("Removal waiting to send") end
  if action.kind == "add_read" then return _("Read waiting to send") end
  local fields = {}
  if (action.change and action.change.started_at) or (action.clear and action.clear.started_at) then
    fields[#fields + 1] = _("Start date")
  end
  if (action.change and (action.change.finished_at or action.change.finished_at_precision))
    or (action.clear and (action.clear.finished_at or action.clear.finished_at_precision)) then
    fields[#fields + 1] = _("Finish date")
  end
  if (action.change and action.change.edition_id) or (action.clear and action.clear.edition_id) then
    fields[#fields + 1] = _("Edition")
  end
  if (action.change and action.change.progress_pages) or (action.clear and action.clear.progress_pages) then
    fields[#fields + 1] = _("Page")
  end
  if #fields == 1 then return T(_("%1 waiting to send"), fields[1]) end
  if #fields > 1 then return _("Changes waiting to send") end
  return _("Change waiting to send")
end

-- [read id] = { text, kind } for the history rows: a state replaces the row's format and pages.
function Flows:readStates(actions)
  local states = {}
  for _i, action in ipairs(actions or {}) do
    local id = action.read_id or action.local_id
    if id ~= nil then
      local state
      if action.conflict then
        state = { text = _("Needs your decision"), kind = "decision" }
      elseif action.checking then
        state = { text = _("Checking what synced"), kind = "checking" }
      elseif action.wait then
        state = { text = _("Waiting for the current read to finish"), kind = "waiting" }
      else
        state = { text = readStateText(action), kind = "waiting" }
      end
      states[id] = state
      states[tostring(id)] = state
    end
  end
  return states
end

local function readBase(read)
  local base = {}
  for _i, field in ipairs({ "started_at", "finished_at", "finished_at_precision", "edition_id",
    "progress_pages" }) do
    base[field] = read and read[field] or nil
  end
  return base
end

-- The edition rows the saved reads already name, for the picker when there is no connection.
local function editionsFromReads(reads)
  local out, seen = {}, {}
  for _i, read in ipairs(reads or {}) do
    local edition = read.edition
    local id = edition and (edition.edition_id or edition.id)
    if id and not seen[tostring(id)] then
      seen[tostring(id)] = true
      out[#out + 1] = {
        edition_id = tonumber(id), pages = tonumber(edition.pages),
        edition_format = ReadHistory.formatName({ edition = edition }),
        reading_format_id = tonumber(edition.reading_format_id),
        audio_seconds = tonumber(edition.audio_seconds),
        title = read.title,
      }
    end
  end
  return out
end

-- Put a current read's chosen edition on the link at once, so pages turned from now on are in
-- the new edition's units and wait behind the edition action. Cancelling puts the old one back.
function Flows:applyEditionLink(file, edition, edition_id)
  if not (file and self.settings and self.settings.updateBookSetting) then return end
  local pages = type(edition) == "table" and tonumber(edition.pages) or nil
  local format = type(edition) == "table" and ReadHistory.formatName({ edition = edition }) or nil
  local update = { edition_id = edition_id, pages = pages, edition_format = format }
  local delete = {}
  for _, key in ipairs({ "edition_id", "pages", "edition_format" }) do
    if update[key] == nil then delete[#delete + 1] = key end
  end
  if #delete > 0 then update._delete = delete end
  self.settings:updateBookSetting(file, update)
  if self.state and self.state.book_status then self.state.book_status.edition_id = edition_id end
end

function Flows:restoreEditionLink(op)
  local file = op.file or (op.book_id and self:deviceFile(op.book_id))
  if not (file and self.settings and self.settings.updateBookSetting) then return end
  local update = { edition_id = op.old_edition_id, pages = op.old_pages, edition_format = op.old_format }
  local delete = {}
  for _, key in ipairs({ "edition_id", "pages", "edition_format" }) do
    if update[key] == nil then delete[#delete + 1] = key end
  end
  if #delete > 0 then update._delete = delete end
  self.settings:updateBookSetting(file, update)
  if self.state and self.state.book_status and self.settings.getLinkedBookId
    and tonumber(self.settings:getLinkedBookId()) == tonumber(op.book_id) then
    self.state.book_status.edition_id = op.old_edition_id
  end
end

-- One read's edition picker. Online it asks Hardcover (audiobooks included) and keeps the rows
-- for offline; offline it lists the editions saved with the reads. No rows means no picker.
function Flows:chooseReadEdition(context, read, on_choose)
  local book_id, user_id = tonumber(context.book_id), User:getId()
  local saved = self.read_store and self.read_store:get(user_id, book_id)
  local offline_editions = saved and saved.editions
  if type(offline_editions) ~= "table" or #offline_editions == 0 then
    offline_editions = editionsFromReads(saved and saved.reads or context.reads)
  end
  if not Network.connected() and #offline_editions == 0 then
    StatusDialogs.info(_("Connect once to choose a different edition."))
    return
  end

  self:buildLoadingSearchDialog(_("Select edition"), function(done)
    if Network.connected() then
      Api:findEditionsAsync(book_id, user_id, true, function(editions, err)
        if editions and self.read_store then
          self.read_store:putEditions(user_id, book_id, editions)
        end
        done(editions, err)
      end)
    else
      done(offline_editions, nil)
    end
  end, { edition_id = read.edition_id }, function(row)
    on_choose(row.book or row)
  end, nil, read.title, true)
end

-- The saved reads with the queued edits laid over them, and each queued read's words.
function Flows:readHistoryProjection(context)
  local actions = self.sync_queue and self.sync_queue.readActions
    and self.sync_queue:readActions(context.book_id) or {}
  local reads = context.reads
  if reads ~= nil then reads = ReadHistory.project(reads, actions) end
  return reads, self:readStates(actions)
end

function Flows:refreshReadHistory(history)
  if not (history and history.context) then return end
  local reads, states = self:readHistoryProjection(history.context)
  history:setData(reads, states, history.context.checked_at)
end

-- Recompute everything the book's page says comes from the queues: a waiting rating or review,
-- a read in flight, and the one decision. Keeps the cover and scroll position.
function Flows:refreshBookState(book_id)
  local screen = self:screens():open("book")
  local on = screen and screen.detail and screen.detail.book and screen.detail.book.book_id
  if on and tonumber(on) == tonumber(book_id) and screen.refreshState then screen:refreshState() end
  local history = self:screens():open("reads")
  if history and tonumber(history.book_id) == tonumber(book_id) then self:refreshReadHistory(history) end
end

-- The reading history screen, from the details page. Its rows are the saved reads with this
-- device's queued edits laid over them; offline the saved copy is all there is. With no saved copy
-- and a connection, ask once before showing the screen.
function Flows:showReadHistory(dialog)
  local detail = dialog and dialog.detail
  local book = detail and detail.book
  if not (book and book.book_id) then return end
  local user_id, book_id = User:getId(), tonumber(book.book_id)
  local saved = self.read_store and self.read_store:get(user_id, book_id)
  self:openReadHistoryWhenAvailable {
    book = book, book_id = book_id, user_book_id = detail.user_book_id, detail = detail, screen = dialog,
    reads = detail.reads or (saved and saved.reads), checked_at = saved and saved.checked_at,
  }
end

-- Reading history from the reader panel's gear, for the book open on the device. The panel's
-- cached record is enough to draw the rows; a fresh copy arrives when the panel next checks.
function Flows:showLinkedReadHistory(opts)
  opts = opts or {}
  local book_id = tonumber(self.settings and self.settings:getLinkedBookId())
  if not book_id then return end
  local user_id = User:getId()
  local status = self.state and self.state.book_status or {}
  local saved = self.read_store and self.read_store:get(user_id, book_id)
  local context = {
    book = { book_id = book_id, title = self.settings:getLinkedTitle() or tostring(book_id),
      pages = self.settings.pages and self.settings:pages() or nil,
      edition_format = self.settings.getLinkedEditionFormat and self.settings:getLinkedEditionFormat() or nil },
    book_id = book_id, user_book_id = status.id, edit_current = opts.edit_current == true,
    reads = status.user_book_reads or (saved and saved.reads), checked_at = saved and saved.checked_at,
  }
  self:openReadHistoryWhenAvailable(context)
end

function Flows:openReadHistoryWhenAvailable(context)
  if context.reads ~= nil or not Network.connected() then
    return self:openReadHistory(context)
  end
  local loading = StatusDialogs.loading(_("Loading reading history…"))
  Api:getBookDetailAsync(context.book_id, User:getId(), nil, function(detail)
    StatusDialogs.close(loading)
    if not (detail and detail.reads) then
      StatusDialogs.info(_("Couldn't load this book's reading history. Try again."))
      return
    end
    context.reads = detail.reads
    context.checked_at = os.time()
    context.user_book_id = context.user_book_id or detail.user_book_id
    if context.detail then
      context.detail.reads = detail.reads
      context.detail.user_book_id = context.detail.user_book_id or detail.user_book_id
    end
    if self.read_store then self.read_store:put(User:getId(), context.book_id, detail.reads) end
    self:openReadHistory(context)
  end)
end

function Flows:openReadHistory(context)
  self:screens():discard("reads")
  local reads, states = self:readHistoryProjection(context)
  local history
  history = require("hardcover/lib/ui/read_history_dialog"):new {
    book = context.book, book_id = context.book_id, reads = reads, states = states,
    checked_at = context.checked_at,
    on_open_read = function(read)
      self:editRead(context, history, read)
    end,
    on_add = function() self:addRead(context, history) end,
  }
  history.context = context
  self:openScreen("reads", history)
  if context.edit_current then
    local current = ReadHistory.current(history.reads)
    if current then self:editRead(context, history, current) end
  end
  return history
end

-- The form for one read. Save queues a sparse date edit and leaves the history showing it at once;
-- offline the edit waits with the rest of the book's changes.
function Flows:editRead(context, history, read)
  local book_id, user_id = tonumber(context.book_id), User:getId()
  local current = context.reads and ReadHistory.current(context.reads)
  local is_current = current and tostring(current.id) == tostring(read.id)
  local adding = read.pending_add == true
  local form
  local function on_save(change, clear, chosen_edition)
    local file = self:deviceFile(book_id)
    local edition_change = tonumber(change.edition_id)
    local old_pages = ReadHistory.editionPages(read) or tonumber(context.book and context.book.pages)
    local old_format = ReadHistory.formatName(read, context.book and context.book.edition_format)
    local new_pages = chosen_edition and tonumber(chosen_edition.pages) or nil
    local new_format = chosen_edition and ReadHistory.formatName({ edition = chosen_edition }) or nil
    local payload = {
      kind = adding and "add_read" or (edition_change and "read_edition" or "read_dates"),
      user_id = user_id, book_id = book_id,
      user_book_id = context.user_book_id or (context.detail and context.detail.user_book_id),
      title = context.book and context.book.title,
      edition_id = context.book and context.book.edition_id,
      read_id = not adding and read.id or nil,
      local_id = adding and read.id or nil,
      base = readBase(read), change = change, clear = clear,
      file = file, edition = chosen_edition,
    }
    if adding then
      payload.change.edition_id = change.edition_id or (chosen_edition and chosen_edition.edition_id)
    elseif edition_change then
      payload.current = is_current == true
      payload.target_edition_id = edition_change
      payload.target_page = tonumber(change.progress_pages)
      payload.old_edition_id = tonumber(read.edition_id or (read.edition and read.edition.id))
      payload.old_pages = old_pages
      payload.old_format = old_format
      payload.new_pages = new_pages
      payload.edition_format = new_format
      payload.edition = chosen_edition
    end
    local entry = self.sync_queue and self.sync_queue.enqueueReadEdit and self.sync_queue:enqueueReadEdit(
      file or book_id, payload)
    if not entry then
      StatusDialogs.info(_("Could not keep this change. Try again."))
      return
    end
    if edition_change and is_current and chosen_edition and not adding then
      self:applyEditionLink(file, chosen_edition, edition_change)
    end
    form:close()
    if history then self:refreshReadHistory(history) end
    if context.screen then context.screen:refreshState() end
    if Network.connected() then
      if self.flush_goals then self.flush_goals() end
    else
      StatusDialogs.info(_("You're offline. This change is kept and will be sent when you're connected."))
    end
  end
  local add_action
  if adding and self.sync_queue then
    for _i, action in ipairs(self.sync_queue:readActions(book_id)) do
      if action.kind == "add_read" and tostring(action.local_id) == tostring(read.id) then
        add_action = action
        break
      end
    end
  end
  form = require("hardcover/lib/ui/read_edit_dialog"):new {
    book = context.book, read = read, on_save = on_save,
    choose_edition = function(edition_id, callback)
      self:chooseReadEdition(context, read, callback)
    end,
    on_remove = function()
      if adding and add_action and self.sync_queue then
        self.sync_queue:cancelReadEdit(book_id, add_action.seq, user_id, self.sync_queue:get(book_id))
      else
        self:removeRead(context, history, read)
      end
      if history then self:refreshReadHistory(history) end
      if context.screen then context.screen:refreshState() end
    end,
  }
  UIManager:show(form, "full")
end

function Flows:addRead(context, history)
  local book_id, user_id = tonumber(context.book_id), User:getId()
  local current = context.reads and ReadHistory.current(context.reads)
  local default_edition = current and current.edition or nil
  if not default_edition and context.book and context.book.edition_id then
    default_edition = { edition_id = context.book.edition_id, pages = context.book.pages,
      edition_format = context.book.edition_format }
  end
  local form
  local function on_save(change, clear, chosen_edition)
    local edition = chosen_edition or default_edition
    if edition and not change.edition_id then change.edition_id = edition.edition_id end
    local entry = self.sync_queue and self.sync_queue:enqueueReadEdit(
      self:deviceFile(book_id) or book_id, {
        kind = "add_read", user_id = user_id, book_id = book_id,
        user_book_id = context.user_book_id or (context.detail and context.detail.user_book_id),
        title = context.book and context.book.title, change = change, clear = clear,
        edition = edition, file = self:deviceFile(book_id),
      })
    if not entry then
      StatusDialogs.info(_("Could not keep this read. Try again."))
      return
    end
    form:close()
    if history then self:refreshReadHistory(history) end
    if context.screen then context.screen:refreshState() end
    if Network.connected() then
      if self.flush_goals then self.flush_goals() end
    else
      StatusDialogs.info(_("You're offline. This read is kept and will be sent when you're connected."))
    end
  end
  form = require("hardcover/lib/ui/read_edit_dialog"):new {
    book = context.book, adding = true, default_edition = default_edition, on_save = on_save,
    choose_edition = function(edition_id, callback)
      self:chooseReadEdition(context, current or {}, callback)
    end,
  }
  UIManager:show(form, "full")
end

function Flows:removeRead(context, history, read)
  local book_id, user_id = tonumber(context.book_id), User:getId()
  local entry = self.sync_queue and self.sync_queue:enqueueReadEdit(
    self:deviceFile(book_id) or book_id, {
      kind = "remove_read", user_id = user_id, book_id = book_id,
      user_book_id = context.user_book_id or (context.detail and context.detail.user_book_id),
      title = context.book and context.book.title, read_id = read.id, base = readBase(read),
      file = self:deviceFile(book_id),
    })
  if not entry then
    StatusDialogs.info(_("Could not remove this read. Try again."))
    return
  end
  if history then self:refreshReadHistory(history) end
  if context.screen then context.screen:refreshState() end
  if Network.connected() then
    if self.flush_goals then self.flush_goals() end
  else
    StatusDialogs.info(_("You're offline. The removal is kept and will be sent when you're connected."))
  end
end

-- A read edit reached Hardcover: save what it answered, and refresh the open history and page.
function Flows:readSent(book_id, user_book, _op)
  local user_id = User:getId()
  local reads = type(user_book) == "table" and user_book.user_book_reads or nil
  if reads and self.read_store then self.read_store:put(user_id, tonumber(book_id), reads) end

  local screen = self:screens():open("book")
  local on = screen and screen.detail and screen.detail.book and screen.detail.book.book_id
  if on and tonumber(on) == tonumber(book_id) then
    if reads then screen.detail.reads = reads end
    if screen.refreshState then screen:refreshState() end
  end

  local history = self:screens():open("reads")
  if history and tonumber(history.book_id) == tonumber(book_id) and history.context then
    if reads then history.context.reads = reads end
    history.context.checked_at = os.time()
    self:refreshReadHistory(history)
  end
end

-- Put the book on the details screen on a shelf, or take it off.
--
-- Online the change is sent at once and the screen is updated from the answer. Offline it
-- is kept (see saveShelfOffline), shown at once and sent when the connection is back.
--
function Flows:chooseShelf(dialog)
  local detail = dialog.detail
  if not (detail and detail.book and detail.book.book_id) then return end

  if not Network.connected() and not self.sync_queue then
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
  local waiting = self.sync_queue and self.sync_queue:shelfOp(detail.book.book_id, User:getId())
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

-- Edition: change edition or unlink this device from the book. When the list closes and the link has
-- changed, the details are opened again for what the file is linked to now.
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
  -- What Hardcover (or the saved copy) said before any offline overlay below. A removal
  -- asked for from this screen must compare against this, not against the reader's own
  -- not-yet-sent rating, review or shelf change.
  if detail and detail.book and not detail._server_base then
    detail._server_base = {
      status_id = detail.status_id, user_rating = detail.user_rating,
      rating_known = detail.rating_known,
      user_review = detail.user_review, review_spoilers = detail.review_spoilers,
      review_known = detail.review_known,
    }
  end
  if self.sync_queue and detail and detail.book then
    BookActions.withPendingShelf(detail,
      PendingStatus.get(self.sync_queue, detail.book.book_id, User:getId()))
  end
  self:withPendingReview(detail)
  return self:withPendingRating(detail)
end

-- A review written offline and not yet sent shows in place of the one on record.
function Flows:withPendingReview(detail)
  local queue = self.review_queue
  local waiting = queue and detail and queue:get(detail.user_book_id, detail.book and detail.book.book_id, User:getId())
  return BookActions.withPendingReview(detail, waiting)
end

-- A rating set offline and not yet sent shows in place of the one on record.
function Flows:withPendingRating(detail)
  local queue = self.rating_queue
  local waiting = queue and detail and queue:get(detail.user_book_id, detail.book and detail.book.book_id, User:getId())
  return BookActions.withPendingRating(detail, waiting)
end

-- Rate the book on the details screen. The rating is shown at once and kept in
-- the rating queue, so it works without a connection; it is sent now if there is
-- one, or when the connection is back.
function Flows:rateBook(dialog, stars, on_set)
  local detail = dialog.detail
  local queue = self.rating_queue
  local gate = BookActions.ratingGate(detail, queue ~= nil)
  if gate == "no_book" then return end
  if gate == "needs_shelf" then
    StatusDialogs.info(_("Put this book on a shelf to rate it."))
    return
  end

  local rating = tonumber(detail.user_rating)
  require("hardcover/lib/ui/components/stepper_dialog").show {
    title = _("Set rating"),
    text = _("0 clears the rating."),
    value = stars or rating or 2.5, min = 0, max = 5, step = 0.5,
    on_save = function(value)
      queue:queue(detail.user_book_id, value, detail.book.title, detail.book.book_id, User:getId(),
        BookActions.ratingBase(detail))
      if Live.shown(dialog) then dialog:setRating(value) end
      if on_set then on_set(value) end
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
  -- A pending review can be edited from the journal before its library record is known.
  if gate == "needs_shelf" and not (queue and queue:get(detail.user_book_id, detail.book.book_id, User:getId())) then
    StatusDialogs.info(_("Put this book on a shelf to review it."))
    return
  end

  -- A book opened from the device's saved copy has your status and rating but not your review:
  -- ask Hardcover for it, or the editor would open empty and saving would replace the review.
  local waiting = queue and queue:get(detail.user_book_id, detail.book.book_id, User:getId())
  if detail.user_book_id and not detail.review_known and not waiting and Network.connected() then
    local loading = StatusDialogs.loading(_("Loading your review…"))
    Api:getBookDetailAsync(detail.book.book_id, User:getId(), nil, function(fresh)
      StatusDialogs.close(loading)
      if not fresh then
        StatusDialogs.info(_("Couldn't load your review. Try again."))
        return
      end
      detail.user_review, detail.review_spoilers = fresh.user_review, fresh.review_spoilers
      detail.review_known = true
      if self.read_store and fresh.reads then
        self.read_store:put(User:getId(), detail.book.book_id, fresh.reads)
      end
      self:editReview(dialog, on_kept)
    end)
    return
  end
  self:editReview(dialog, on_kept)
end

function Flows:editReview(dialog, on_kept)
  local detail = dialog.detail
  local queue = self.review_queue

  local function keep(text, spoilers)
    queue:queue(detail.user_book_id, text, spoilers, detail.book.title, detail.book.book_id, User:getId(),
      BookActions.reviewBase(detail))
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
  self:rememberServerDetail(user_book, { status = true, rating = true })
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

-- Offline: the change is kept in the progress queue with the book's pages (see sync_queue.lua), so they
-- are sent in the order they were made. The saved shelves and the screen show it at once, and it is
-- sent when the connection is back (see shelfSent).
function Flows:saveShelfOffline(dialog, status_id)
  local detail = dialog.detail
  local old_status_id = detail.status_id
  local request = BookActions.shelfRequest(detail, status_id)
  self:keepBookRow(detail)
  -- by file when the book is on this device, else by book
  local entry = self.sync_queue:enqueueStatus(self:deviceFile(request.book_id) or request.book_id, {
    user_id = User:getId(), book_id = request.book_id, edition_id = request.edition_id,
    title = detail.book.title, user_book_id = detail.user_book_id,
    status_id = status_id, from_status_id = old_status_id,
  })
  local user_book_id = entry and entry.user_book_id
  self:shelfChanged(request.book_id, old_status_id, status_id, user_book_id, true)
  if Live.shown(dialog) then dialog:setStatus(status_id, user_book_id) end
  StatusDialogs.info(_("Offline: the shelf change is kept and will be sent when you're connected."), 3)
end

function Flows:saveShelf(dialog, status_id)
  local detail = dialog.detail
  local old_status_id = detail.status_id
  local request = BookActions.shelfRequest(detail, status_id)

  if self.sync_queue and (not Network.connected() or self.sync_queue:hasPending(request.book_id)) then
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

      -- A change queued while the request was out is newer and must remain queued.
      self:rememberServerDetail(user_book, { status = true })
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

  local waiting = self.sync_queue and book_id and self.sync_queue:shelfOp(book_id, User:getId())
  -- What this device last knew of the record, so a later replay can tell whether Hardcover
  -- gained work the reader never saw. Use the values before `withPending` laid the reader's
  -- own not-yet-sent shelf, rating and review changes over them.
  local server = detail._server_base or detail
  local queued = self.sync_queue and book_id and self.sync_queue:get(book_id)
  local status = self.state and self.state.book_status or {}
  -- The reader's open book is not necessarily this one; only use its reads when it is.
  if status.book_id ~= nil and detail.book and tonumber(status.book_id) ~= tonumber(detail.book.book_id) then
    status = {}
  end
  if status.id ~= nil and user_book_id ~= nil and tonumber(status.id) ~= tonumber(user_book_id) then
    status = {}
  end
  -- A queued page has already been laid over the open book's saved reads. Use the last
  -- synced snapshot instead, so the reader's own offline page is not mistaken for an
  -- online change.
  local reads = type(status.user_book_reads) == "table" and status.user_book_reads or nil
  local reads_known = type(reads) == "table"
  if (queued and queued.mapped_page ~= nil) or not reads then
    local file = book_id and self:deviceFile(book_id)
    local snapshot = file and self.settings and self.settings.bookStatusFromSnapshot
      and self.settings:bookStatusFromSnapshot(file) or nil
    if snapshot and type(snapshot.user_book_reads) == "table" then
      reads, reads_known = snapshot.user_book_reads, true
    elseif queued and queued.mapped_page ~= nil then
      reads, reads_known = nil, false
    end
  end
  -- A queued status has already moved the saved shelf; its `from_status_id` is the shelf
  -- Hardcover still has.
  local online_status = server.status_id
  if waiting and waiting.kind == "status" and waiting.from_status_id ~= nil then
    online_status = waiting.from_status_id
  end
  local base = {
    status_id = online_status,
    status_known = online_status ~= nil,
    rating = server.user_rating,
    rating_known = true,
    review_raw = server.user_review,
    review_has_spoilers = server.review_spoilers,
    review_known = server.review_known == true,
    reads = self.sync_queue and self.sync_queue.readSignature
      and reads and self.sync_queue.readSignature(reads) or nil,
    reads_known = reads_known and self.sync_queue and self.sync_queue.readSignature ~= nil,
  }
  -- offline, or a book that only went on a shelf offline (the connection may be back, but
  -- Hardcover has no record of it yet): kept, not sent
  if self.sync_queue and book_id and (not Network.connected() or (not user_book_id and waiting)) then
    if not (user_book_id or waiting) then return end
    -- a book that only went on a shelf offline has nothing on Hardcover to remove
    local outcome = self.sync_queue:queueRemove(User:getId(), book_id, user_book_id, detail.book.title,
      old_status_id, base, self:deviceFile(book_id))
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

    if self.sync_queue and book_id then self.sync_queue:cancelStatus(book_id) end
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
  self:rememberServerDetail(user_book, { status = true })
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

  -- An edition change puts the new edition on the link at once (pages turned afterwards are in
  -- its units); cancelling before it is sent puts the old edition and page count back.
  if row.kind == "read" and op.kind == "read_edition" and op.current then
    self:restoreEditionLink(op)
    return
  end

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
  local copy = _t.copy(series)
  copy.books = {}
  for i, b in ipairs(series.books or {}) do
    local row = _t.copy(b)
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
  -- Refresh is also what Hardcover has: keep a later removal comparison current.
  self:rememberServerDetail(mine, { book_id = book_id, status = true, rating = true })
  local status_id = mine and tonumber(mine.status_id) or nil
  local user_book_id = mine and tonumber(mine.id) or nil
  -- a shelf change made here and not sent yet is what the screen shows, not Hardcover's
  -- older word
  local shelf_waiting = self.sync_queue and self.sync_queue:shelfOp(book_id, User:getId())
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
  local waiting = self.rating_queue and self.rating_queue:get(user_book_id, book_id, user_id)
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
