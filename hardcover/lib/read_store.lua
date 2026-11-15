-- A book's reads, kept on the device: what Hardcover last said its reading history is, so
-- Reading history opens offline. Keyed by account and book, so another sign-in never sees this
-- account's reads. Pure logic over the same injected store as review_store.lua (getBlob, putBlob);
-- every operation is best-effort.
--
-- The book details cache (book_store.lua) deliberately drops all of a book's own user data, so
-- reads are kept here instead: a detail that is a week old must not claim a week-old history.

local Codec = require("hardcover/lib/codec")

local ReadStore = {}
ReadStore.__index = ReadStore

function ReadStore:new(o)
  o = o or {}
  o.now = o.now or os.time
  return setmetatable(o, self)
end

local function key(user_id, book_id)
  return "reads:" .. tostring(user_id or 0) .. ":" .. tostring(book_id)
end

-- { reads, checked_at } as last saved, or nil. An empty list is a real answer: the book has no
-- reads, as opposed to no saved copy at all.
function ReadStore:get(user_id, book_id)
  if not self.db then return nil end
  local saved = Codec.decode(self.db:getBlob(key(user_id, book_id)))
  if saved and type(saved.reads) == "table" and type(saved.checked_at) == "number" then
    return saved
  end
end

-- Save what Hardcover said this book's reads are. `editions` (optional) is the picker's list,
-- kept so a read's edition can be changed offline. Omitting it keeps the editions already saved.
function ReadStore:put(user_id, book_id, reads, editions)
  if not self.db or type(reads) ~= "table" then return false end
  if editions == nil then
    local saved = self:get(user_id, book_id)
    editions = saved and saved.editions
  end
  local text = Codec.encode({ reads = reads, checked_at = self.now(), editions = editions })
  return text and self.db:putBlob(key(user_id, book_id), text) or false
end

-- The edition picker's rows changed. The reads and their checked time stay as they were.
function ReadStore:putEditions(user_id, book_id, editions)
  if type(editions) ~= "table" then return false end
  local saved = self:get(user_id, book_id)
  return self:put(user_id, book_id, saved and saved.reads or {}, editions)
end

-- Signing out forgets every account's saved reads, like the rest of the library cache. A store
-- without a way to drop keys still answers the question, it just cannot forget them.
function ReadStore:invalidate()
  if self.db and type(self.db.dropOwned) == "function" then
    return self.db:dropOwned("reads:") and true or false
  end
  return true
end

return ReadStore
