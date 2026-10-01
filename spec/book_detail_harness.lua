-- The book detail screen: what the dialog builds, and the query behind it.
--
-- Found by reading the code against KOReader's own widget source (the emulator
-- that would render it needs a KOReader install). Each check below is one of
-- those defects:
--
--   * a nil subtitle left a hole in the VerticalGroup constructor, and the
--     group's ipairs stopped at it: everything after the title vanished
--   * the Back key was bound to an event with no handler
--   * TextWidget reads max_width, not width, so long text ran off the screen
--   * a TextBoxWidget given a height shows only the lines that fit
--   * the edition query was sent the book id, never the edition id
--
-- The widgets here are small stand-ins that keep their children in plain
-- arrays, so the structure the dialog builds can be walked and counted.
--
-- Run with:  lua spec/book_detail_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function make()
  local t = {}
  return setmetatable(t, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end

-- a widget class whose instances are the table they were built from, so a
-- constructor's children stay in a plain array
local function widget(kind)
  local C = { kind = kind }
  C.__index = C
  function C:new(o)
    o = o or {}
    o.kind = kind
    return setmetatable(o, C)
  end
  function C:getSize() return { w = self.width or 0, h = 20 } end
  function C:free() end
  return C
end

local FocusManager = {}
function FocusManager:extend(o)
  o = o or {}
  o.__index = o
  return setmetatable(o, { __index = FocusManager })
end
function FocusManager:new(o)
  o = setmetatable(o or {}, self)
  o.key_events = {}
  o:init()
  return o
end

local widgets = {
  ["ui/widget/focusmanager"] = FocusManager,
  ["ui/widget/textwidget"] = widget("Text"),
  ["ui/widget/textboxwidget"] = widget("TextBox"),
  ["ui/widget/button"] = widget("Button"),
  ["ui/widget/horizontalgroup"] = widget("HGroup"),
  ["ui/widget/horizontalspan"] = widget("HSpan"),
  ["ui/widget/verticalgroup"] = widget("VGroup"),
  ["ui/widget/verticalspan"] = widget("VSpan"),
  ["ui/widget/container/centercontainer"] = widget("Center"),
  ["ui/widget/container/framecontainer"] = widget("Frame"),
  ["ui/widget/container/leftcontainer"] = widget("Left"),
  ["ui/widget/container/scrollablecontainer"] = widget("Scroll"),
  ["ui/geometry"] = { new = function(_, t) return t end },
  ["device"] = { screen = {
    getWidth = function() return 1000 end,
    getHeight = function() return 1400 end,
    scaleBySize = function(_, n) return n end,
    getSize = function() return { w = 1000, h = 1400 } end,
  } },
}

package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
local real_require = require
_G.require = function(name)
  if widgets[name] then return widgets[name] end
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local BookDetailDialog = real_require("hardcover/lib/ui/book_detail_dialog")
local Shelf = real_require("hardcover/lib/shelf")
local Api = real_require("hardcover/lib/hardcover_api")

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local function kinds(group)
  local out = {}
  for _, child in ipairs(group) do out[#out + 1] = child.kind end
  return out
end

local function detail(book)
  return { book = book, status_id = 2, user_rating = 4 }
end

print("\n== the body is built whole ==")

check("a book with no subtitle still shows its status, metadata and description", function()
  local d = BookDetailDialog:new { detail = detail({ title = "T", pages = 300, release_year = 2001, description = "About it." }) }
  local k = kinds(d.content_group)
  -- title, status, spacer, 2 metadata rows, spacer, description, spacer
  assert(#k == 8, "only " .. #k .. " of 8 widgets reached the group: " .. table.concat(k, ","))
end)

check("a book with a subtitle shows it too", function()
  local d = BookDetailDialog:new { detail = detail({ title = "T", subtitle = "A Subtitle", pages = 300 }) }
  local k = kinds(d.content_group)
  assert(k[2] == "TextBox", "the subtitle is not second: " .. table.concat(k, ","))
  assert(#k >= 6, "the group stopped short: " .. table.concat(k, ","))
end)

check("a detail rebuilt from a saved row (no edition fields) is whole", function()
  local row = Shelf.normalizeEntry({ id = 1, status_id = 1, book = { book_id = 7, title = "Saved", pages = 100, description = "d" } })
  local d = BookDetailDialog:new { detail = Shelf.detailFromEntry(row) }
  assert(#kinds(d.content_group) >= 5, table.concat(kinds(d.content_group), ","))
end)

print("\n== text that must fit ==")

check("a long title wraps instead of running off the screen", function()
  local d = BookDetailDialog:new { detail = detail({ title = string.rep("Long ", 40) }) }
  assert(d.title_text.kind == "TextBox", "title is " .. tostring(d.title_text.kind))
  assert(d.title_text.width == d.width)
end)

check("single-line text is limited with max_width, the field TextWidget reads", function()
  local d = BookDetailDialog:new { detail = detail({ title = "T" }) }
  assert(d.status_text.max_width == d.width, "status max_width " .. tostring(d.status_text.max_width))
  local loading = BookDetailDialog:new { loading = true }
  assert(loading.loading_text.max_width == loading.width, "loading text is not limited")
end)

check("metadata labels sit in a fixed-width column and values wrap", function()
  local d = BookDetailDialog:new { detail = detail({ title = "T", pages = 300, release_year = 2001 }) }
  local want = math.floor(d.width * 0.32)
  assert(#d.meta_rows == 2, "rows: " .. #d.meta_rows)
  for _, row in ipairs(d.meta_rows) do
    assert(row[1].kind == "Left" and row[1].dimen.w == want, "label column is not fixed")
    assert(row[3].kind == "TextBox", "value does not wrap")
  end
end)

check("the description is not clipped to a fixed height", function()
  local d = BookDetailDialog:new { detail = detail({ title = "T", description = string.rep("word ", 2000) }) }
  assert(d.description_text.height == nil, "height = " .. tostring(d.description_text.height))
end)

print("\n== leaving the screen ==")

check("every key the dialog binds has a handler", function()
  local d = BookDetailDialog:new { detail = detail({ title = "T" }) }
  local count = 0
  for name in pairs(d.key_events) do
    count = count + 1
    assert(type(BookDetailDialog["on" .. name]) == "function", "key event " .. name .. " has no handler (on" .. name .. ")")
  end
  assert(count > 0 and d.key_events.CloseDetail, "Back is not bound")
end)

check("Back works on the loading screen too", function()
  local d = BookDetailDialog:new { loading = true }
  assert(d.key_events.CloseDetail, "no Back binding while loading")
end)

print("\n== the numbers shown ==")

check("a rating of zero is not shown as a community rating", function()
  local rows = Shelf.detailRows({ title = "T", rating = 0, ratings_count = 0 })
  for _, row in ipairs(rows) do assert(row.label ~= "Community rating", "shown: " .. tostring(row.value)) end
  local rated = Shelf.detailRows({ title = "T", rating = 4.2, ratings_count = 10 })
  local found = false
  for _, row in ipairs(rated) do if row.label == "Community rating" then found = true end end
  assert(found, "a real rating disappeared")
end)

print("\n== the query behind it ==")

local captured
Api.query = function(_, q, vars)
  captured = { q = q, vars = vars }
  if vars.editionId then
    return { editions = { { id = vars.editionId, edition_format = "Hardcover", pages = 300,
      book = { book_id = 7, title = "T" } } } }
  end
  return { books = { { book_id = 7, title = "T" } } }
end

check("a linked edition is looked up by its own id", function()
  captured = nil
  local result = Api:getBookDetail(7, 1, 555)
  assert(result and result.book.title == "T", "no detail came back")
  assert(captured.vars.editionId == 555, "editionId sent: " .. tostring(captured.vars.editionId))
  assert(captured.vars.bookId == nil, "the book id was sent for an edition query")
  assert(captured.q:find("$editionId", 1, true), "the query never uses $editionId")
  assert(not captured.q:find("$bookId", 1, true), "the query still declares an unused $bookId")
end)

check("with no edition, the book id is used", function()
  captured = nil
  local result = Api:getBookDetail(7, 1, nil)
  assert(result and result.book.title == "T")
  assert(captured.vars.bookId == 7 and captured.vars.editionId == nil)
end)

r.finish()
