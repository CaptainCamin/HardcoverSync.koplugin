-- Keeps the pages of your shelves on disk so they can be browsed offline.
--
-- Pure logic: the store is injected (`open(path)` returns a LuaSettings-like
-- object) and opened on first use, so requiring this costs nothing at startup
-- and nothing is read until a shelf is actually opened.
--
-- A shelf is the pair (user, status). Keying on the user means a different
-- account never sees someone else's cached library. Pages are stored by their
-- offset, exactly as the API returns them, because that is how the shelf screen
-- asks for them.
--
-- Every operation is best-effort: a cache that cannot be read or written must
-- never break the screen that asked for it.

local ShelfCache = {}
ShelfCache.__index = ShelfCache

-- Do not keep pages past this offset: the cache is for browsing, not a mirror
-- of a very large library, and each page carries descriptions.
local MAX_OFFSET = 200

function ShelfCache:new(o)
  return setmetatable(o or {}, self)
end

-- false (not nil) once opening has failed, so a broken file is not retried on
-- every call
function ShelfCache:_store()
  if self.store == nil then
    local ok, store = pcall(self.open, self.path)
    self.store = ok and store or false
  end
  return self.store or nil
end

local function shelfKey(user_id, status_id)
  return tostring(user_id or 0) .. ":" .. tostring(status_id or "all")
end

local function pageKey(offset)
  return "p" .. tostring(offset or 0)
end

function ShelfCache:_shelf(user_id, status_id, create)
  local store = self:_store()
  if not store then return nil end

  local shelves = store:readSetting("shelves")
  if not shelves then
    if not create then return nil end
    shelves = {}
    store:saveSetting("shelves", shelves)
  end

  local key = shelfKey(user_id, status_id)
  local shelf = shelves[key]
  if not shelf and create then
    shelf = { pages = {} }
    shelves[key] = shelf
  end
  return shelf
end

-- { entries = {...}, has_more = bool, saved_at = os.time() } or nil
function ShelfCache:getPage(user_id, status_id, offset)
  local shelf = self:_shelf(user_id, status_id, false)
  local page = shelf and shelf.pages and shelf.pages[pageKey(offset)]
  if page and type(page.entries) == "table" then
    return page
  end
end

function ShelfCache:putPage(user_id, status_id, offset, entries, has_more)
  offset = offset or 0
  if offset >= MAX_OFFSET or type(entries) ~= "table" then
    return false
  end

  local shelf = self:_shelf(user_id, status_id, true)
  if not shelf then return false end

  -- A fresh first page means the later ones were fetched against an older
  -- ordering and their offsets no longer line up, so drop them. They are
  -- re-fetched if the reader pages forward.
  if offset == 0 then
    shelf.pages = {}
  end

  shelf.pages[pageKey(offset)] = {
    entries = entries,
    has_more = has_more and true or false,
    saved_at = os.time(),
  }

  local store = self:_store()
  local ok = pcall(store.flush, store)
  return ok
end

-- The cached row for a book, from any page of any of this user's shelves. Lets
-- a book's details be shown offline from what the shelf already had.
function ShelfCache:findEntry(user_id, book_id)
  local store = self:_store()
  local shelves = store and store:readSetting("shelves")
  if not shelves or not book_id then return nil end

  local prefix = tostring(user_id or 0) .. ":"
  for key, shelf in pairs(shelves) do
    if key:sub(1, #prefix) == prefix and shelf.pages then
      for _, page in pairs(shelf.pages) do
        for _, entry in ipairs(page.entries or {}) do
          if entry.book_id == book_id then
            return entry
          end
        end
      end
    end
  end
end

-- Everything, for sign out: the cache holds a user's library.
function ShelfCache:clear()
  local store = self:_store()
  if not store then return false end
  store:saveSetting("shelves", nil)
  return pcall(store.flush, store)
end

return ShelfCache
