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

-- How many of each seed's similar books count, and the score of the first: a book that
-- is high up in several of your favourites' lists outscores one that is low in one.
Recommendations.SEED_DEPTH = 30

--
-- "For you": books to suggest from the books you rated highly. `seeds` are rows of
-- { rating, book = { id, title, cached_similar_book_ids } }; `own` is the ids of every
-- book already in your library (never suggested, and neither are the seeds). Each
-- seed's similar books score by rank (the first counts most), a seed you rated 4.5
-- or more counting double. Returns { { id, score, reason }... }, best first, at most
-- `limit`; `reason` is the title of the seed that contributed most.
--
function Recommendations.score(seeds, own, limit)
  limit = limit or Recommendations.LIMIT
  local owned = {}
  for _, id in ipairs(type(own) == "table" and own or {}) do
    local n = tonumber(id)
    if n then owned[n] = true end
  end

  local total, best = {}, {}
  for _, seed in ipairs(type(seeds) == "table" and seeds or {}) do
    local book = type(seed) == "table" and seed.book
    local rating = type(seed) == "table" and tonumber(seed.rating) or nil
    if type(book) == "table" and rating and rating >= 4 then
      local weight = rating >= 4.5 and 2 or 1
      local seed_id = tonumber(book.id or book.book_id)
      if seed_id then owned[seed_id] = true end
      local ids = Recommendations.ids(book.cached_similar_book_ids, Recommendations.SEED_DEPTH)
      for rank, id in ipairs(ids) do
        local gain = weight * (Recommendations.SEED_DEPTH + 1 - rank)
        total[id] = (total[id] or 0) + gain
        if not best[id] or gain > best[id].gain then
          best[id] = { gain = gain, title = book.title }
        end
      end
    end
  end

  local out = {}
  for id, score in pairs(total) do
    if not owned[id] then out[#out + 1] = { id = id, score = score, reason = best[id].title } end
  end
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.id < b.id
  end)
  while #out > limit do table.remove(out) end
  return out
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
