-- The Journal tab's body (journal_body.lua): what it builds for your journal, a page at a time.
--
-- The widgets here are small stand-ins that keep their children in plain arrays, so the structure the
-- body builds can be walked and read; the drawing itself is checked on a real KOReader
-- (spec/emu/scenarios/journal_tab.lua). Plugin-owned modules (Theme, Journal, CoverCells, Hosted)
-- are the real ones.
--
-- Usage: lua spec/journal_body_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function make()
  return setmetatable({}, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end

local function widget(kind)
  local C = { kind = kind }
  C.__index = C
  function C:new(o)
    o = o or {}
    o.kind = kind
    return setmetatable(o, C)
  end
  function C:getSize() return { w = self.width or 10, h = 20 } end
  function C:free() end
  return C
end

local InputContainer = {}
function InputContainer:extend(o)
  o = o or {}
  o.__index = o
  return setmetatable(o, { __index = InputContainer })
end
function InputContainer:new(o)
  o = setmetatable(o or {}, self)
  o.key_events = {}
  o:init()
  return o
end

local touch = true
local dirty = 0
local widgets = {
  ["ui/widget/container/inputcontainer"] = InputContainer,
  ["ui/widget/horizontalgroup"] = widget("HGroup"),
  ["ui/widget/verticalgroup"] = widget("VGroup"),
  ["ui/widget/container/centercontainer"] = widget("Center"),
  ["ui/widget/container/leftcontainer"] = widget("Left"),
  ["ui/widget/container/framecontainer"] = widget("Frame"),
  ["ui/widget/overlapgroup"] = widget("Overlap"),
  ["ui/widget/textwidget"] = widget("Text"),
  ["ui/widget/textboxwidget"] = widget("TextBox"),
  ["hardcover/lib/ui/tap_row"] = widget("TapRow"),
  ["ui/geometry"] = { new = function(_, t) return t end },
  ["ui/gesturerange"] = { new = function(_, t) return t end },
  ["device"] = {
    isTouchDevice = function() return touch end,
    hasKeys = function() return false end,
    screen = {
      getWidth = function() return 1080 end,
      getHeight = function() return 1440 end,
      scaleBySize = function(_, n) return n end,
    },
  },
  ["ui/uimanager"] = { setDirty = function() dirty = dirty + 1 end },
  ["hardcover/lib/ui/components/scroll_control"] = {
    gutter = function() return 18 end,
    paged = function(opts) return widget("Control"):new { opts = opts } end,
  },
  ["hardcover/lib/ui/components/button"] = { new = function(o) return widget("Button"):new { text = o.label, callback = o.callback } end },
  ["hardcover/lib/ui/components/draw"] = { chevron = function() return widget("Chevron"):new {} end },
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

local Body = real_require("hardcover/lib/ui/journal_body")
local Journal = real_require("hardcover/lib/journal")

-- ---------------------------------------------------------------- fixtures
local NOW = Journal.epoch("2026-10-22T12:00:00Z")

local function entry(n, over)
  local e = { key = "progress_updated:" .. n, id = n, kind = "event", action = "Updated progress to " .. n .. "%",
    at = "2026-10-01T12:00:00Z", book_id = 100 + n, title = "Book " .. n, authors = "Author " .. n,
    cover_url = "https://covers.example/" .. n .. ".jpg" }
  for k, v in pairs(over or {}) do e[k] = v end
  return e
end

local function many(n)
  local out = {}
  for i = 1, n do out[i] = entry(i) end
  return out
end

local shell = { isActive = function() return true end }
local function build(opts)
  opts = opts or {}
  opts.shell = shell
  opts.width, opts.height = 1080, opts.height or 1000
  opts.image_loader = { loadImages = function() return {}, function() end end }
  opts.now = function() return NOW end
  return Body:new(opts)
end

-- every widget of a kind under `root`, in order
local function all(root, kind, out, seen)
  out, seen = out or {}, seen or {}
  if type(root) ~= "table" or seen[root] then return out end
  seen[root] = true
  if root.kind == kind then out[#out + 1] = root end
  for _, child in ipairs(root) do all(child, kind, out, seen) end
  return out
end

local function texts(body)
  local out = {}
  for _, t in ipairs(all(body[1], "Text")) do out[#out + 1] = t.text end
  return out
end

local function hasText(body, text)
  for _, t in ipairs(texts(body)) do if t == text then return true end end
  return false
end

local check = r.test

-- 1000 high, rows 104 and a footer of 40: nine rows a page
print("\n== the rows ==")

check("an entry is a row: its book, what happened, the authors and the day", function()
  local body = build { entries = { entry(1) } }
  assert(hasText(body, "Book 1"), table.concat(texts(body), " | "))
  assert(hasText(body, "Updated progress to 1%"))
  assert(hasText(body, "Author 1 \194\183 Oct 1"))
  assert(#all(body[1], "TapRow") == 1 and #all(body[1], "Chevron") == 1, "a row that opens has a chevron")
end)

check("a row opens what it is about; one with nothing to open has no chevron and no tap", function()
  local got
  local e = entry(1)
  local body = build { entries = { e, entry(2, { book_id = false }) }, select_cb = function(x) got = x end }
  local taps = all(body[1], "TapRow")
  assert(#taps == 1, "taps " .. #taps)
  taps[1].callback()
  assert(got == e)
  assert(#all(body[1], "Chevron") == 1)
end)

check("a short journal fits one page: no scroll control, and the footer under the rows", function()
  local body = build { entries = many(3) }
  assert(body.pages == 1 and body.control == nil)
  assert(hasText(body, "Showing 1 to 3 of 3"), table.concat(texts(body), " | "))
end)

print("\n== a page at a time ==")

check("a long journal goes by page, every page the same rows, with the scroll control", function()
  local body = build { entries = many(20) }
  assert(body.per_page == 9 and body.pages == 3, "per page " .. tostring(body.per_page) .. ", pages " .. tostring(body.pages))
  assert(body.control and body.control.opts.pages() == 3 and body.control.opts.page() == 1)
  assert(#all(body[1], "TapRow") == 9)
  assert(hasText(body, "Showing 1 to 9 of 20"))
  body.control.opts.go(3)
  assert(body.page == 3 and #all(body[1], "TapRow") == 2 and hasText(body, "Showing 19 to 20 of 20"))
  assert(hasText(body, "Book 19") and not hasText(body, "Book 1"))
end)

check("a swipe up pages on and down pages back, and stops at either end", function()
  local body = build { entries = many(20) }
  assert(body:onSwipeJournal(nil, { direction = "north" }) and body.page == 2)
  body:onSwipeJournal(nil, { direction = "north" })
  body:onSwipeJournal(nil, { direction = "north" })
  assert(body.page == 3)
  body:onSwipeJournal(nil, { direction = "south" })
  assert(body.page == 2)
  assert(body:onSwipeJournal(nil, { direction = "east" }) == false)
  body:onPrevPage(); body:onPrevPage()
  assert(body.page == 1)
end)

check("with more on Hardcover, a Load more block follows the last row and the count says so", function()
  local asked = 0
  local body = build { entries = many(9), has_more = true, more_cb = function() asked = asked + 1 end }
  assert(body.pages == 2, "the block needs a page of its own here")
  assert(hasText(body, "Showing 1 to 9 of 9+"))
  body:setPage(2)
  local buttons = all(body[1], "Button")
  assert(#buttons == 1 and buttons[1].text == "Load more")
  buttons[1].callback()
  assert(asked == 1 and body.loading)
  assert(all(body[1], "Button")[1].text == "Loading\226\128\166")
  body:loadMore()
  assert(asked == 1, "a second tap while loading asks nothing")
end)

check("the answer to Load more opens on the page of the first new row", function()
  local body
  body = build { entries = many(9), has_more = true, more_cb = function() body:setEntries(many(25), true) end }
  body:loadMore()
  assert(body.page == 2 and hasText(body, "Book 10"), "page " .. body.page)
  assert(hasText(body, "Showing 10 to 18 of 25+"))
end)

check("a failed Load more leaves the block to try again", function()
  local body
  body = build { entries = many(3), has_more = true, more_cb = function() body:setLoading(false) end }
  body:loadMore()
  assert(not body.loading and all(body[1], "Button")[1].text == "Load more")
end)

check("new entries that are not Load more's answer leave the page where it was", function()
  local body = build { entries = many(20) }
  body:setPage(2)
  body:setEntries(many(21), false)
  assert(body.page == 2)
  body:setEntries(many(4), false)
  assert(body.page == 1, "a page that is gone goes back to the last there is")
end)

print("\n== in place of the rows ==")

check("a message stands alone, with no rows, pages or swipe", function()
  local body = build { message = "Loading your journal\226\128\166" }
  assert(#all(body[1], "TapRow") == 0 and #all(body[1], "TextBox") == 1)
  assert(body:onSwipeJournal(nil, { direction = "north" }) == false)
end)

check("an empty journal says there is nothing yet", function()
  local body = build { entries = many(2) }
  body:setEntries({}, false)
  assert(body.message and body.message:find("Nothing in your journal yet", 1, true), tostring(body.message))
end)

check("a fully filtered page still offers older entries", function()
  local rows = {}
  for i = 1, Journal.PAGE_SIZE do
    rows[i] = { id = i, event = "referral_to", action_at = "2026-10-22T12:00:00Z" }
  end
  local page = Journal.parse({ reading_journals = rows }, Journal.PAGE_SIZE)
  local body
  body = build { more_cb = function() body:setEntries({ entry(50) }, false) end }
  body:setEntries(page.entries, page.more)
  local buttons = all(body[1], "Button")
  assert(#buttons == 1 and buttons[1].text == "Load more", "older history is unreachable")
  buttons[1].callback()
  assert(hasText(body, "Book 50") and not body.has_more)
end)

check("without a touch screen there is no swipe to listen for", function()
  touch = false
  local body = build { entries = many(2) }
  touch = true
  assert(body.ges_events == nil)
end)

r.finish()
