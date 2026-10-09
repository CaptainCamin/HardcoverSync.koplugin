-- Shelves, as methods of DialogManager: a shelf's books, keeping every shelf saved on
-- the device, and keeping the saved shelves right when a book is moved, rated or removed
-- here.
--
-- Everything is saved (shelf_store.lua, book_store.lua) and opens from there at once,
-- offline too. Hardcover is asked only whether a shelf changed: Home does it for all of
-- them in the request it already makes for the counts, and a shelf screen asks again (one
-- small request) only when Home has not in the last few minutes. A shelf is downloaded
-- again only when it changed, and then only which books it holds plus the books the
-- device lacks. Shelf requests go through the same queue as the lists (list_flows.lua).
--
-- Copied onto the class by install(), like book_flows.lua.

local _ = require("gettext")

local UIManager = require("ui/uimanager")

local Api = require("hardcover/lib/hardcover_api")
local Background = require("hardcover/lib/background")
local Home = require("hardcover/lib/home")
local Network = require("hardcover/lib/network")
local ShelfLoader = require("hardcover/lib/shelf_loader")
local ShelvesSync = require("hardcover/lib/shelves_sync")
local User = require("hardcover/lib/user")

local SETTING = require("hardcover/lib/constants/settings")

local StatusDialogs = require("hardcover/lib/ui/status_dialogs")

local Flows = {}

-- The shelf store, or nil when this manager has none (a test's).
function Flows:shelves()
  return self.book_store and self.shelf_store or nil
end

-- Carry the shelves an earlier version saved over to the shelf store, once a session.
function Flows:convertShelves()
  local store = self:shelves()
  if self._shelves_converted or not store then return end
  self._shelves_converted = true
  store:convert(User:getId(), self.shelf_cache, Home.statusIds())
end

-- The book as a shelf entry, from the saved shelves, or nil when it is on none of them.
function Flows:findShelfEntry(user_id, book_id)
  local store = self:shelves()
  local entry = store and store:findEntry(user_id, book_id)
  if entry then return entry end
  -- not carried over yet: what an earlier version saved
  return self.shelf_cache and self.shelf_cache:findEntry(user_id, book_id) or nil
end

--
-- Download shelf `status_id` and save it, through the lists' queue. `opts`:
--   fingerprint  Hardcover's, from a check just made (Home's)
--   check        ask Hardcover first (one small request) and download only if it changed
--   front, force, on_page, on_done   as for downloadList
--
function Flows:downloadShelf(status_id, opts)
  opts = opts or {}
  local store = self:shelves()
  local user_id = User:getId()
  local queue = self:listsQueue()
  local key = "shelf:" .. tostring(status_id) .. (opts.force and ":refresh" or "")
  local alive = function() return not self.closed end
  queue:wait(key, opts.on_done)
  queue:add({
    key = key,
    work = function()
      local fingerprint = opts.fingerprint
      if opts.check and store then
        local _counts, _err, prints = ShelfLoader.patient(function()
          return Api:getShelfCounts(user_id, { status_id })
        end, Background.sleep)
        fingerprint = prints and prints[status_id]
        local meta = store:meta(user_id, status_id)
        if fingerprint and not ShelvesSync.needsDownload(meta, fingerprint) then
          store:markChecked(user_id, status_id)
          return { complete = true, unchanged = true }
        end
      end
      return ShelvesSync.download {
        api = Api,
        shelves = store,
        books = self.book_store,
        user_id = user_id,
        status_id = status_id,
        fingerprint = fingerprint,
        alive = alive,
        sleep = Background.sleep,
        network = Network,
        force = opts.force,
        on_page = opts.on_page,
      }
    end,
  }, opts.front)
  queue:start()
end

--
-- Home's check: `prints` are the shelves' fingerprints from the counts request Home
-- makes anyway. A shelf whose fingerprint matches what is saved is noted as checked;
-- the others are downloaded (membership only, when saved before). Called at the end of
-- Home's refresh, in the same background block, after the lists.
--
function Flows:checkShelves(prints)
  local store = self:shelves()
  if not store or type(prints) ~= "table" then return end
  self:convertShelves()
  -- what Download covers for offline says is missing is counted again
  self._covers_missing = nil
  local user_id = User:getId()
  for _, status_id in ipairs(Home.statusIds()) do
    local fingerprint = prints[status_id]
    if fingerprint then
      if ShelvesSync.needsDownload(store:meta(user_id, status_id), fingerprint) then
        self:downloadShelf(status_id, { fingerprint = fingerprint })
      else
        store:markChecked(user_id, status_id)
      end
    end
  end
end

-- The shelves' fingerprints if every one was checked in the last few minutes, else nil.
function Flows:freshPrints()
  local store = self:shelves()
  if not store then return nil end
  local user_id, prints = User:getId(), {}
  for _, status_id in ipairs(Home.statusIds()) do
    local meta = store:meta(user_id, status_id)
    if not ShelvesSync.fresh(meta, store.now()) then return nil end
    prints[status_id] = meta.fingerprint
  end
  return prints
end

-- The shelf screen's title-bar order, remembered per shelf.
local function sortKey(self, status_id)
  local choices = self.settings:readSetting(SETTING.SHELF_SORT)
  return type(choices) == "table" and choices[tostring(status_id)] or nil
end

--
-- One shelf's books. The saved copy is on screen at once; if Hardcover's fingerprint for
-- the shelf is the one it was saved with (Home asked a moment ago, or one small request
-- now), nothing else is fetched. Otherwise the shelf is downloaded (only what it gained,
-- when it was saved before) and replaces it.
--
function Flows:showShelf(status_id, title)
  local user_id = User:getId()
  local store = self:shelves()

  self:screens():discard("shelf")
  self:convertShelves()

  local saved_entries, meta
  if store then saved_entries, meta = store:entries(user_id, status_id) end

  local dialog
  local refresh

  dialog = require("hardcover/lib/ui/shelf_dialog"):new {
    compatibility_mode = self.settings:compatibilityMode(),
    title = title,
    status_id = status_id,
    sortable = true,
    sort_key = sortKey(self, status_id),
    on_sort_change = function(key)
      local saved = self.settings:readSetting(SETTING.SHELF_SORT)
      saved = type(saved) == "table" and saved or {}
      saved[tostring(status_id)] = key
      self.settings:updateSetting(SETTING.SHELF_SORT, saved)
    end,
    -- Empty until something is shown. Passing a nil here would reach the API as a nil
    -- offset and silently refetch page one forever.
    entries = {},
    has_more = false,
    offset = 0,
    page_size = ShelfLoader.PAGE_SIZE,
    -- the menu's "Load the rest of the list", after an interrupted download: the whole
    -- shelf comes through the queue, and what this screen lacks is appended
    fetch_page = function(offset, _limit, callback)
      if not Network.connected() then
        callback(nil, _("not available offline"))
        return
      end
      self:downloadShelf(status_id, {
        front = true,
        on_done = function(result)
          if not (result and result.complete and result.entries) then
            callback(nil, result and result.failure or _("no response"))
            return
          end
          local rest = {}
          for i = offset + 1, #result.entries do rest[#rest + 1] = result.entries[i] end
          callback(rest, nil, false)
        end,
      })
    end,
    select_entry_cb = function(entry)
      self:showBookDetail(entry.book_id)
    end,
    actions = store and {
      { text = _("Refresh"), callback = function() refresh() end },
    } or nil,
  }
  self:screens():track("shelf", dialog)
  UIManager:show(dialog)

  local function show(entries, complete)
    if complete and #entries == 0 then
      dialog:setEmptyState(_("No books on this shelf yet"))
      return
    end
    dialog.offset = #entries
    dialog:setEntries(entries, not complete, true)
  end

  -- download it all again, books included: the escape hatch for anything the
  -- fingerprint did not catch
  refresh = function()
    if not Network.connected() then
      StatusDialogs.info(_("Refreshing needs an internet connection."))
      return
    end
    local loading = StatusDialogs.loading(_("Refreshing your shelf\226\128\166"))
    self:downloadShelf(status_id, {
      front = true,
      force = true,
      check = false,
      on_done = function(result)
        StatusDialogs.close(loading)
        if not UIManager:isWidgetShown(dialog) then return end
        if result and result.complete then
          show(result.entries, true)
        else
          StatusDialogs.info(_("Couldn't refresh the shelf."))
        end
      end,
    })
  end

  if saved_entries and (#saved_entries > 0 or meta.complete) then
    show(saved_entries, meta.complete)
  end

  -- Offline there is nothing to wait for: say what is being shown and stop.
  if not Network.connected() then
    if meta then
      StatusDialogs.info(string.format(_("Offline: showing your list as it was on %s"),
        os.date("%Y-%m-%d", meta.saved_at or os.time())))
    else
      StatusDialogs.retry(_("no internet connection"), _("Loading your shelf"),
        function() self:showShelf(status_id, title) end,
        function() end)
    end
    return
  end

  -- Home asked a moment ago and the shelf is as saved: nothing to fetch at all
  if store and ShelvesSync.fresh(meta, store.now()) then return end

  -- With a saved shelf on screen the check is quiet; without one the reader is waiting
  -- on it, so say so.
  local loading = not saved_entries and StatusDialogs.loading(_("Loading your shelf\226\128\166")) or nil
  local function stopLoading()
    if loading then
      StatusDialogs.close(loading)
      loading = nil
    end
  end

  self:downloadShelf(status_id, {
    front = true,
    check = store ~= nil,
    -- rows appear as pages arrive when there is nothing saved to show
    on_page = not meta and function(fresh)
      stopLoading()
      if UIManager:isWidgetShown(dialog) then
        dialog.offset = #fresh
        dialog:setEntries(fresh, true, true)
      end
    end or nil,
    on_done = function(result)
      stopLoading()
      if not UIManager:isWidgetShown(dialog) then return end
      if result and result.unchanged then return end
      if result and result.complete then
        show(result.entries or {}, true)
        return
      end
      -- a saved copy, or part of the shelf, is on screen: keep it (the menu can carry on)
      if saved_entries or (result and #(result.entries or {}) > 0) then return end
      StatusDialogs.retry(result and result.failure, _("Loading your shelf"),
        function() self:showShelf(status_id, title) end,
        function() end)
    end,
  })
end

--
-- A book's status changed here (moved to `status_id`, or out of the library when nil):
-- the saved shelves show it at once, and are asked about again next time. What changes
-- with a shelf on Home (the counts, the reading list) and in Stats is forgotten as
-- before.
--
function Flows:shelfChanged(book_id, old_status_id, status_id, user_book_id)
  local store = self:shelves()
  local user_id = User:getId()
  if store then
    if status_id then
      store:moveBook(user_id, book_id, status_id, user_book_id)
    else
      store:removeBook(user_id, book_id)
    end
  end
  self:forgetShelves(old_status_id, status_id)
end

-- Copy the flows onto the class.
local function install(class)
  for name, fn in pairs(Flows) do
    class[name] = fn
  end
end

return { install = install }
