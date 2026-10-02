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

-- number fields: missing values go last whichever way the sort runs
local function numberSorter(field, descending)
  return function(a, b)
    local x, y = tonumber(a[field]), tonumber(b[field])
    if x == nil and y == nil then return nil end
    if x == nil then return false end
    if y == nil then return true end
    if x == y then return nil end
    if descending then return x > y end
    return x < y
  end
end

local function textSorter(keyfn)
  return function(a, b)
    local x, y = keyfn(a), keyfn(b)
    if x == y then return nil end
    return x < y
  end
end

local SORTERS = {
  added_desc = nil, -- the order they arrive in
  added_asc = "reverse",
  title = textSorter(titleKey),
  author = textSorter(authorKey),
  year_desc = numberSorter("release_year", true),
  year_asc = numberSorter("release_year", false),
  pages_asc = numberSorter("pages", false),
  pages_desc = numberSorter("pages", true),
  popular = numberSorter("users_count", true),
  rating = numberSorter("community_rating", true),
  my_rating = numberSorter("user_rating", true),
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

  local compare = SORTERS[key]
  local order = {}
  for i, entry in ipairs(list) do order[entry] = i end

  table.sort(list, function(a, b)
    local result = compare(a, b)
    if result == nil then
      return order[a] < order[b]
    end
    return result
  end)
  return list
end

return ShelfSort
