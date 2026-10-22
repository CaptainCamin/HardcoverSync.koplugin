-- The shape of a value: which fields it has and what type each holds, never the values.
--
-- The live check (hardcover_live.lua) reduces what the real API returned to a shape, so it can be
-- compared with the emulator's canned data (spec/emu/fixtures.lua) without keeping or printing
-- anything from the account. A shape is "string" / "number" / "boolean" / "null", a table of field
-- shapes, or { ["[]"] = item shape } for a list (items merged; an empty list has no item shape).
local Shape = {}

local function merge(a, b)
  if a == nil then return b end
  if b == nil or a == b then return a end
  if a == "null" then return b end
  if b == "null" then return a end
  if type(a) == "table" and type(b) == "table" then
    local out = {}
    for k, v in pairs(a) do out[k] = merge(v, b[k]) end
    for k, v in pairs(b) do if out[k] == nil then out[k] = v end end
    return out
  end
  return "mixed"
end

Shape.merge = merge

function Shape.of(value, is_null)
  local t = type(value)
  if value == nil or (is_null and is_null(value)) then return "null" end
  if t ~= "table" then return t end
  if #value > 0 then
    local item
    for _, v in ipairs(value) do item = merge(item, Shape.of(v, is_null)) end
    return { ["[]"] = item }
  end
  local out = {}
  for k, v in pairs(value) do out[tostring(k)] = Shape.of(v, is_null) end
  return out
end

-- What a fixture must change to look like the live answer. Returns a list of strings.
--   missing: the live answer has a typed field the fixture lacks (or holds as another type)
--   extra:   the fixture has a field the live answer never showed (a warning, not a failure)
-- "null" on either side means unknown, and an empty list has no item shape to compare.
function Shape.compare(live, fixture, path, problems, extras)
  path, problems, extras = path or "", problems or {}, extras or {}
  if live == "null" or live == nil or fixture == "null" then return problems, extras end
  if type(live) ~= type(fixture) or (type(live) == "string" and live ~= fixture) then
    if live ~= "mixed" and fixture ~= "mixed" then
      problems[#problems + 1] = string.format("%s: live is %s, fixture is %s", path == "" and "(root)" or path,
        type(live) == "table" and (live["[]"] and "a list" or "an object") or live,
        fixture == nil and "absent" or (type(fixture) == "table" and (fixture["[]"] and "a list" or "an object") or fixture))
    end
    return problems, extras
  end
  if type(live) ~= "table" then return problems, extras end
  if live["[]"] or fixture["[]"] then
    if live["[]"] and fixture["[]"] then Shape.compare(live["[]"], fixture["[]"], path .. "[]", problems, extras) end
    return problems, extras
  end
  for k, v in pairs(live) do
    local fv = fixture[k]
    if fv == nil then
      if v ~= "null" then problems[#problems + 1] = string.format("%s.%s: live has %s, fixture lacks it", path, k, type(v) == "table" and "an object" or v) end
    else
      Shape.compare(v, fv, path .. "." .. k, problems, extras)
    end
  end
  for k in pairs(fixture) do
    if live[k] == nil then extras[#extras + 1] = path .. "." .. k end
  end
  return problems, extras
end

return Shape
