package.path = "./?.lua;" .. package.path
local Community = require("hardcover/lib/community")
local function eq(a, b, m) if a ~= b then error((m or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end

local d = Community.distribution({ ratings_distribution = {
  { count = 2, rating = 5.0 }, { count = 2, rating = 4.0 }, { count = 1, rating = 0.5 }, { count = 0, rating = 3 },
  { count = 3, rating = 9 }, "junk", { count = "x", rating = 1 } } })
eq(d.total, 5, "total") eq(d.counts[10], 2, "five") eq(d.counts[8], 2, "four") eq(d.counts[1], 1, "half")
eq(d.average, (10 + 8 + 0.5) / 5, "average")
eq(Community.distribution({}), nil, "none") eq(Community.distribution({ ratings_distribution = {} }), nil, "empty")
eq(Community.distribution(nil), nil, "nil")

local t = Community.tags({ cached_tags = {
  Genre = { { tag = "Fantasy", count = 5 }, { tag = "Magic", count = 5 }, { tag = "Zero", count = 0 } },
  Mood = { { tag = "lighthearted", count = 74 }, { tag = "adventurous", count = 137 }, { tag = "spoilery", count = 900, spoilerRatio = 0.9 } },
  ["Content Warning"] = { { tag = "bullying", count = 3, spoilerRatio = 0.1 } },
} }, 2)
eq(#t.genres, 2, "zero count dropped") eq(t.genres[1].tag, "Fantasy", "tie by name")
eq(t.moods[1].tag, "Adventurous", "most used first, capitalised") eq(#t.moods, 2, "spoiler dropped")
eq(t.warnings[1].tag, "Bullying", "warning")
eq(#Community.tags(nil).genres, 0, "nil book")
eq(#Community.tags({ cached_tags = "x" }).moods, 0, "junk tags")
local many = {}
for i = 1, 20 do many[i] = { tag = "t" .. i, count = i } end
eq(#Community.tags({ cached_tags = { Mood = many } }).moods, 8, "default limit")
print("community_harness OK")
