-- Text search over shelf and list entries.
--
-- The Search button on a shelf or list filters what is already on the device, so
-- this runs over the loaded entries and never costs a request. Matching ignores
-- case and accents: "emile" finds "Émile". Pure: no KOReader modules, so it runs
-- under stock Lua.
--
-- Folding is done by hand because Lua 5.1 has no Unicode library, and KOReader's
-- util folds case but not accents.

local EntrySearch = {}

-- Two-byte UTF-8 Latin letters (U+00C0..U+017F) and what they fold to. Keys are the
-- raw bytes, so a letter not listed here is left as it is.
local FOLD = {}

local function fold_into(letters, to)
  for letter in letters:gmatch("[\195-\197][\128-\191]") do
    FOLD[letter] = to
  end
end

fold_into("àáâãäåāăąÀÁÂÃÄÅĀĂĄ", "a")
fold_into("çćčÇĆČ", "c")
fold_into("ďđĎĐ", "d")
fold_into("ðÐ", "d")
fold_into("èéêëēėęěÈÉÊËĒĖĘĚ", "e")
fold_into("ìíîïīįıÌÍÎÏĪĮİ", "i")
fold_into("ñńňÑŃŇ", "n")
fold_into("òóôõöøōőÒÓÔÕÖØŌŐ", "o")
fold_into("ùúûüūůűÙÚÛÜŪŮŰ", "u")
fold_into("ýÿÝŸ", "y")
fold_into("žźżŽŹŻ", "z")
fold_into("šśŠŚ", "s")
fold_into("řŘ", "r")
fold_into("łŁ", "l")
fold_into("ß", "ss")
fold_into("æÆ", "ae")
fold_into("œŒ", "oe")
fold_into("þÞ", "th")

-- Lowercase with the accented letters folded. The table is applied first so that
-- string.lower only has to deal with ASCII.
function EntrySearch.fold(s)
  if s == nil then return "" end
  local folded = string.gsub(tostring(s), "[\195-\197][\128-\191]", FOLD)
  return string.lower(folded)
end

-- The query as a list of folded words. Blank input gives an empty list.
function EntrySearch.words(query)
  local list = {}
  for word in EntrySearch.fold(query):gmatch("%S+") do
    list[#list + 1] = word
  end
  return list
end

-- Appends s when it is a non-empty string, so a missing part adds nothing.
local function add(list, s)
  if type(s) == "string" and s ~= "" then list[#list + 1] = s end
end

-- Every author name the entry carries, from each shape it might come in. Collecting
-- from all of them is harmless: a match in any one is a match.
local function authorsOf(entry)
  local names = {}
  add(names, entry.authors)
  if type(entry.author) == "table" then add(names, entry.author.name) end
  if type(entry.contributions) == "table" then
    for _, c in ipairs(entry.contributions) do
      if type(c) == "table" and type(c.author) == "table" then add(names, c.author.name) end
    end
  end
  return table.concat(names, ", ")
end

local function seriesOf(entry)
  local names = {}
  add(names, entry.series)
  if type(entry.book_series) == "table" then
    for _, bs in ipairs(entry.book_series) do
      if type(bs) == "table" and type(bs.series) == "table" then add(names, bs.series.name) end
    end
  end
  return table.concat(names, ", ")
end

-- The title, authors and series as one folded string, one part per line. A missing
-- part adds no line. Query words hold no whitespace, so a word cannot run across
-- two lines or across the ", " inside a part.
function EntrySearch.haystack(entry)
  if type(entry) ~= "table" then return "" end
  local parts = {}
  add(parts, entry.title)
  add(parts, authorsOf(entry))
  add(parts, seriesOf(entry))
  return EntrySearch.fold(table.concat(parts, "\n"))
end

-- Plain find, so "(" and "%" in a query are just characters.
local function containsAll(hay, words)
  for _, word in ipairs(words) do
    if not hay:find(word, 1, true) then return false end
  end
  return true
end

function EntrySearch.matches(entry, query)
  return containsAll(EntrySearch.haystack(entry), EntrySearch.words(query))
end

-- A new list of the matching entries, in their original order. A blank query gives
-- back the list it was handed.
function EntrySearch.filter(entries, query)
  local words = EntrySearch.words(query)
  if #words == 0 then return entries end
  local out = {}
  for _, entry in ipairs(entries or {}) do
    if containsAll(EntrySearch.haystack(entry), words) then
      out[#out + 1] = entry
    end
  end
  return out
end

return EntrySearch
