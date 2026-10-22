-- The shape comparison the live check uses to hold the emulator fixtures to the real API.
--
-- Run with:  lua spec/shape_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local support = dofile(PLUGIN .. "/spec/support.lua")
local Shape = dofile(PLUGIN .. "/spec/live/shape.lua")
local r = support.reporter()
local check = r.test

local function compare(live, fixture)
  return Shape.compare(Shape.of(live), Shape.of(fixture))
end

check("a value reduces to its types, not its content", function()
  local s = Shape.of({ id = 7, title = "x", tags = { "a", "b" }, owner = { name = "n" }, note = nil })
  assert(s.id == "number" and s.title == "string")
  assert(s.tags["[]"] == "string" and s.owner.name == "string")
end)

check("list items are merged, so a field set in only some items still counts", function()
  local s = Shape.of({ { a = 1 }, { a = 2, b = "x" } })
  assert(s["[]"].a == "number" and s["[]"].b == "string")
end)

check("identical shapes agree", function()
  local m, e, miss = compare({ id = 1, rows = { { n = "a" } } }, { id = 9, rows = { { n = "zz" }, { n = "y" } } })
  assert(#m == 0 and #e == 0 and #miss == 0)
end)

check("a field the fixture lacks is reported as missing, not as a mismatch", function()
  local m, _, miss = compare({ id = 1, pages = 300 }, { id = 1 })
  assert(#m == 0 and #miss == 1 and miss[1] == ".pages", tostring(miss[1]))
end)

check("a field of another type is a mismatch", function()
  local m = compare({ id = 1 }, { id = "1" })
  assert(#m == 1 and m[1]:find("number"), table.concat(m, "; "))
  m = compare({ id = 1 }, { id = { 1 } })
  assert(#m == 1)
end)

check("a field that is null live, or null in the fixture, is unknown", function()
  local m, _, miss = Shape.compare({ a = "null", b = "number" }, Shape.of({ a = "x", b = 2 }))
  assert(#m == 0 and #miss == 0)
  m, _, miss = Shape.compare(Shape.of({ a = "x" }), { a = "null" })
  assert(#m == 0 and #miss == 0)
end)

check("an empty list on either side has nothing to compare", function()
  local m, e, miss = compare({ rows = {} }, { rows = { { a = 1 } } })
  assert(#m + #e + #miss == 0)
  m, e, miss = compare({ rows = { { a = 1 } } }, { rows = {} })
  assert(#m + #e + #miss == 0)
end)

check("a fixture field the live answer never showed is an extra", function()
  local m, e = compare({ id = 1 }, { id = 1, invented = true })
  assert(#m == 0 and e[1] == ".invented", tostring(e[1]))
end)

check("a path names the field, through lists and objects", function()
  local _, _, miss = compare({ rows = { { book = { pages = 1, title = "t" } } } }, { rows = { { book = { title = "x" } } } })
  assert(miss[1] == ".rows[].book.pages", tostring(miss[1]))
end)

r.finish()
