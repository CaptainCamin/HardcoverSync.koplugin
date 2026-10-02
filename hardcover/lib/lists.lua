-- Hardcover lists, as plain data.
--
-- No KOReader requires, so it runs under stock Lua in the spec suite; the dialogs
-- (ui/lists_dialog.lua and the shelf screen a list opens in) only draw what this
-- returns.
--
-- What the real API does, which this is written around (checked against live
-- data): your own lists and the lists you follow both come back through `me`, with
-- the permissions the plugin already has -- looking a list up by id, or browsing
-- other people's, needs read:lists and is not used. A list is `ranked` (its order
-- is the point: a top ten) or not (an unordered collection), and each book carries
-- a `position` (0 first).

local Shelf = require("hardcover/lib/shelf")

local Lists = {}

-- How many covers the index shows beside each list
Lists.COVERS = 3

local DOT = " \194\183 "

local function covers(list_books)
  local urls = {}
  for _, list_book in ipairs(type(list_books) == "table" and list_books or {}) do
    local cover = Shelf.coverOf(type(list_book) == "table" and list_book.book or nil)
    if cover then urls[#urls + 1] = cover.url end
    if #urls >= Lists.COVERS then break end
  end
  return urls
end

local function row(list, source, owner)
  if type(list) ~= "table" or not list.id then return nil end
  return {
    id = list.id,
    source = source, -- "mine" or "followed": which part of `me` the books are read through
    name = (type(list.name) == "string" and list.name ~= "") and list.name or "Untitled list",
    count = tonumber(list.books_count) or 0,
    ranked = list.ranked and true or false,
    private = list.privacy_setting_id ~= nil and list.privacy_setting_id ~= 1 or nil,
    owner = owner,
    covers = covers(list.list_books),
  }
end

--
-- `me` from Api:getLists (one object, or the one-element array Hasura returns for a
-- relationship named `me`) as { mine = { rows }, following = { rows } }, in the
-- order the API gave them.
--
function Lists.normalize(me)
  if type(me) == "table" and me[1] ~= nil then me = me[1] end
  local result = { mine = {}, following = {} }
  if type(me) ~= "table" then return result end

  for _, list in ipairs(type(me.lists) == "table" and me.lists or {}) do
    local r = row(list, "mine")
    if r then result.mine[#result.mine + 1] = r end
  end
  for _, followed in ipairs(type(me.followed_lists) == "table" and me.followed_lists or {}) do
    local list = type(followed) == "table" and followed.list
    local owner = type(list) == "table" and type(list.user) == "table" and list.user.username or nil
    local r = row(list, "followed", owner)
    if r then result.following[#result.following + 1] = r end
  end
  return result
end

-- "7 books", "1 book"
function Lists.countText(count)
  count = tonumber(count) or 0
  return count == 1 and "1 book" or string.format("%d books", count)
end

-- The small print under a list's name: "7 books · ranked", "42 books · by hardcover".
function Lists.subtitle(row)
  local parts = { Lists.countText(row.count) }
  if row.ranked then parts[#parts + 1] = "ranked" end
  if row.owner then parts[#parts + 1] = "by " .. row.owner end
  if row.private then parts[#parts + 1] = "private" end
  return table.concat(parts, DOT)
end

--
-- A shelf row for one book in a list (a `list_books` row with its book). It is the
-- same shape a shelf entry has, so the shelf screen and the book details take it
-- unchanged, plus `rank` (1 for the first) on a ranked list.
--
function Lists.entry(list_book, ranked)
  list_book = type(list_book) == "table" and list_book or {}
  local entry = Shelf.normalizeEntry({
    id = list_book.id,
    date_added = list_book.date_added,
    book = list_book.book,
  })
  entry.user_book_id = nil -- a list entry is not one of your own library rows
  entry.list_book_id = list_book.id
  if ranked and tonumber(list_book.position) then
    entry.rank = tonumber(list_book.position) + 1
  end
  return entry
end

return Lists
