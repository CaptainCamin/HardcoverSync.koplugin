-- Ordering a shelf's books.
--
-- The whole shelf is loaded (and saved) in the order Hardcover returns it, newest
-- added first. Sorting is done here, on the loaded list, so it works the same
-- offline and never costs a request. Pure: no widgets.

local ShelfSort = {}

-- key, label (what the sort menu says), field used
ShelfSort.OPTIONS = {
  { key = "added_desc", label = "Date added (newest first)" },
  { key = "added_asc", label = "Date added (oldest first)" },
  { key = "title", label = "Title (A\226\128\147Z)" },
  { key = "author", label = "Author (A\226\128\147Z)" },
  { key = "year_desc", label = "Published (newest first)" },
  { key = "year_asc", label = "Published (oldest first)" },
  { key = "pages_asc", label = "Pages (shortest first)" },
  { key = "pages_desc", label = "Pages (longest first)" },
  { key = "popular", label = "Most readers on Hardcover" },
  { key = "rating", label = "Community rating (highest first)" },
  { key = "my_rating", label = "My rating (highest first)" },
}

ShelfSort.DEFAULT = "added_desc"

function ShelfSort.isKey(key)
  for _, option in ipairs(ShelfSort.OPTIONS) do
    if option.key == key then return true end
  end
  return false
end

function ShelfSort.label(key)
  for _, option in ipairs(ShelfSort.OPTIONS) do
    if option.key == key then return option.label end
  end
  return ShelfSort.OPTIONS[1].label
end

-- "The Dispossessed" sorts under D, as in a library
local function titleKey(entry)
  local title = (entry.title or ""):lower():gsub("^%s+", "")
  for _, article in ipairs({ "the ", "an ", "a " }) do
    if title:sub(1, #article) == article and #title > #article then
      return title:sub(#article + 1)
    end
  end
  return title
end

-- sorted by surname: the last word of the first author
local function authorKey(entry)
  local first = (entry.authors or ""):match("^([^,]+)") or ""
  first = first:gsub("%s+$", "")
  local surname = first:match("([^%s]+)$") or first
  return surname:lower() .. "\0" .. first:lower()
end

local function numberKey(field)
  return function(entry) return tonumber(entry[field]) end
end

-- Each order is a key worked out once per book (not once per comparison, which
-- on a slow device is the difference between a noticeable pause and none), and
-- whether the keys are numbers. Number fields: missing values go last whichever
-- way the sort runs.
local SORTERS = {
  title = { key = titleKey },
  author = { key = authorKey },
  year_desc = { key = numberKey("release_year"), numeric = true, descending = true },
  year_asc = { key = numberKey("release_year"), numeric = true },
  pages_asc = { key = numberKey("pages"), numeric = true },
  pages_desc = { key = numberKey("pages"), numeric = true, descending = true },
  popular = { key = numberKey("users_count"), numeric = true, descending = true },
  rating = { key = numberKey("community_rating"), numeric = true, descending = true },
  my_rating = { key = numberKey("user_rating"), numeric = true, descending = true },
}

--
-- A new list in the chosen order; the input is not changed. Ties keep their
-- original (date added) order, so sorting by author groups a writer's books
-- newest-added first rather than shuffling them.
--
function ShelfSort.sort(entries, key)
  local list = {}
  for i, entry in ipairs(entries or {}) do
    list[i] = entry
  end

  if key == nil or key == "added_desc" or not ShelfSort.isKey(key) then
    return list
  end

  if key == "added_asc" then
    local reversed = {}
    for i = #list, 1, -1 do reversed[#reversed + 1] = list[i] end
    return reversed
  end

  local sorter = SORTERS[key]
  local keyOf, numeric, descending = sorter.key, sorter.numeric, sorter.descending
  local keys, order = {}, {}
  for i, entry in ipairs(list) do
    keys[i] = keyOf(entry)
    order[i] = i
  end

  local function before(i, j)
    local x, y = keys[i], keys[j]
    if x == y then return i < j end
    if numeric then
      if x == nil then return false end
      if y == nil then return true end
      if descending then return x > y end
    end
    return x < y
  end
  table.sort(order, before)

  local sorted = {}
  for n, i in ipairs(order) do sorted[n] = list[i] end
  return sorted
end

return ShelfSort
