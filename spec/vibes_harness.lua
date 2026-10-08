-- Hardcover's vibes as plain data: the rows the API gives, their kinds and order, the index
-- rows the lists screen draws, and the two requests Api:getVibes sends (against a stubbed
-- Api:query). Shapes are the live ones (an account's own, Top Picks, Recommendations...).
--
-- Run with:  lua spec/vibes_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local function make()
  local t = {}
  return setmetatable(t, {
    __index = function() return make() end, __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end, __mul = function() return 0 end,
    __div = function() return 0 end, __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end
package.preload["ui/uimanager"] = function()
  return { show = function() end, close = function() end, isWidgetShown = function() return false end,
    setDirty = function() end, scheduleIn = function() end, unschedule = function() end, nextTick = function() end }
end
package.preload["ui/trapper"] = function()
  return { wrap = function(_, fn) local co = coroutine.create(fn); assert(coroutine.resume(co)) end }
end
package.preload["ui/network/manager"] = function() return { isConnected = function() return true end } end
package.preload["gettext"] = function() return setmetatable({}, { __call = function(_, s) return s end }) end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
package.preload["logger"] = function() return { dbg = function() end, info = function() end, warn = function() end, err = function() end } end
local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then return real_require(name) end
  return make()
end

local Vibes = real_require("hardcover/lib/vibes")
local Api = real_require("hardcover/lib/hardcover_api")

local rows = {
  { id = 1340, title = "For Red Rising Withdrawl", vibe_type = 0, privacy_setting_id = 3, cached_book_ids = { 11, 12, 13, 14 } },
  { id = 1342, title = "Top Picks", vibe_type = 3, privacy_setting_id = 3, cached_book_ids = { 21, 22, 23, 24, 25 } },
  { id = 1343, title = "Recommendations", vibe_type = 1, privacy_setting_id = 3, cached_book_ids = { 31, 32, 33, 34 } },
  { id = 1344, title = "Based on your recent 5-star reads", vibe_type = 2, privacy_setting_id = 3, cached_book_ids = { 41, 42 } },
  { id = 1341, title = "Based on your most recently read book", vibe_type = 2, privacy_setting_id = 3, cached_book_ids = { 51 } },
  { id = 9, title = "Empty", vibe_type = 0, cached_book_ids = {} },
  { title = "No id", cached_book_ids = { 1 } },
}

print("\n== reading the rows ==")

check("Hardcover's own come first (Top Picks, Recommendations, Based on...), yours last; empty and id-less rows go", function()
  local v = Vibes.normalize(rows)
  local names = {}
  for _, x in ipairs(v) do names[#names + 1] = x.title end
  assert(#v == 5, #v .. ": " .. table.concat(names, " | "))
  assert(v[1].title == "Top Picks" and v[1].kind == "top_picks")
  assert(v[2].title == "Recommendations" and v[2].kind == "recommendations")
  assert(v[3].id == 1341 and v[4].id == 1344 and v[3].kind == "based_on", "the 'Based on' ones are in id order")
  assert(v[5].title == "For Red Rising Withdrawl" and v[5].kind == "mine")
end)

check("ids are whole numbers in rank order without repeats; junk gives an empty list", function()
  local v = Vibes.normalize({ { id = 1, title = "T", vibe_type = 0, cached_book_ids = { 5, "7", 5, 2.5, "x", 9 } } })
  assert(#v == 1 and #v[1].ids == 3 and v[1].ids[1] == 5 and v[1].ids[2] == 7 and v[1].ids[3] == 9 and v[1].count == 3)
  assert(#Vibes.normalize(nil) == 0 and #Vibes.normalize("x") == 0 and #Vibes.normalize({ "x" }) == 0)
end)

check("a title missing is named; private is read from the privacy setting; the date is kept", function()
  local v = Vibes.normalize({ { id = 2, title = "", vibe_type = 0, privacy_setting_id = 3, books_generated_at = "2026-10-03", cached_book_ids = { 1 } },
    { id = 3, vibe_type = 0, privacy_setting_id = 1, cached_book_ids = { 1 } } })
  assert(v[1].title == "Untitled vibe" and v[1].private == true and v[1].generated_at == "2026-10-03")
  assert(v[2].private == nil)
end)

check("an unknown vibe type is treated as one of yours", function()
  assert(Vibes.kind(99) == "mine" and Vibes.kind(nil) == "mine" and Vibes.kind("3") == "top_picks")
end)

print("\n== the index and the pages ==")

check("two groups of rows for the lists screen: Hardcover's, then yours, with covers and a small print", function()
  local v = Vibes.normalize(rows)
  local system, mine = Vibes.rows(v, { [1342] = { "a.jpg", "b.jpg" } })
  assert(#system == 4 and #mine == 1)
  assert(system[1].name == "Top Picks" and system[1].owner == "Hardcover" and #system[1].covers == 2 and system[1].count == 5)
  assert(system[1].private == nil, "a Hardcover vibe is not labelled private")
  assert(mine[1].private == true and mine[1].owner == nil and #mine[1].covers == 0)
  assert(system[1].vibe and system[1].vibe.ids[1] == 21, "the row keeps its vibe")
  local Lists = real_require("hardcover/lib/lists")
  assert(Lists.subtitle(system[1]) == "5 books \194\183 ranked \194\183 by Hardcover", Lists.subtitle(system[1]))
end)

check("pages of ids, in rank order, never past the end", function()
  local vibe = Vibes.normalize({ { id = 1, title = "T", vibe_type = 0, cached_book_ids = { 1, 2, 3, 4, 5 } } })[1]
  assert(table.concat(Vibes.page(vibe, 0, 2), ",") == "1,2")
  assert(table.concat(Vibes.page(vibe, 2, 2), ",") == "3,4")
  assert(table.concat(Vibes.page(vibe, 4, 2), ",") == "5")
  assert(#Vibes.page(vibe, 9, 2) == 0)
end)

print("\n== the requests ==")

local sent, script
local function answers(...)
  Api.enabled = true
  sent, script = {}, { ... }
  Api.query = function(_, q, vars, background)
    sent[#sent + 1] = { q = q, vars = vars, background = background }
    local a = table.remove(script, 1) or {}
    return a.result, a.err
  end
end
local function ok(result) return { result = result } end
local function fail(err) return { err = err } end

check("getVibes: the vibes of the account, then the first covers of each; neither can be cancelled by a touch", function()
  answers(ok({ vibes = rows }),
    ok({ books = { { book_id = 21, cached_image = { url = "21.jpg" } }, { book_id = 22, cached_image = { url = "22.jpg" } },
      { book_id = 31, cached_image = { url = "31.jpg" } } } }))
  local vibes, covers = Api:getVibes(7291)
  assert(vibes and #vibes == 5 and not covers.err)
  assert(#sent == 2 and sent[1].vars.userId == 7291 and sent[1].q:find("user_id: { _eq: $userId }", 1, true))
  assert(sent[1].background == true and sent[2].background == true)
  assert(#sent[2].vars.ids == 12, "ids asked for covers: " .. #sent[2].vars.ids)
  assert(#covers[1342] == 2 and covers[1342][1] == "21.jpg" and covers[1342][2] == "22.jpg")
  assert(#covers[1343] == 1 and covers[1343][1] == "31.jpg")
end)

check("getVibes: a refusal for the permission is nil and the error", function()
  local err = { status = 403, errors = { { message = "Missing scopes: read:vibes" } } }
  answers(fail(err))
  local vibes, e = Api:getVibes(1)
  assert(vibes == nil and e == err and Vibes.isScopeError(e))
end)

check("getVibes: the covers failing still gives the index", function()
  answers(ok({ vibes = rows }), fail({ completed = false }))
  local vibes, covers = Api:getVibes(1)
  assert(vibes and #vibes == 5 and type(covers) == "table")
end)

check("getVibeBooks: one request for one page of ids, in the vibe's order", function()
  local vibe = Vibes.normalize({ { id = 1, title = "T", vibe_type = 0, cached_book_ids = { 3, 1, 2 } } })[1]
  answers(ok({ books = { { book_id = 1, title = "One" }, { book_id = 2, title = "Two" }, { book_id = 3, title = "Three" } } }))
  local entries = Api:getVibeBooks(vibe, 0, 20)
  assert(#sent == 1 and #sent[1].vars.ids == 3)
  assert(entries[1].book_id == 3 and entries[2].book_id == 1 and entries[3].book_id == 2)
end)

check("the permission is asked for at sign-in", function()
  for _, file in ipairs({ "hardcover/lib/auth.lua", "hardcover/lib/default_config.lua" }) do
    local f = assert(io.open(PLUGIN .. "/" .. file)); local src = f:read("*a"); f:close()
    local scope = src:match('scope = "([^"]+)"') or src:match('DEFAULT_SCOPE = "([^"]+)"')
    assert(scope and (" " .. scope .. " "):find(" " .. Vibes.SCOPE .. " ", 1, true), file .. " does not request " .. Vibes.SCOPE)
  end
end)

r.finish()
