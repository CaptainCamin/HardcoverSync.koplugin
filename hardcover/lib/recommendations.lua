-- "Books like this", as plain data.
--
-- No KOReader requires, so it runs under stock Lua in the spec suite. Hardcover keeps
-- a ranked list of about 100 similar book ids on every book (`cached_similar_book_ids`,
-- readable with the permissions the plugin already has). The ids come first, then one
-- request turns the first few into books; this module trims the ids, puts the books
-- back in rank order (the API returns `_in` matches in any order) and shapes them as
-- shelf entries.

local Shelf = require("hardcover/lib/shelf")

local Recommendations = {}

-- How many similar books one screen shows (one request fetches them all)
Recommendations.LIMIT = 20

-- The first `limit` ids, as whole numbers, without repeats. Anything that is not a
-- list of numbers (null for a new book, an object) gives an empty list.
function Recommendations.ids(raw, limit)
  limit = limit or Recommendations.LIMIT
  local out, seen = {}, {}
  if type(raw) ~= "table" then return out end
  for _, value in ipairs(raw) do
    local id = tonumber(value)
    if id and id == math.floor(id) and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
      if #out >= limit then break end
    end
  end
  return out
end

-- Shelf entries for `books` (rows from the books query), in the order of `ids`.
-- Ids that did not come back are left out; rows that were not asked for are ignored.
function Recommendations.entries(ids, books)
  local by_id = {}
  for _, book in ipairs(type(books) == "table" and books or {}) do
    local id = tonumber(book.book_id or book.id)
    if id then by_id[id] = book end
  end
  local entries = {}
  for _, id in ipairs(ids or {}) do
    local book = by_id[id]
    if book then
      local entry = Shelf.normalizeEntry({ book = book })
      entry.user_book_id = nil -- not one of your own library rows
      entries[#entries + 1] = entry
    end
  end
  return entries
end

return Recommendations
