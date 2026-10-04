-- What other readers say about a book, from Hardcover's own tallies: how many gave each
-- rating (the breakdown) and the genres, moods and content warnings readers tagged it with.
-- Pure logic, no KOReader.

local Community = {}

-- tags marked as spoilers by at least this share of the readers who used them are not shown
local SPOILER_RATIO = 0.5

-- The ratings given to a book as { counts = {10 half-star counts, 0.5 first}, total,
-- average } or nil when nobody rated it. `book.ratings_distribution` is a list of
-- { rating, count }; the average is computed from it, so the markers and the bars agree.
function Community.distribution(book)
  local list = type(book) == "table" and book.ratings_distribution
  if type(list) ~= "table" then return nil end
  local counts = {}
  for i = 1, 10 do counts[i] = 0 end
  local total, sum = 0, 0
  for _, row in ipairs(list) do
    local rating, count = type(row) == "table" and tonumber(row.rating), type(row) == "table" and tonumber(row.count)
    if rating and count and count > 0 and rating >= 0.5 and rating <= 5 then
      local i = math.floor(rating * 2 + 0.5)
      counts[i] = counts[i] + count
      total = total + count
      sum = sum + count * rating
    end
  end
  if total == 0 then return nil end
  return { counts = counts, total = total, average = sum / total }
end

-- "adventurous" -> "Adventurous"
local function capital(text)
  return (text:gsub("^%l", string.upper))
end

local function topTags(list, limit)
  local out = {}
  for _, row in ipairs(type(list) == "table" and list or {}) do
    local tag, count = type(row) == "table" and row.tag, type(row) == "table" and tonumber(row.count)
    local spoiler = type(row) == "table" and tonumber(row.spoilerRatio) or 0
    if type(tag) == "string" and tag ~= "" and count and count > 0 and spoiler < SPOILER_RATIO then
      out[#out + 1] = { tag = capital(tag), count = count }
    end
  end
  table.sort(out, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.tag < b.tag
  end)
  for i = #out, limit + 1, -1 do out[i] = nil end
  return out
end

-- The tags readers gave a book, each group most-used first: { genres, moods, warnings },
-- every one a list of { tag, count } (empty when there are none).
function Community.tags(book, limit)
  local tags = type(book) == "table" and type(book.cached_tags) == "table" and book.cached_tags or {}
  limit = limit or 8
  return {
    genres = topTags(tags.Genre, limit),
    moods = topTags(tags.Mood, limit),
    warnings = topTags(tags["Content Warning"], limit),
  }
end

return Community
