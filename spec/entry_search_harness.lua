-- Searching shelf and list entries: case- and accent-insensitive, every word must
-- be found, and a query may hold ( or % without erroring. Pure, no KOReader.
--
-- Run with:  lua spec/entry_search_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local EntrySearch = require("hardcover/lib/entry_search")

-- One entry per shape the search meets.
local plain = { id = 1, title = "The Dispossessed", authors = "Ursula K. Le Guin, Someone Else",
  series = "Hainish Cycle #6" }
local byAuthorName = { id = 2, title = "Dune", author = { name = "Frank Herbert" } }
local byContributions = { id = 3, title = "Good Omens",
  contributions = { { author = { name = "Terry Pratchett" } }, { author = { name = "Neil Gaiman" } } } }
local byBookSeries = { id = 4, title = "The Hobbit", book_series = { { series = { name = "Middle-earth" } } } }
local paren = { id = 5, title = "Dune (Deluxe) 100%" }

local function ids(list)
  local out = {}
  for i, e in ipairs(list) do out[i] = e.id end
  return table.concat(out, ",")
end

print("\n== folding ==")

check("accents and case fold together", function()
  assert(EntrySearch.fold("Émile Zola") == "emile zola", EntrySearch.fold("Émile Zola"))
end)

check("sharp s folds to ss", function()
  assert(EntrySearch.fold("Straße") == "strasse", EntrySearch.fold("Straße"))
end)

check("the ligature folds to ae", function()
  assert(EntrySearch.fold("ÆON") == "aeon", EntrySearch.fold("ÆON"))
end)

check("nil folds to the empty string", function()
  assert(EntrySearch.fold(nil) == "")
end)

check("every letter in the table folds to its plain form", function()
  local pairs_ = {
    { "àáâãäåāăąÀÁÂÃÄÅĀĂĄ", string.rep("a", 18) },
    { "çćčÇĆČ", string.rep("c", 6) },
    { "ďđĎĐðÐ", string.rep("d", 6) },
    { "èéêëēėęěÈÉÊËĒĖĘĚ", string.rep("e", 16) },
    { "ìíîïīįıÌÍÎÏĪĮİ", string.rep("i", 14) },
    { "ñńňÑŃŇ", string.rep("n", 6) },
    { "òóôõöøōőÒÓÔÕÖØŌŐ", string.rep("o", 16) },
    { "ùúûüūůűÙÚÛÜŪŮŰ", string.rep("u", 14) },
    { "ýÿÝŸ", string.rep("y", 4) },
    { "žźżŽŹŻ", string.rep("z", 6) },
    { "šśŠŚ", string.rep("s", 4) },
    { "řŘ", "rr" },
    { "łŁ", "ll" },
    { "ßæÆœŒþÞ", "ssaeaeoeoethth" },
  }
  for _, p in ipairs(pairs_) do
    local got = EntrySearch.fold(p[1])
    assert(got == p[2], p[1] .. " -> " .. got .. ", wanted " .. p[2])
  end
end)

check("a letter outside the table is left as it is", function()
  -- Ğ is in the two-byte range but not in the table; Ω is outside the range.
  assert(EntrySearch.fold("Ğ") == "Ğ", EntrySearch.fold("Ğ"))
  assert(EntrySearch.fold("Ω") == "Ω", EntrySearch.fold("Ω"))
end)

print("\n== the haystack ==")

check("the haystack is the title, authors and series, one per line, folded", function()
  local hay = EntrySearch.haystack(plain)
  assert(hay == "the dispossessed\nursula k. le guin, someone else\nhainish cycle #6", hay)
  hay = EntrySearch.haystack(byAuthorName)
  assert(hay == "dune\nfrank herbert", hay)
  hay = EntrySearch.haystack(byContributions)
  assert(hay == "good omens\nterry pratchett, neil gaiman", hay)
  hay = EntrySearch.haystack(byBookSeries)
  assert(hay == "the hobbit\nmiddle-earth", hay)
end)

check("missing parts add no lines", function()
  assert(EntrySearch.haystack({}) == "")
  assert(EntrySearch.haystack({ authors = "Au Thor" }) == "au thor")
end)

check("the same people read the same in every author shape", function()
  local a = EntrySearch.haystack({ authors = "Terry Pratchett, Neil Gaiman" })
  local b = EntrySearch.haystack(byContributions)
  assert(a == "terry pratchett, neil gaiman" and b == "good omens\n" .. a, a .. " | " .. b)
end)

print("\n== words ==")

check("the query splits into folded words", function()
  local w = EntrySearch.words("  Émile   Zola ")
  assert(#w == 2 and w[1] == "emile" and w[2] == "zola", table.concat(w, "|"))
end)

check("blank and nil queries have no words", function()
  assert(#EntrySearch.words("   ") == 0 and #EntrySearch.words(nil) == 0)
end)

print("\n== where a word is found ==")

check("a title match", function()
  assert(EntrySearch.matches(plain, "dispossessed"))
end)

check("an author match from the authors string", function()
  assert(EntrySearch.matches(plain, "guin"))
end)

check("an author match from author.name", function()
  assert(EntrySearch.matches(byAuthorName, "herbert"))
end)

check("an author match from contributions", function()
  assert(EntrySearch.matches(byContributions, "gaiman"))
end)

check("a series match from the series string", function()
  assert(EntrySearch.matches(plain, "hainish"))
  assert(EntrySearch.matches(plain, "#6"))
end)

check("a series match from book_series", function()
  assert(EntrySearch.matches(byBookSeries, "middle-earth"))
end)

check("a word does not run across two parts of an entry", function()
  -- title "Ab" and authors "Cd" fold to two separate lines, so "bc" is not there.
  assert(not EntrySearch.matches({ title = "Ab", authors = "Cd" }, "bc"))
end)

print("\n== several words ==")

check("two words, one in the title and one in the author, both match", function()
  assert(EntrySearch.matches(plain, "dispossessed guin"))
  assert(EntrySearch.matches(plain, "guin dispossessed"))
end)

check("one word that matches nothing rejects the entry", function()
  assert(not EntrySearch.matches(plain, "dispossessed tolkien"))
end)

check("a word found nowhere rejects the entry", function()
  assert(not EntrySearch.matches(byAuthorName, "zzz"))
end)

print("\n== accents in either direction ==")

check("an accented title is found by a plain query", function()
  assert(EntrySearch.matches({ title = "Émile Zola" }, "emile"))
  assert(EntrySearch.matches({ title = "Straße" }, "strasse"))
end)

check("a plain title is found by an accented query", function()
  assert(EntrySearch.matches({ title = "Emile Zola" }, "émile"))
end)

print("\n== a query with ( or % ==")

check("( and % in a query do not error, and match what is there", function()
  assert(EntrySearch.matches(paren, "(deluxe"))
  assert(EntrySearch.matches(paren, "100%"))
  assert(EntrySearch.matches(paren, "%"))
end)

check("( and % that are not there do not match", function()
  assert(not EntrySearch.matches(paren, "(x"))
  assert(not EntrySearch.matches(paren, "%d"))
  assert(not EntrySearch.matches(paren, "["))
end)

check("filter takes a query with ( in it", function()
  assert(ids(EntrySearch.filter({ paren, plain }, "(")) == "5")
end)

print("\n== blank and nil queries ==")

check("a blank or nil query matches everything", function()
  assert(EntrySearch.matches(plain, ""))
  assert(EntrySearch.matches(plain, nil))
  assert(EntrySearch.matches(plain, "   "))
end)

check("a blank or nil query returns the same list object", function()
  local list = { plain, byAuthorName }
  assert(rawequal(EntrySearch.filter(list, ""), list))
  assert(rawequal(EntrySearch.filter(list, nil), list))
  assert(rawequal(EntrySearch.filter(list, "   "), list))
end)

print("\n== filter ==")

check("filter keeps the matching entries in their order", function()
  local list = {
    { id = 1, title = "Xa" }, { id = 2, title = "Yb" },
    { id = 3, title = "xc" }, { id = 4, title = "Xd" },
  }
  local out = EntrySearch.filter(list, "x")
  assert(ids(out) == "1,3,4", ids(out))
end)

check("filter returns a new list, and leaves the one it was given alone", function()
  local list = { plain, byAuthorName }
  local out = EntrySearch.filter(list, "e")
  assert(not rawequal(out, list), "same list object")
  assert(#out == 2 and #list == 2, "lengths changed")
end)

check("filter with nothing matching gives an empty new list", function()
  local list = { plain, byAuthorName }
  local out = EntrySearch.filter(list, "zzz")
  assert(#out == 0 and not rawequal(out, list))
end)

check("filter finds an entry by its author from any shape", function()
  local all = { plain, byAuthorName, byContributions, byBookSeries }
  assert(ids(EntrySearch.filter(all, "gaiman")) == "3")
  assert(ids(EntrySearch.filter(all, "herbert")) == "2")
  assert(ids(EntrySearch.filter(all, "middle-earth")) == "4")
end)

check("filter over no entries gives an empty list", function()
  assert(#EntrySearch.filter(nil, "x") == 0)
end)

print("\n== missing parts ==")

check("an empty entry matches a blank query and nothing else", function()
  assert(EntrySearch.matches({}, ""))
  assert(not EntrySearch.matches({}, "x"))
end)

check("odd shapes are ignored, not an error", function()
  local odd = { author = {}, contributions = { 5, { author = nil } }, book_series = { {}, { series = {} } } }
  assert(not EntrySearch.matches(odd, "x"))
  assert(EntrySearch.haystack(nil) == "")
end)

r.finish()
