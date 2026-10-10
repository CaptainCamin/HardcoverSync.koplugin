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

-- The OAuth scope that lets a sign-in add books to lists and take them off
-- (insert_list_book / delete_list_book). This is the one place its name is
-- written down: auth.lua and default_config.lua spell it out in the scope they
-- ask for, and a spec keeps the three in step. Reading your lists needs nothing
-- new. NOT yet confirmed against Hardcover's OAuth app that approving it works.
Lists.WRITE_SCOPE = "write:lists"

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

-- How many books a list holds. Counted (list_books_aggregate) when the answer has the
-- count: the list's own books_count is a stored number that can be off (26 for a list of
-- 25, seen on the real API).
local function bookCount(list)
  local aggregate = type(list.list_books_aggregate) == "table" and list.list_books_aggregate.aggregate
  return tonumber(type(aggregate) == "table" and aggregate.count or nil) or tonumber(list.books_count) or 0
end

--
-- What says whether a saved list is still right: when Hardcover last changed the list,
-- and how many books it holds. Adding or removing a book moves the time (checked against
-- the real API: the time follows the new book by milliseconds); the count is there too,
-- so a removal is seen even if the time did not move. nil when the answer had no time,
-- which never matches, so such a list is always fetched.
--
function Lists.fingerprint(r)
  if type(r) ~= "table" or type(r.updated_at) ~= "string" or r.updated_at == "" then return nil end
  return r.updated_at .. "|" .. tostring(tonumber(r.count) or 0)
end

local function row(list, source, owner)
  if type(list) ~= "table" or not list.id then return nil end
  local r = {
    id = list.id,
    source = source, -- "mine" or "followed": which part of `me` the books are read through
    name = (type(list.name) == "string" and list.name ~= "") and list.name or "Untitled list",
    count = bookCount(list),
    ranked = list.ranked and true or false,
    private = list.privacy_setting_id ~= nil and list.privacy_setting_id ~= 1 or nil,
    owner = owner,
    covers = covers(list.list_books),
    updated_at = type(list.updated_at) == "string" and list.updated_at or nil,
  }
  r.fingerprint = Lists.fingerprint(r)
  return r
end

--
-- `me` from Api:getListCount: each list's id, source and fingerprint, enough to tell
-- whether the saved lists are still right without fetching them. Returns
-- { { id, source, fingerprint }, ... }, yours first.
--
function Lists.marks(me)
  if type(me) == "table" and me[1] ~= nil then me = me[1] end
  local marks = {}
  if type(me) ~= "table" then return marks end
  local function add(list, source)
    if type(list) == "table" and list.id then
      local r = { id = list.id, count = bookCount(list), updated_at = list.updated_at }
      marks[#marks + 1] = { id = list.id, source = source, fingerprint = Lists.fingerprint(r) }
    end
  end
  for _, list in ipairs(type(me.lists) == "table" and me.lists or {}) do add(list, "mine") end
  for _, followed in ipairs(type(me.followed_lists) == "table" and me.followed_lists or {}) do
    add(type(followed) == "table" and followed.list or nil, "followed")
  end
  return marks
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
  entry.position = tonumber(list_book.position)
  if ranked and tonumber(list_book.position) then
    entry.rank = tonumber(list_book.position) + 1
  end
  return entry
end

--
-- Adding a book to lists, from the book's details screen.
--
-- `me` from Api:getBookLists: your own lists (not the ones you follow, which cannot
-- be added to), each with `list_books` holding the rows that are this book (its own
-- id is what delete_list_book wants). Returns rows { id, name, count, ranked,
-- private, on, list_book_id }, in the order the API gave them.
--
function Lists.membership(me)
  if type(me) == "table" and me[1] ~= nil then me = me[1] end
  local rows = {}
  if type(me) ~= "table" then return rows end
  for _, list in ipairs(type(me.lists) == "table" and me.lists or {}) do
    local r = row(list, "mine")
    if r then
      local first = type(list.list_books) == "table" and list.list_books[1]
      local id = type(first) == "table" and tonumber(first.id) or nil
      r.covers = nil
      r.on = type(first) == "table" -- on the list even if the row's id did not come
      r.list_book_id = id
      rows[#rows + 1] = r
    end
  end
  return rows
end

-- "A, B" for the lists the book is on; nil when it is on none.
function Lists.onNames(rows)
  local names = {}
  for _, r in ipairs(type(rows) == "table" and rows or {}) do
    if r.on then names[#names + 1] = r.name end
  end
  return #names > 0 and table.concat(names, ", ") or nil
end

-- A picker row: the name and how many books the list holds (the tick box is the row's own). "..." while a change is on its way.
function Lists.pickerLabel(r)
  local text = string.format("%s (%d)", r.name, r.count or 0)
  if r.ranked then text = text .. DOT .. "ranked" end
  if r.busy then text = text .. " \226\128\166" end
  return text
end

-- The book went on / came off the list: the row and its count follow.
function Lists.markAdded(r, list_book_id)
  r.on, r.list_book_id, r.count = true, tonumber(list_book_id), (r.count or 0) + 1
end

function Lists.markRemoved(r)
  r.on, r.list_book_id, r.count = false, nil, math.max(0, (r.count or 0) - 1)
end

--
-- The ListBookInput for adding `book_id` to a list that holds `count` books. The
-- position is the end of the list: on a ranked list that puts the new book last
-- rather than on top of #1, and on an unranked one it is ignored. No edition: the
-- list is of the book, not of one edition of it.
--
--
-- What a tap on a list's tick box does, from the row as it is now.
--   "add"     the book goes on the list
--   "remove"  it comes off, by the list_books row id the row already knows
--   "lookup"  it was added a moment ago and Hardcover's answer did not say which row it
--             made: ask which, then remove (see resolveLookup)
--
function Lists.togglePlan(r)
  if not r.on then return "add" end
  if r.list_book_id then return "remove" end
  return "lookup"
end

--
-- What a fresh look at the book's lists says about taking it off list `list_id`. `fresh`
-- is getBookLists's answer (nil when it failed).
--   "remove", list_book_id   take that row off
--   "already_off"            it is no longer on the list: nothing to send
--   "not_found"              the list is not in the answer
--   "no_row_id"              it is on the list but the answer has no row id for it
--
function Lists.resolveLookup(fresh, list_id)
  local found
  for _i, f in ipairs(fresh or {}) do
    if f.id == list_id then found = f end
  end
  if not found then return "not_found" end
  if not found.on then return "already_off" end
  if not found.list_book_id then return "no_row_id" end
  return "remove", found.list_book_id
end

function Lists.insertObject(book_id, list_id, count)
  return { book_id = book_id, list_id = list_id, position = tonumber(count) or 0 }
end

-- The list_book id out of an insert_list_book answer, whatever shape it came in
-- (the payload's own id, or a nested list_book); nil when there is none.
function Lists.listBookId(answer)
  if type(answer) ~= "table" then return nil end
  local nested = type(answer.list_book) == "table" and answer.list_book.id or nil
  return tonumber(answer.id) or tonumber(nested)
end

--
-- Did this failure say the sign-in lacks the scope to change lists? Any text in
-- the error mentioning a scope (insufficient_scope, "missing scope write:lists"),
-- or a 403. Takes what Api:query hands back, or a string, or junk.
--
function Lists.isScopeError(err)
  if type(err) == "table" and tonumber(err.status) == 403 then return true end
  local function mentions(value, depth)
    if type(value) == "string" then return value:lower():find("scope", 1, true) ~= nil end
    if type(value) ~= "table" or depth > 4 then return false end
    for _, v in pairs(value) do
      if mentions(v, depth + 1) then return true end
    end
    return false
  end
  return mentions(err, 0)
end

return Lists
