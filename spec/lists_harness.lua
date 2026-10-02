-- Lists as plain data: your lists and the ones you follow from the shape `me`
-- comes back in, the small print under each, and a list's books as shelf rows.
--
-- Run with:  lua spec/lists_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local Lists = dofile(PLUGIN .. "/hardcover/lib/lists.lua")

local function image(url) return { url = url, width = 1, height = 2 } end

local me = { {
  lists = {
    { id = 1, name = "To Read - SciFi", books_count = 7, ranked = true, privacy_setting_id = 1,
      list_books = { { book = { cached_image = image("a.jpg") } }, { book = { cached_image = image("b.jpg") } },
                     { book = {} }, { book = { cached_image = image("c.jpg") } },
                     { book = { cached_image = image("d.jpg") } } } },
    { id = 2, name = "", books_count = 1, ranked = false, privacy_setting_id = 3, list_books = {} },
    { name = "no id" },
  },
  followed_lists = {
    { list = { id = 106, name = "Top 25", books_count = 26, ranked = false, user = { username = "hardcover" },
               list_books = { { book = { cached_image = image("z.jpg") } } } } },
    { list = nil },
  },
} }

print("\n== reading `me` ==")

check("your lists and followed lists come out separately, in order, skipping rows with no id", function()
  local out = Lists.normalize(me)
  assert(#out.mine == 2 and #out.following == 1)
  assert(out.mine[1].id == 1 and out.mine[1].source == "mine" and out.mine[1].ranked == true)
  assert(out.following[1].source == "followed" and out.following[1].owner == "hardcover")
end)

check("a list shows at most three covers, skipping books with none", function()
  local out = Lists.normalize(me)
  assert(table.concat(out.mine[1].covers, ",") == "a.jpg,b.jpg,c.jpg", table.concat(out.mine[1].covers, ","))
  assert(#out.mine[2].covers == 0)
end)

check("an unnamed list gets a name, and a private one is marked", function()
  local out = Lists.normalize(me)
  assert(out.mine[2].name == "Untitled list" and out.mine[2].private == true)
  assert(out.mine[1].private == nil)
end)

check("junk never raises: nil, a string, empty tables, the bare object instead of an array", function()
  for _, junk in ipairs({ "x", 5, {}, { {} }, { { lists = "no" } } }) do
    local out = Lists.normalize(junk)
    assert(#out.mine == 0 and #out.following == 0)
  end
  assert(#Lists.normalize(nil).mine == 0)
  assert(#Lists.normalize(me[1]).mine == 2, "the bare object is accepted too")
end)

print("\n== the small print ==")

check("count, ranked, owner and private read as one line", function()
  local out = Lists.normalize(me)
  assert(Lists.subtitle(out.mine[1]) == "7 books \194\183 ranked", Lists.subtitle(out.mine[1]))
  assert(Lists.subtitle(out.mine[2]) == "1 book \194\183 private")
  assert(Lists.subtitle(out.following[1]) == "26 books \194\183 by hardcover")
  assert(Lists.countText(nil) == "0 books")
end)

print("\n== a list's books ==")

check("a list book becomes a shelf row, ranked from 1 only on a ranked list", function()
  local lb = { id = 77, position = 0, date_added = "2025-01-01", book = { book_id = 5, title = "Wool",
    contributions = { { author = { name = "Hugh Howey" } } }, cached_image = image("w.jpg") } }
  local e = Lists.entry(lb, true)
  assert(e.title == "Wool" and e.book_id == 5 and e.authors == "Hugh Howey" and e.rank == 1)
  assert(e.user_book_id == nil and e.list_book_id == 77)
  assert(Lists.entry(lb, false).rank == nil)
  lb.position = 4
  assert(Lists.entry(lb, true).rank == 5)
end)

check("a bare or empty row does not raise", function()
  assert(Lists.entry(nil, true).title)
  assert(Lists.entry({}, true).rank == nil)
end)

r.finish()
