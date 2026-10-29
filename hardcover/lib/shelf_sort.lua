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

-- Common Latin accents folded to their ASCII base letter (lower case), so "\195\137mile" sorts
-- under E and "\195\145and\195\186" under N rather than after Z. Latin-1 Supplement and Latin Extended-A.
local FOLD = {}
do
  local function add(first, last, base)
    for cp = first, last do
      FOLD[string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)] = base
    end
  end
  local latin1 = {
    { 0xC0, 0xC5, "a" }, { 0xC6, 0xC6, "ae" }, { 0xC7, 0xC7, "c" }, { 0xC8, 0xCB, "e" },
    { 0xCC, 0xCF, "i" }, { 0xD0, 0xD0, "d" }, { 0xD1, 0xD1, "n" }, { 0xD2, 0xD6, "o" },
    { 0xD8, 0xD8, "o" }, { 0xD9, 0xDC, "u" }, { 0xDD, 0xDD, "y" }, { 0xDE, 0xDE, "th" },
    { 0xDF, 0xDF, "ss" }, { 0xE0, 0xE5, "a" }, { 0xE6, 0xE6, "ae" }, { 0xE7, 0xE7, "c" },
    { 0xE8, 0xEB, "e" }, { 0xEC, 0xEF, "i" }, { 0xF0, 0xF0, "d" }, { 0xF1, 0xF1, "n" },
    { 0xF2, 0xF6, "o" }, { 0xF8, 0xF8, "o" }, { 0xF9, 0xFC, "u" }, { 0xFD, 0xFD, "y" },
    { 0xFE, 0xFE, "th" }, { 0xFF, 0xFF, "y" },
    { 0x100, 0x105, "a" }, { 0x106, 0x10D, "c" }, { 0x10E, 0x111, "d" }, { 0x112, 0x11B, "e" },
    { 0x11C, 0x123, "g" }, { 0x124, 0x127, "h" }, { 0x128, 0x131, "i" }, { 0x132, 0x133, "ij" },
    { 0x134, 0x135, "j" }, { 0x136, 0x138, "k" }, { 0x139, 0x142, "l" }, { 0x143, 0x14B, "n" },
    { 0x14C, 0x151, "o" }, { 0x152, 0x153, "oe" }, { 0x154, 0x159, "r" }, { 0x15A, 0x161, "s" },
    { 0x162, 0x167, "t" }, { 0x168, 0x173, "u" }, { 0x174, 0x175, "w" }, { 0x176, 0x178, "y" },
    { 0x179, 0x17E, "z" }, { 0x17F, 0x17F, "s" },
  }
  for _, r in ipairs(latin1) do add(r[1], r[2], r[3]) end
end

-- lower case with accents folded, for ordering
local function fold(text)
  return (text:gsub("[\195-\197][\128-\191]", FOLD):lower())
end

-- "The Dispossessed" sorts under D, as in a library
local function titleKey(entry)
  local title = fold(entry.title or ""):gsub("^%s+", "")
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
  return fold(surname) .. "\0" .. fold(first)
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
