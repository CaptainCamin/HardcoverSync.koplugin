-- Sorting a shelf's books.
--
-- Run with:  lua spec/shelf_sort_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path
local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local ShelfSort = require("hardcover/lib/shelf_sort")

local function book(id, over)
  local b = { book_id = id, title = "Book " .. id, authors = "Au Thor", release_year = 2000, pages = 300,
    users_count = 10, community_rating = 4, user_rating = nil }
  for k, v in pairs(over or {}) do
    if v == "NONE" then b[k] = nil else b[k] = v end
  end
  return b
end

local function ids(list)
  local out = {}
  for i, b in ipairs(list) do out[i] = b.book_id end
  return table.concat(out, ",")
end

print("\n== the options ==")

check("the default is the order the shelf arrives in", function()
  assert(ShelfSort.DEFAULT == "added_desc")
  assert(ids(ShelfSort.sort({ book(1), book(2), book(3) }, nil)) == "1,2,3")
  assert(ids(ShelfSort.sort({ book(1), book(2), book(3) }, "added_desc")) == "1,2,3")
end)

check("every option is a known key with a label, and an unknown key changes nothing", function()
  for _, o in ipairs(ShelfSort.OPTIONS) do
    assert(ShelfSort.isKey(o.key) and ShelfSort.label(o.key) == o.label)
  end
  assert(not ShelfSort.isKey("bogus") and not ShelfSort.isKey(nil))
  assert(ids(ShelfSort.sort({ book(1), book(2) }, "bogus")) == "1,2")
end)

check("the input list is not changed", function()
  local input = { book(1, { title = "B" }), book(2, { title = "A" }) }
  ShelfSort.sort(input, "title")
  assert(ids(input) == "1,2")
end)

print("\n== ordering ==")

check("oldest added first reverses the arrival order", function()
  assert(ids(ShelfSort.sort({ book(1), book(2), book(3) }, "added_asc")) == "3,2,1")
end)

check("title, ignoring a leading The, A or An", function()
  local list = { book(1, { title = "The Dispossessed" }), book(2, { title = "A Wizard of Earthsea" }),
    book(3, { title = "Babel" }), book(4, { title = "An Ocean" }) }
  assert(ids(ShelfSort.sort(list, "title")) == "3,1,4,2", ids(ShelfSort.sort(list, "title")))
end)

check("a title that is only an article is not emptied", function()
  local list = { book(1, { title = "A" }), book(2, { title = "Aa" }) }
  assert(ids(ShelfSort.sort(list, "title")) == "1,2")
end)

check("author by surname, ties keep the arrival order", function()
  local list = { book(1, { authors = "Ursula K. Le Guin" }), book(2, { authors = "Octavia E. Butler" }),
    book(3, { authors = "Ursula K. Le Guin" }), book(4, { authors = "Dan Simmons, Someone Else" }) }
  assert(ids(ShelfSort.sort(list, "author")) == "2,1,3,4", ids(ShelfSort.sort(list, "author")))
end)

check("year, both ways, and books with no year go last either way", function()
  local list = { book(1, { release_year = 1990 }), book(2, { release_year = "NONE" }), book(3, { release_year = 2010 }) }
  assert(ids(ShelfSort.sort(list, "year_desc")) == "3,1,2", ids(ShelfSort.sort(list, "year_desc")))
  assert(ids(ShelfSort.sort(list, "year_asc")) == "1,3,2", ids(ShelfSort.sort(list, "year_asc")))
end)

check("pages, both ways, no page count last", function()
  local list = { book(1, { pages = 500 }), book(2, { pages = "NONE" }), book(3, { pages = 120 }) }
  assert(ids(ShelfSort.sort(list, "pages_asc")) == "3,1,2")
  assert(ids(ShelfSort.sort(list, "pages_desc")) == "1,3,2")
end)

check("most readers, community rating and my rating, highest first", function()
  local list = { book(1, { users_count = 5, community_rating = 3.5, user_rating = 2 }),
    book(2, { users_count = 50, community_rating = 4.5 }), book(3, { users_count = 20, community_rating = 4.0, user_rating = 5 }) }
  assert(ids(ShelfSort.sort(list, "popular")) == "2,3,1")
  assert(ids(ShelfSort.sort(list, "rating")) == "2,3,1")
  assert(ids(ShelfSort.sort(list, "my_rating")) == "3,1,2", ids(ShelfSort.sort(list, "my_rating")))
end)

check("equal values keep the arrival order (the sort is stable)", function()
  local list = {}
  for i = 1, 40 do list[i] = book(i, { pages = (i % 2 == 0) and 100 or 200 }) end
  local sorted = ShelfSort.sort(list, "pages_asc")
  local evens, odds = {}, {}
  for _, b in ipairs(sorted) do
    local t = (b.book_id % 2 == 0) and evens or odds
    t[#t + 1] = b.book_id
  end
  for _, group in ipairs({ evens, odds }) do
    for i = 2, #group do assert(group[i] > group[i - 1], "ties were shuffled") end
  end
end)

check("an empty or missing list is fine", function()
  assert(#ShelfSort.sort({}, "title") == 0 and #ShelfSort.sort(nil, "title") == 0)
end)

r.finish()
