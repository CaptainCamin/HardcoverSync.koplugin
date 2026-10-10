-- Optional Bookshelf shelf sources backed by Hardcover Sync's own library.
--
-- The source hooks only return cached records. Network work is started on the
-- next UI tick and Bookshelf is told when a newer page has landed.

local _ = require("gettext")
local logger = require("logger")
local Api = require("hardcover/lib/hardcover_api")
local Background = require("hardcover/lib/background")
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local Network = require("hardcover/lib/network")
local ShelfLoader = require("hardcover/lib/shelf_loader")
local User = require("hardcover/lib/user")
local SETTING = require("hardcover/lib/constants/settings")

local UIManager = require("ui/uimanager")

local Sources = {}
local WANT_TO_READ_ID = "hardcover_wtr"
local SHELVES_ID = "hardcover_shelf"
local LISTS_ID = "hardcover_lists"
local SHELF_SOURCES = {
  { id = WANT_TO_READ_ID, label = "Hardcover: Want to Read", choice = "Want to Read", status = HARDCOVER.STATUS.TO_READ },
  { id = "hardcover_reading", label = "Hardcover: Currently Reading", choice = "Currently Reading", status = HARDCOVER.STATUS.READING },
  { id = "hardcover_read", label = "Hardcover: Read", choice = "Read", status = HARDCOVER.STATUS.FINISHED },
  { id = "hardcover_dnf", label = "Hardcover: Did Not Finish", choice = "Did Not Finish", status = HARDCOVER.STATUS.DNF },
}
local shelf_entries = {}
local list_entries = {}
local in_flight = {}
local retry_after = {}
local cover_in_flight = {}
local registered_app
local remoteSpec

local function hasCredentials(app)
  if not app or not app.enabled or not app.auth then return false end
  if app.auth.usingOAuth and app.auth:usingOAuth() then
    return app.auth.tokens ~= nil
  end
  return app.auth.usingPat and app.auth:usingPat()
    and app.auth.config and app.auth.config.token ~= nil
    and app.auth.config.token ~= ""
end

local function shelfKey(user_id, status_id)
  return table.concat({ "shelf", tostring(user_id), tostring(status_id) }, ":")
end

local function shelfRequestKey(status_id)
  -- One Hardcover account is active per KOReader session. Keep the request
  -- key stable while the first request resolves User:getId().
  return "shelf-fetch:" .. tostring(status_id)
end

local function listKey(user_id, source, list_id)
  return table.concat({ "list", tostring(user_id), tostring(source), tostring(list_id) }, ":")
end

local function listRequestKey(source, list_id)
  return table.concat({ "list-fetch", tostring(source), tostring(list_id) }, ":")
end

local function dateTime(value)
  if type(value) ~= "string" then return nil end
  local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not year then return nil end
  return os.time { year = tonumber(year), month = tonumber(month), day = tonumber(day),
    hour = 12 }
end

local function toBooks(entries, status_id)
  local out = {}
  for _, entry in ipairs(type(entries) == "table" and entries or {}) do
    local book_id = tonumber(entry.book_id)
    if book_id then
      local authors = type(entry.authors) == "string" and entry.authors or nil
      local record = {
        filepath = "hardcover://book/" .. tostring(book_id),
        title = entry.title or _("Untitled"),
        author = authors,
        authors = authors and { authors } or nil,
        series = entry.series,
        pages = entry.pages,
        rating = tonumber(entry.user_rating),
        status_id = status_id or tonumber(entry.status_id),
        added_time = dateTime(entry.date_added),
        hardcover_book_id = book_id,
        hardcover_entry = entry,
      }
      if status_id == HARDCOVER.STATUS.TO_READ then
        record.status, record.read_status = "unread", "unread"
        record.book_pct, record.percent_finished = 0, 0
      elseif status_id == HARDCOVER.STATUS.READING then
        record.status, record.read_status = "reading", "reading"
      elseif status_id == HARDCOVER.STATUS.FINISHED then
        record.status, record.read_status = "finished", "finished"
        record.book_pct, record.percent_finished = 1, 1
      end
      if type(entry.cached_image) == "table" then
        record.hardcover_cover_url = entry.cached_image.url
        record.hardcover_cover_width = entry.cached_image.width
        record.hardcover_cover_height = entry.cached_image.height
      end
      if entry.rank then record.hardcover_rank = tonumber(entry.rank) end
      out[#out + 1] = record
    end
  end
  return out
end

local function slice(items, offset, limit)
  local out = {}
  local first = (tonumber(offset) or 0) + 1
  local last = first + (tonumber(limit) or 0) - 1
  for i = first, math.min(last, #items) do out[#out + 1] = items[i] end
  return out
end

local function shelfPage(user_id, status_id, offset, limit)
  local state = shelf_entries[shelfKey(user_id, status_id)]
  if not state then return {}, nil end
  return slice(state.entries, offset, limit), state.complete and #state.entries or nil
end

local function changed(app, id)
  local bookshelf = app and app.ui and app.ui.bookshelf
  if bookshelf and type(bookshelf.sourceChanged) == "function" then
    pcall(bookshelf.sourceChanged, bookshelf, id)
  end
end

local function changedShelf(app, status_id)
  changed(app, SHELVES_ID)
  for _, shelf in ipairs(SHELF_SOURCES) do
    if shelf.status == status_id then changed(app, shelf.id) end
  end
end

local function startLoad(key, force, loader, app, done)
  if in_flight[key] then
    if done then
      in_flight[key].callbacks[#in_flight[key].callbacks + 1] = done
    end
    return
  end
  if not force and (retry_after[key] or 0) > os.time() then
    if done then done() end
    return
  end

  local pending = { callbacks = done and { done } or {} }
  in_flight[key] = pending
  UIManager:nextTick(function()
    Background.run(function()
      local ok, err = pcall(loader)
      if not ok then
        logger.warn("Hardcover Bookshelf source refresh failed:", tostring(err))
        retry_after[key] = os.time() + 30
      end
      if in_flight[key] == pending then in_flight[key] = nil end
      for _, callback in ipairs(pending.callbacks) do pcall(callback) end
    end)
  end)
end

local function loadShelf(app, shelf, force, done)
  local status_id = shelf.status
  local known_id = app.settings:readSetting(SETTING.USER_ID)
  local key = shelfRequestKey(status_id)
  if known_id and not force then
    local saved = app.shelf_cache:get(known_id, status_id)
    if saved and saved.complete then
      shelf_entries[shelfKey(known_id, status_id)] = { entries = saved.entries, complete = true }
      if done then done() end
      return
    end
  end

  startLoad(key, force, function()
    if not known_id and not Network.connected() then
      retry_after[key] = os.time() + 30
      return
    end
    local user_id = known_id or User:getId()
    local saved = app.shelf_cache:get(user_id, status_id)
    if saved and not force then
      shelf_entries[shelfKey(user_id, status_id)] = {
        entries = saved.entries, complete = saved.complete == true,
      }
      if saved.complete then return end
    end

    if not Network.connected() then
      retry_after[key] = os.time() + 30
      return
    end
    local result = ShelfLoader.load {
      fetch = function(offset, limit)
        return Api:getShelf(user_id, status_id, offset, limit)
      end,
      network = Network,
      dedupe = true,
      alive = function() return true end,
      sleep = Background.sleep,
      on_page = function(entries)
        shelf_entries[shelfKey(user_id, status_id)] = { entries = entries, complete = false }
        changedShelf(app, status_id)
      end,
    }
    if result then
      shelf_entries[shelfKey(user_id, status_id)] = {
        entries = result.entries, complete = result.complete == true,
      }
      app.shelf_cache:put(user_id, status_id, result.entries, result.complete)
      changedShelf(app, status_id)
      if result.complete then retry_after[key] = nil
      else retry_after[key] = os.time() + 30 end
    else
      retry_after[key] = os.time() + 30
    end
  end, app, done)
end

local function shelfForStatus(status_id)
  status_id = tonumber(status_id)
  for _, shelf in ipairs(SHELF_SOURCES) do
    if shelf.status == status_id then return shelf end
  end
end

local function shelfSource(app, id, fixed_shelf, picker)
  local spec = remoteSpec(app, id)
  spec.label = function()
    return picker and _("Hardcover shelf") or _(fixed_shelf.label)
  end
  spec.available = function() return hasCredentials(app) end
  spec.picker = picker == true

  if picker then
    spec.pick = function(draft, done)
      local Picker = require("hardcover/lib/ui/picker")
      local picker_widget
      local finished = false
      local function cancel()
        if finished then return end
        finished = true
        done(false)
      end
      local buttons = {}
      for index, shelf in ipairs(SHELF_SOURCES) do
        local shelf_spec = shelf
        buttons[index] = {
          text = _(shelf.choice),
          id = "hardcover_shelf_" .. tostring(index),
          callback = function()
            if finished then return end
            finished = true
            UIManager:close(picker_widget)
            draft.source.status_id = shelf_spec.status
            draft.source.shelf_name = shelf_spec.choice
            draft.label = _(shelf_spec.label)
            done()
          end,
        }
      end
      picker_widget = Picker.new { title = _("Choose a Hardcover shelf"), rows = buttons,
        close_callback = cancel }
      UIManager:show(picker_widget)
    end
  end

  spec.fetch = function(source, _drill, offset, limit)
    local shelf = fixed_shelf or shelfForStatus(source and source.status_id)
    if not shelf then return {}, 0 end
    local user_id = app.settings:readSetting(SETTING.USER_ID)
    if not user_id then
      loadShelf(app, shelf, false)
      return {}, nil
    end
    local key = shelfKey(user_id, shelf.status)
    local state = shelf_entries[key]
    if not state then
      local saved = app.shelf_cache:get(user_id, shelf.status)
      if saved then
        state = { entries = saved.entries, complete = saved.complete == true }
        shelf_entries[key] = state
      end
    end
    if not (state and state.complete) then loadShelf(app, shelf, false) end
    local entries, total = shelfPage(user_id, shelf.status, offset, limit)
    return toBooks(entries, shelf.status), total
  end
  spec.refresh = function(source, _drill, done)
    local shelf = fixed_shelf or shelfForStatus(source and source.status_id)
    if not shelf then done(); return end
    loadShelf(app, shelf, true, done)
  end
  return spec
end

local function loadList(app, source, force, done)
  local user_id = app.settings:readSetting(SETTING.USER_ID)
  local key = listRequestKey(source.list_source, source.list_id)
  startLoad(key, force, function()
    if not user_id and not Network.connected() then
      retry_after[key] = os.time() + 30
      return
    end
    local list_user_id = user_id or User:getId()
    local actual_key = listKey(list_user_id, source.list_source, source.list_id)
    local current = list_entries[actual_key]
    if current and current.complete and not force then return end
    if not Network.connected() then
      retry_after[key] = os.time() + 30
      return
    end

    local result = ShelfLoader.load {
      fetch = function(offset, limit)
        return Api:getListBooks(source.list_id, source.list_source,
          source.ranked == true, offset, limit)
      end,
      network = Network,
      use_has_more = true,
      dedupe = true,
      alive = function() return true end,
      sleep = Background.sleep,
      on_page = function(entries)
        list_entries[actual_key] = { entries = entries, complete = false }
        changed(app, LISTS_ID)
      end,
    }
    if result then
      list_entries[actual_key] = {
        entries = result.entries,
        complete = result.complete,
        total = result.complete and #result.entries or nil,
      }
      changed(app, LISTS_ID)
      if result.complete then retry_after[key] = nil
      else retry_after[key] = os.time() + 30 end
    else
      retry_after[key] = os.time() + 30
    end
  end, app, done)
end

local function bookDetail(app, book)
  local book_id = book and (book.hardcover_book_id or book.book_id)
  if book_id and app.dialog_manager then
    app.dialog_manager:showBookDetail(book_id)
  end
end

remoteSpec = function(app, id)
  return {
    api = 1,
    remote_prefix = "hardcover://",
    owns = function(book)
      return type(book) == "table" and type(book.filepath) == "string"
        and book.filepath:match("^hardcover://book/") ~= nil
    end,
    open = function(book)
      bookDetail(app, book)
      return true
    end,
    info = function(book)
      bookDetail(app, book)
    end,
    cover = function(book)
      local url = book and book.hardcover_cover_url
      if type(url) ~= "string" or url == "" then return nil end
      local ImageLoader = require("hardcover/lib/ui/image_loader")
      local cache_key = ImageLoader:fetchUrl(url, "small")
      local content = ImageLoader:lookup(cache_key)
      -- Older cache entries, and pinned originals from before sized covers,
      -- may still use the uploaded URL itself.
      if not content and cache_key ~= url then content = ImageLoader:lookup(url) end
      if not content then
        local pending = cover_in_flight[url]
        if not pending or os.time() - pending.started_at > 60 then
          pending = { started_at = os.time() }
          cover_in_flight[url] = pending
          local _batch, halt = ImageLoader:loadImages({ url }, function()
            cover_in_flight[url] = nil
            changed(app, id)
          end)
          pending.halt = halt
        end
        return nil
      end
      local width = math.max(1, math.min(600, tonumber(book.hardcover_cover_width) or 320))
      local height = math.max(1, math.min(900, tonumber(book.hardcover_cover_height) or 480))
      local bb = require("ui/renderimage"):renderImageData(content, #content, false, width, height)
      if bb then return bb, width, height end
      return nil
    end,
  }
end

function Sources.register(app)
  if not app then return false end
  registered_app = app
  local bookshelf = app.ui and app.ui.bookshelf
  if not (bookshelf and bookshelf.registerSource
      and (bookshelf.SOURCE_API or 0) >= 1) then
    return false
  end

  -- Preserve source IDs already saved on Bookshelf shelves. Keep those legacy
  -- entries out of the picker; new shelves use the single picker below.
  local ok_shelves = true
  for _, shelf in ipairs(SHELF_SOURCES) do
    local spec = shelfSource(app, shelf.id, shelf, false)
    spec.picker = false
    local ok, why = bookshelf:registerSource(shelf.id, spec)
    if not ok then logger.warn("Hardcover shelf source refused:", shelf.id, tostring(why)) end
    ok_shelves = ok_shelves and ok
  end

  local shelves = shelfSource(app, SHELVES_ID, nil, true)
  local ok_shelves_picker, why_shelves_picker = bookshelf:registerSource(SHELVES_ID, shelves)
  if not ok_shelves_picker then
    logger.warn("Hardcover shelf picker source refused:", tostring(why_shelves_picker))
  end

  local lists = remoteSpec(app, LISTS_ID)
  lists.label = function() return _("Hardcover list") end
  lists.available = function() return hasCredentials(app) end
  lists.picker = true
  lists.pick = function(draft, done)
    if not Network.connected() then
      UIManager:show(require("ui/widget/infomessage"):new {
        text = _("Connect to the internet to choose a Hardcover list."), timeout = 3,
      })
      done(false)
      return
    end
    Api:getListsAsync(function(found, err)
      if not found then
        logger.warn("Hardcover list picker failed:", tostring(err))
        UIManager:show(require("ui/widget/infomessage"):new {
          text = _("Could not load your Hardcover lists."), timeout = 3,
        })
        done(false)
        return
      end
      local rows = {}
      for _, row in ipairs(found.mine or {}) do
        rows[#rows + 1] = { row = row, text = row.name }
      end
      for _, row in ipairs(found.following or {}) do
        local owner = row.owner and (" — " .. row.owner) or ""
        rows[#rows + 1] = { row = row, text = row.name .. owner }
      end
      if #rows == 0 then
        UIManager:show(require("ui/widget/infomessage"):new {
          text = _("No Hardcover lists are available."), timeout = 3,
        })
        done(false)
        return
      end
      local Picker = require("hardcover/lib/ui/picker")
      local picker
      local finished = false
      local function cancel()
        if finished then return end
        finished = true
        done(false)
      end
      local buttons = {}
      for index, choice in ipairs(rows) do
        buttons[index] = {
          text = choice.text,
          id = "hardcover_list_" .. tostring(index),
          callback = function()
            if finished then return end
            finished = true
            UIManager:close(picker)
            local row = choice.row
            draft.source.list_id = tonumber(row.id) or row.id
            draft.source.list_source = row.source or "mine"
            draft.source.ranked = row.ranked == true
            draft.source.list_name = row.name
            draft.label = row.name
            done()
          end,
        }
      end
      picker = Picker.new { title = _("Choose a Hardcover list"), rows = buttons,
        close_callback = cancel }
      UIManager:show(picker)
    end)
  end
  lists.fetch = function(source, _drill, offset, limit)
    if not source.list_id then return {}, 0 end
    local user_id = app.settings:readSetting(SETTING.USER_ID)
    if not user_id then
      loadList(app, source, false)
      return {}, nil
    end
    local key = listKey(user_id, source.list_source or "mine", source.list_id)
    local state = list_entries[key]
    if not state then
      loadList(app, source, false)
      return {}, nil
    end
    if not state.complete then loadList(app, source, false) end
    return slice(toBooks(state.entries, nil), offset, limit), state.total
  end
  lists.refresh = function(source, _drill, done)
    if not source.list_id then done(); return end
    local user_id = app.settings:readSetting(SETTING.USER_ID)
    if user_id then
      list_entries[listKey(user_id, source.list_source or "mine", source.list_id)] = nil
    end
    loadList(app, source, true, done)
  end

  local ok_lists, why_lists = bookshelf:registerSource(LISTS_ID, lists)
  if not ok_lists then logger.warn("Hardcover lists source refused:", tostring(why_lists)) end
  return ok_shelves and ok_shelves_picker and ok_lists
end

function Sources.changed(app)
  app = app or registered_app
  for _, shelf in ipairs(SHELF_SOURCES) do retry_after[shelfRequestKey(shelf.status)] = nil end
  for key in pairs(retry_after) do
    if key:match("^list%-fetch:") then retry_after[key] = nil end
  end
  for _, shelf in ipairs(SHELF_SOURCES) do changed(app, shelf.id) end
  changed(app, SHELVES_ID)
  changed(app, LISTS_ID)
end

function Sources.invalidate(app)
  app = app or registered_app
  local user_id = app and app.settings and app.settings:readSetting(SETTING.USER_ID)
  if user_id then
    for _, shelf in ipairs(SHELF_SOURCES) do
      shelf_entries[shelfKey(user_id, shelf.status)] = nil
    end
  end
  for _, shelf in ipairs(SHELF_SOURCES) do changed(app, shelf.id) end
  changed(app, SHELVES_ID)
end

return Sources
