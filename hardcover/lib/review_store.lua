-- Community reviews already browsed, kept in the library database. Account-scoped because
-- the permission to see reviewers' names can differ between sign-ins. Full text is kept;
-- spoiler reveals are screen state only and are never saved.
local Codec = require("hardcover/lib/codec")

local ReviewStore = {}
ReviewStore.__index = ReviewStore

function ReviewStore:new(o)
  o = o or {}
  o.now = o.now or os.time
  o.sessions = {}
  return setmetatable(o, self)
end

local function key(user_id, book_id)
  return "reviews:" .. tostring(user_id or 0) .. ":" .. tostring(book_id)
end

-- A newer visit supersedes pending writes from an older one, but simply closing a screen
-- does not: its last page may still arrive. Sign-out invalidates every pending write.
function ReviewStore:begin(user_id, book_id)
  local session = {}
  self.sessions[key(user_id, book_id)] = session
  return session
end

function ReviewStore:invalidate()
  self.sessions = {}
end

function ReviewStore:get(user_id, book_id)
  if not self.db then return nil end
  local saved = Codec.decode(self.db:getBlob(key(user_id, book_id)))
  if saved and type(saved.reviews) == "table" and type(saved.offset) == "number"
      and type(saved.saved_at) == "number" then
    return saved
  end
end

function ReviewStore:put(user_id, book_id, reviews, offset, more, summary, session)
  if not self.db or self.sessions[key(user_id, book_id)] ~= session then return false end
  local text = Codec.encode({ reviews = reviews, offset = offset, more = more == true,
    summary = summary, saved_at = self.now() })
  return text and self.db:putBlob(key(user_id, book_id), text) or false
end

return ReviewStore
