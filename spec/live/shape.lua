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

-- How a fixture differs from the live answer. Returns three lists of strings:
--   mismatches: a field both sides have, with different types (the fixture's data cannot be right)
--   missing:    the live answer has a typed field the fixture lacks (path ends in the field name)
--   extras:     the fixture has a field the live answer never showed
-- "null" on either side means unknown, and an empty list has no item shape to compare.
function Shape.compare(live, fixture, path, mismatches, extras, missing)
  path, mismatches, extras, missing = path or "", mismatches or {}, extras or {}, missing or {}
  local function kind(v) return type(v) == "table" and (v["[]"] and "a list" or "an object") or tostring(v) end
  if live == "null" or live == nil or fixture == "null" then return mismatches, extras, missing end
  -- an empty table is an empty list or an empty object: nothing to compare
  if type(live) == "table" and next(live) == nil or type(fixture) == "table" and next(fixture) == nil then
    return mismatches, extras, missing
  end
  if kind(live) ~= kind(fixture) then
    if live ~= "mixed" and fixture ~= "mixed" then
      mismatches[#mismatches + 1] = string.format("%s: live is %s, fixture is %s", path == "" and "(root)" or path, kind(live), kind(fixture))
    end
    return mismatches, extras, missing
  end
  if type(live) ~= "table" then return mismatches, extras, missing end
  if live["[]"] or fixture["[]"] then
    if live["[]"] and fixture["[]"] then Shape.compare(live["[]"], fixture["[]"], path .. "[]", mismatches, extras, missing) end
    return mismatches, extras, missing
  end
  for k, v in pairs(live) do
    local fv = fixture[k]
    if fv == nil then
      if v ~= "null" then missing[#missing + 1] = path .. "." .. k end
    else
      Shape.compare(v, fv, path .. "." .. k, mismatches, extras, missing)
    end
  end
  for k in pairs(fixture) do
    if live[k] == nil then extras[#extras + 1] = path .. "." .. k end
  end
  return mismatches, extras, missing
end

return Shape
