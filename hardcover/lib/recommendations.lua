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

-- The carousel on the details screen, headed "Similar to <the book's title>" (same shape
-- as Shelf.seriesCard): a cover, the bold title, the author under it (`title_first`; a
-- series strip shows the book's number first). Nil when there is nothing to show.
function Recommendations.card(entries, name)
  if type(entries) ~= "table" or #entries == 0 then return nil end
  local items = {}
  for i, entry in ipairs(entries) do
    items[i] = {
      book_id = entry.book_id,
      number = entry.authors ~= "" and entry.authors or " ",
      title = entry.title,
      current = false,
      cover = Shelf.coverOf({ cached_image = entry.cached_image }),
    }
  end
  return {
    title = (type(name) == "string" and name ~= "") and ("Similar to " .. name) or "Similar books",
    subtitle = string.format("%d books", #items),
    title_first = true,
    items = items,
  }
end

-- The strip while the ranking is on its way: the same heading with "Loading…", and empty
-- covers where the books will be, so the screen does not grow when they arrive. The
-- carousel fills it with as many empty covers as it shows at once; they cannot be tapped.
function Recommendations.loadingCard(name)
  return {
    title = (type(name) == "string" and name ~= "") and ("Similar to " .. name) or "Similar books",
    subtitle = "Loading\226\128\166",
    title_first = true,
    loading = true,
    items = { { number = " ", title = " " } },
  }
end

return Recommendations
