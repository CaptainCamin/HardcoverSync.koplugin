-- The shape comparison the live check uses to hold the emulator fixtures to the real API.
--
-- Run with:  lua spec/shape_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local support = dofile(PLUGIN .. "/spec/support.lua")
local Shape = dofile(PLUGIN .. "/spec/live/shape.lua")
local r = support.reporter()
local check = r.test

local function problems(live, fixture)
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
  local p = problems({ id = 1, rows = { { n = "a" } } }, { id = 9, rows = { { n = "zz" }, { n = "y" } } })
  assert(#p == 0, table.concat(p, "; "))
end)

check("a field the fixture lacks is a problem", function()
  local p = problems({ id = 1, pages = 300 }, { id = 1 })
  assert(#p == 1 and p[1]:find("pages"), table.concat(p, "; "))
end)

check("a field of another type is a problem", function()
  local p = problems({ id = 1 }, { id = "1" })
  assert(#p == 1 and p[1]:find("number"), table.concat(p, "; "))
end)

check("a field that is null live, or null in the fixture, is unknown and not a problem", function()
  assert(#problems({ a = Shape.of(nil) and nil, b = 1 }, { a = "x", b = 2 }) == 0)
  local live = { b = 1 }
  local p = Shape.compare({ a = "null", b = "number" }, Shape.of({ a = "x", b = 2 }))
  assert(#p == 0)
  p = Shape.compare(Shape.of({ a = "x" }), { a = "null" })
  assert(#p == 0 and live)
end)

check("an empty list on either side has nothing to compare", function()
  assert(#problems({ rows = {} }, { rows = { { a = 1 } } }) == 0)
  assert(#problems({ rows = { { a = 1 } } }, { rows = {} }) == 0)
end)

check("a fixture field the live answer never showed is only an extra", function()
  local p, extras = problems({ id = 1 }, { id = 1, invented = true })
  assert(#p == 0 and extras[1] == ".invented", tostring(extras[1]))
end)

check("a problem names the path to the field", function()
  local p = problems({ rows = { { book = { pages = 1 } } } }, { rows = { { book = {} } } })
  assert(p[1]:find("%.rows%[%]%.book%.pages"), p[1])
end)

r.finish()
