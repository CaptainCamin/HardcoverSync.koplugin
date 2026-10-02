-- Other readers' reviews: the shaping module, the API query, and the dialog's
-- state handling (spoilers, paging, empty), without a KOReader.
--
-- The emulator scenario spec/emu/scenarios/reviews.lua drives the real widgets
-- with real taps; this covers the logic underneath so a regression names the
-- rule it broke.
--
-- Run with:  lua spec/reviews_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
support.preload_ui_stubs()
support.preload_http_stubs()
support.preload_json(PLUGIN)

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local ELLIPSIS = "\226\128\166"

-- ---------------------------------------------------------------- stubs
local Menu = support.capturing_menu()
package.preload["ui/widget/menu"] = function() return Menu end

local function container_stub(name)
  local base = {}
  base.__index = base
  base.new = function(cls, o)
    o = setmetatable(o or {}, cls)
    o.key_events, o.ges_events = {}, {}
    o.getSize = function() return { w = 600, h = 800 } end
    if o.init then o:init() end
    return o
  end
  base.extend = function(_, over)
    local child = over or {}
    setmetatable(child, { __index = base })
    child.__index = child
    child.new = function(cls, o) return base.new(child, o) end
    return child
  end
  package.loaded[name] = base
  return base
end
container_stub("ui/widget/container/centercontainer")
container_stub("ui/widget/container/inputcontainer")
support.preload_theme_stubs()
package.preload["ui/widget/container/topcontainer"] = package.preload["ui/widget/linewidget"]

package.preload["device"] = function()
  return { isTouchDevice = function() return false end, screen = {
    getWidth = function() return 1264 end,
    getHeight = function() return 1680 end,
    getSize = function() return { x = 0, y = 0, w = 1264, h = 1680 } end,
    scaleBySize = function(_, n) return n end,
  } }
end

local shown, closed, dirty = {}, {}, 0
package.preload["ui/uimanager"] = function()
  return {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function(_, w) closed[#closed + 1] = w end,
    setDirty = function() dirty = dirty + 1 end,
    nextTick = function(_, fn) fn() end,
    scheduleIn = function() end,
    unschedule = function() end,
  }
end
package.preload["ui/widget/textviewer"] = function()
  return { new = function(_, o) return o end }
end

-- ================================================================ helpers
local Reviews = require("hardcover/lib/reviews")

print("\n== who wrote it ==")
check("a private account (no user) is 'A reader'", function()
  assert(Reviews.reviewer({ user = nil }) == "A reader")
  assert(Reviews.reviewer({}) == "A reader")
end)
check("the display name wins over the username", function()
  assert(Reviews.reviewer({ user = { name = "Maya Okafor", username = "pt" } }) == "Maya Okafor")
end)
check("an empty display name falls back to the username, then to 'A reader'", function()
  assert(Reviews.reviewer({ user = { name = "  ", username = "pt" } }) == "pt")
  assert(Reviews.reviewer({ user = { name = "", username = "" } }) == "A reader")
end)

print("\n== stars, likes, date ==")
check("ratings read as 4.5* and 4*, and no rating is nothing", function()
  assert(Reviews.ratingText(4.5) == "4.5*")
  assert(Reviews.ratingText(4) == "4*")
  assert(Reviews.ratingText(0.5) == "0.5*")
  assert(Reviews.ratingText(nil) == nil)
  assert(Reviews.ratingText(0) == nil)
end)
check("likes are counted, singular for one, nothing for none", function()
  assert(Reviews.likesText(12) == "12 likes")
  assert(Reviews.likesText(1) == "1 like")
  assert(Reviews.likesText(0) == nil)
  assert(Reviews.likesText(nil) == nil)
end)
check("the date is the day only, and a missing one is nothing", function()
  assert(Reviews.dateText("2025-11-02T09:15:00") == "2025-11-02")
  assert(Reviews.dateText(nil) == nil)
  assert(Reviews.dateText("garbage") == nil)
end)

check("star glyphs are five, rounded to the nearest whole star", function()
  local FULL, EMPTY = "\226\152\133", "\226\152\134"
  assert(Reviews.stars(4.2) == FULL:rep(4) .. EMPTY)
  assert(Reviews.stars(4.5) == FULL:rep(5))
  assert(Reviews.stars(1) == FULL .. EMPTY:rep(4))
  assert(Reviews.stars(0) == "" and Reviews.stars(nil) == "")
end)

check("the summary is the book's title and community rating, or nil when there is nothing", function()
  local sum = Reviews.summary({ book = { title = "T", rating = 4.2, ratings_count = 120 } })
  assert(sum.title == "T" and sum.rating == 4.2 and sum.count == 120)
  local unrated = Reviews.summary({ book = { title = "T", rating = 0, ratings_count = 0 } })
  assert(unrated.title == "T" and unrated.rating == nil and unrated.count == nil)
  assert(Reviews.summary({ book = {} }) == nil and Reviews.summary(nil) == nil)
end)

check("a normalised review keeps its rating as a number for the stars", function()
  assert(Reviews.normalize({ id = 1, review_raw = "x", rating = 4.5 }).rating_value == 4.5)
  assert(Reviews.normalize({ id = 1, review_raw = "x" }).rating_value == nil)
end)

print("\n== truncation ==")
check("a short review is not cut", function()
  local text, cut = Reviews.excerpt("Short and lovely.")
  assert(text == "Short and lovely." and cut == false)
end)
check("a long review is cut to the budget at a word, with an ellipsis", function()
  local long = string.rep("word ", 200)
  local text, cut = Reviews.excerpt(long, 100)
  assert(cut == true)
  assert(text:sub(-#ELLIPSIS) == ELLIPSIS, "no ellipsis")
  assert(#text <= 100 + #ELLIPSIS, "too long: " .. #text)
  assert(not text:sub(1, -#ELLIPSIS - 1):match("%s$"), "ends in a space")
  assert(not text:match("wor" .. ELLIPSIS .. "$"), "cut mid-word")
end)
check("exactly at the budget is not cut, one over is", function()
  assert(select(2, Reviews.excerpt(string.rep("a", 100), 100)) == false)
  assert(select(2, Reviews.excerpt(string.rep("a", 101), 100)) == true)
end)
check("a cut never splits a multi-byte character", function()
  local text = Reviews.excerpt(string.rep("\195\169", 100), 51) -- 2-byte characters
  local body = text:sub(1, -#ELLIPSIS - 1)
  assert(#body % 2 == 0, "split a character: " .. #body)
end)
check("paragraph breaks are flattened for the list", function()
  local text = Reviews.excerpt("One.\n\nTwo.\r\nThree.")
  assert(not text:find("[\r\n]"), "line break survived")
  assert(text:find("One.", 1, true) and text:find("Three.", 1, true))
end)

print("\n== shaping a row ==")
local function row(over)
  local t = { id = 1, rating = 4.5, review_raw = "Great.", review_has_spoilers = false, likes_count = 3,
    reviewed_at = "2025-01-02T00:00:00", user = { username = "u", name = "Una" } }
  for k, v in pairs(over or {}) do t[k] = v end
  for k in pairs(over or {}) do if over[k] == false and k == "user" then t[k] = nil end end
  return t
end
check("a row becomes a review, with the headline", function()
  local rv = Reviews.normalize(row())
  assert(rv.reviewer == "Una" and rv.rating == "4.5*" and rv.likes == "3 likes" and rv.date == "2025-01-02")
  assert(Reviews.headline(rv) == "Una \194\183 4.5* \194\183 3 likes \194\183 2025-01-02", Reviews.headline(rv))
end)
check("the headline leaves out what is missing", function()
  local rv = Reviews.normalize(row({ rating = false, likes_count = 0, reviewed_at = false, user = false }))
  assert(Reviews.headline(rv) == "A reader", Reviews.headline(rv))
end)
check("only an explicit true marks a spoiler", function()
  assert(Reviews.normalize(row({ review_has_spoilers = true })).has_spoilers == true)
  assert(Reviews.normalize(row({ review_has_spoilers = false })).has_spoilers == false)
  assert(Reviews.normalize(row({ review_has_spoilers = false })).has_spoilers == false)
end)
check("rows with no text are dropped from a page", function()
  local list = Reviews.normalizeAll({ row({ id = 1 }), row({ id = 2, review_raw = "  " }), row({ id = 3, review_raw = false }) })
  assert(#list == 1 and list[1].id == 1, "got " .. #list)
end)

print("\n== spoilers in the list ==")
check("a hidden spoiler shows only the prompt, never the text", function()
  local rv = Reviews.normalize(row({ review_has_spoilers = true, review_raw = "The butler did it." }))
  local text, action = Reviews.rowText(rv, false)
  assert(action == "reveal")
  assert(text:find("Contains spoilers - tap to show", 1, true))
  assert(not text:find("butler", 1, true), "the spoiler leaked into the row")
end)
check("a revealed spoiler shows its text and is then an ordinary row", function()
  local rv = Reviews.normalize(row({ review_has_spoilers = true, review_raw = "The butler did it." }))
  local text, action = Reviews.rowText(rv, true)
  assert(text:find("butler", 1, true) and not text:find("Contains spoilers", 1, true))
  assert(action == nil)
end)
check("a long review offers Read more, a short one does not", function()
  local long = Reviews.normalize(row({ review_raw = string.rep("word ", 200) }))
  local text, action = Reviews.rowText(long, false)
  assert(action == "full" and text:find("Read more", 1, true))
  local short, a2 = Reviews.rowText(Reviews.normalize(row()), false)
  assert(a2 == nil and not short:find("Read more", 1, true))
end)
check("a long spoiler stays hidden until revealed, then offers Read more", function()
  local rv = Reviews.normalize(row({ review_has_spoilers = true, review_raw = string.rep("word ", 200) }))
  local _, hidden = Reviews.rowText(rv, false)
  local _, shown_action = Reviews.rowText(rv, true)
  assert(hidden == "reveal" and shown_action == "full")
end)

print("\n== paging ==")
check("appending a page drops rows already held, keeping order", function()
  local out = Reviews.appendPage({ { id = 1 }, { id = 2 } }, { { id = 2 }, { id = 3 } })
  assert(#out == 3 and out[1].id == 1 and out[2].id == 2 and out[3].id == 3)
end)
check("a full page means there may be more, a short one means there is not", function()
  assert(Reviews.hasMore(10, 10) == true)
  assert(Reviews.hasMore(9, 10) == false)
  assert(Reviews.hasMore(0, 10) == false)
end)

-- ================================================================ the query
print("\n== the request ==")
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return true end, isOnline = function() return true end }
end
package.preload["ui/trapper"] = function()
  return {
    wrap = function(_, fn) fn() end,
    dismissableRunInSubprocess = function(_, fn) return true, fn() end,
  }
end
package.preload["ffi/util"] = function()
  local util = { template = function(t) return t end }
  setmetatable(util, { __call = function(_, s) return tostring(s) end })
  return util
end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["ffi"] = function() return {} end
package.preload["ffi/pointer"] = function() return {} end
package.preload["ffi/utf8"] = function() return { char = string.char, len = string.len } end
package.preload["blitbuffer"] = function() return {} end
package.preload["socketutil"] = function()
  return { set_timeout = function() end, reset_timeout = function() end, table_sink = function(t) return t end,
           TIMEOUT_CODE = "timeout", SSL_HANDSHAKE_CODE = "ssl", SINK_TIMEOUT_CODE = "sink" }
end

local Api = require("hardcover/lib/hardcover_api")

local sent
local original_query = Api.query
Api.query = function(_, query, variables)
  sent = { query = query, variables = variables }
  return Api._reply
end

local flat = function(s) return (s:gsub("%s+", " ")) end

check("it asks for reviews of this book only, with a filter on has_review", function()
  Api._reply = { user_books = {} }
  Api:getReviews(77, 10, 0)
  local q = flat(sent.query)
  assert(q:find("book_id: { _eq: $bookId }", 1, true), "no book filter")
  assert(q:find("has_review: { _eq: true }", 1, true), "no has_review filter")
  assert(sent.variables.bookId == 77)
end)
check("it orders by likes, then recency, then id (the tie-break offset paging needs)", function()
  Api:getReviews(77, 10, 0)
  local q = flat(sent.query)
  local order = q:match("order_by: %[(.-)%]")
  assert(order, "no order_by list")
  assert(order == "{ likes_count: desc }, { reviewed_at: desc }, { id: desc }", order)
end)
check("it takes the page from limit and offset, as variables", function()
  Api:getReviews(77, 10, 20)
  local q = flat(sent.query)
  assert(q:find("limit: $limit", 1, true) and q:find("offset: $offset", 1, true))
  assert(sent.variables.limit == 10 and sent.variables.offset == 20)
  Api:getReviews(77, 5, 15)
  assert(sent.variables.limit == 5 and sent.variables.offset == 15, "limit or offset ignored")
  Api:getReviews(77)
  assert(sent.variables.limit == 10 and sent.variables.offset == 0, "no defaults")
end)
check("it asks for the fields the list shows", function()
  Api:getReviews(77, 10, 0)
  local q = flat(sent.query)
  for _, field in ipairs({ "id", "rating", "review_raw", "review_has_spoilers", "review_length",
    "likes_count", "reviewed_at", "user { username name }" }) do
    assert(q:find(field, 1, true), "missing " .. field)
  end
end)
check("the rows come back as they are, and a failure comes back as nil plus the error", function()
  Api._reply = { user_books = { { id = 5 } } }
  local rows = Api:getReviews(77, 10, 0)
  assert(#rows == 1 and rows[1].id == 5)
  Api._reply = nil
  local none, err = Api:getReviews(77, 10, 0)
  assert(none == nil and type(err) == "table", "a failure was not reported")
end)
check("the async wrapper passes the page through and delivers the rows", function()
  Api._reply = { user_books = { { id = 9 } } }
  local got
  Api:getReviewsAsync(77, 10, 30, function(rows) got = rows end)
  assert(got and got[1].id == 9, "callback not delivered")
  assert(sent.variables.offset == 30 and sent.variables.bookId == 77)
end)
Api.query = original_query

-- ================================================================ the dialog
print("\n== the reviews screen ==")
local ReviewsDialog = require("hardcover/lib/ui/reviews_dialog")

local function reviews(n, from)
  local out = {}
  for i = (from or 1), (from or 1) + n - 1 do
    out[#out + 1] = Reviews.normalize(row({ id = i, review_raw = "Review " .. i }))
  end
  return out
end

local function build(opts)
  local d = ReviewsDialog:new(opts or {})
  return d
end

check("an empty list says there are no reviews yet, and is not tappable", function()
  local d = build({ message = "Loading reviews" })
  assert(d.items[1].text == "Loading reviews")
  d:addPage({}, 0, 0)
  assert(d.items[1].text == "No reviews yet", d.items[1].text)
  assert(#d.items == 1)
  d:onSelectItem(d.items[1]) -- must do nothing
end)
check("the first reviews replace the loading message", function()
  local d = build({ message = "Loading reviews" })
  d:addPage(reviews(2), 2, 0)
  assert(d.message == nil and d.items[1].text:find("Review 1", 1, true))
end)
check("ten reviews and a Load more item", function()
  local d = build()
  d:addPage(reviews(10), 10, 0)
  assert(#d.items == 11, "ten reviews and a Load more row, got " .. #d.items)
  assert(d.items[11].text == "Load more reviews" and d.items[11].action == "more")
end)
check("a short first page offers no Load more", function()
  local d = build()
  d:addPage(reviews(3), 3, 0)
  assert(#d.items == 3 and not d.has_more)
end)
check("a spoiler row is hidden, a tap reveals it, and it stays revealed across a rebuild", function()
  local d = build()
  local list = reviews(3)
  list[2] = Reviews.normalize(row({ id = 2, review_has_spoilers = true, review_raw = "The butler did it." }))
  d:addPage(list, 3, 0)
  local item = d.items[2]
  assert(item.text:find("Contains spoilers", 1, true) and not item.text:find("butler", 1, true))
  d:onSelectItem(item)
  assert(d.items[2].text:find("butler", 1, true), "tap did not reveal")
  -- another page arriving rebuilds the rows; the revealed one stays revealed
  d:refresh()
  assert(d.items[2].text:find("butler", 1, true), "spoiler hid itself again")
  assert(d.items[1].text:find("Review 1", 1, true))
end)
check("tapping an ordinary short row does nothing", function()
  local d = build()
  d:addPage(reviews(2), 2, 0)
  local before = #shown
  d:onSelectItem(d.items[1])
  assert(#shown == before)
end)
check("tapping Read more opens the whole review in a viewer", function()
  local d = build()
  local long = Reviews.normalize(row({ id = 1, review_raw = "First.\n\n" .. string.rep("word ", 200) .. "LASTWORD" }))
  d:addPage({ long }, 1, 0)
  local before = #shown
  d:onSelectItem(d.items[1])
  assert(#shown == before + 1, "no viewer shown")
  local viewer = shown[#shown]
  assert(viewer.text:find("LASTWORD", 1, true), "the viewer has not the whole text")
  assert(viewer.text:find("First.\n\n", 1, true), "paragraphs were lost")
end)
check("Load more asks for the next page at the right offset, once, and appends", function()
  local calls = {}
  local pending
  local d = build({ fetch_page = function(offset, limit, cb)
    calls[#calls + 1] = { offset, limit }
    pending = cb
  end })
  d:addPage(reviews(10), 10, 0)
  d:onSelectItem(d.items[11])
  d:onSelectItem(d.items[11]) -- a double tap
  assert(#calls == 1, "double tap fired " .. #calls .. " requests")
  assert(calls[1][1] == 10 and calls[1][2] == 10, "offset " .. tostring(calls[1][1]))
  assert(d.items[11].text:find("Loading", 1, true), "no loading state")
  pending(reviews(10, 11), nil, 10)
  assert(#d.reviews == 20 and #d.items == 21)
  assert(d.offset == 20 and d.has_more)
  d:onSelectItem(d.items[21])
  assert(calls[2][1] == 20, "second page offset " .. tostring(calls[2][1]))
  pending(reviews(3, 21), nil, 3)
  assert(#d.reviews == 23 and not d.has_more and #d.items == 23, "last page left Load more")
end)
check("a row repeated across pages is shown once", function()
  local pending
  local d = build({ fetch_page = function(_, _, cb) pending = cb end })
  d:addPage(reviews(10), 10, 0)
  d:loadMore()
  pending(reviews(10, 10), nil, 10) -- id 10 again
  assert(#d.reviews == 19, "got " .. #d.reviews)
end)
check("a failed page puts Load more back and can be tried again", function()
  local pending, n = nil, 0
  local d = build({ fetch_page = function(_, _, cb) n = n + 1 pending = cb end })
  d:addPage(reviews(10), 10, 0)
  d:loadMore()
  pending(nil, "boom")
  assert(not d.loading and d.has_more, "stuck loading")
  assert(d.items[11].text == "Load more reviews")
  d:loadMore()
  assert(n == 2, "no second request")
end)
check("a page of ten with a textless row dropped still offers Load more", function()
  local d = build()
  local rows = Reviews.normalizeAll((function()
    local raw = {}
    for i = 1, 10 do raw[i] = row({ id = i, review_raw = (i == 4) and "" or "ok" }) end
    return raw
  end)())
  assert(#rows == 9)
  d:addPage(rows, 10, 0)
  assert(d.has_more, "lost Load more")
  -- the next page starts after the ten the server gave, not the nine shown
  assert(d.offset == 10, "offset " .. tostring(d.offset))
end)
check("closing calls back once and closes the widget", function()
  local called = 0
  local d = build({ close_callback = function() called = called + 1 end })
  local before = #closed
  d:onClose()
  assert(called == 1 and #closed == before + 1)
end)

r.finish()
