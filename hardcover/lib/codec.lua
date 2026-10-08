-- JSON for what the plugin keeps on the device (book_store.lua, list_store.lua,
-- shelf_store.lua).
--
-- rapidjson when KOReader has it (every KOReader since mid-2020): it decodes a 611-book
-- shelf in about a quarter of the time KOReader's pure-Lua json takes, which is the
-- difference between a shelf that opens faster than the old saved-shelf file and one
-- that opens three times slower (measured in the emulator). The pure-Lua json
-- otherwise, and in the spec suite.
--
-- What is stored is always encoded here from Lua tables, so it holds no JSON null
-- (a nil field is simply left out). json is still asked for "simple" decoding, which
-- reads a null as nil, in case a value ever arrives with one.

local Codec = {}

-- rapidjson only if it really is one: a round trip must come back as it went
local ok_rapid, rapidjson = pcall(require, "rapidjson")
if ok_rapid and type(rapidjson) == "table" then
  local works = pcall(function()
    local back = rapidjson.decode(rapidjson.encode({ a = 1, b = { "x" } }))
    assert(type(back) == "table" and back.a == 1 and back.b[1] == "x")
  end)
  if not works then rapidjson = nil end
else
  rapidjson = nil
end
local json = require("json")

-- Can be set to false by a test to check the fallback.
Codec.use_rapidjson = rapidjson ~= nil

-- The text, or nil when the value cannot be encoded.
function Codec.encode(value)
  if Codec.use_rapidjson then
    local ok, text = pcall(rapidjson.encode, value)
    if ok and type(text) == "string" then return text end
  end
  local ok, text = pcall(json.encode, value)
  return ok and type(text) == "string" and text or nil
end

-- The table, or nil when the text is not JSON for a table.
function Codec.decode(text)
  if type(text) ~= "string" then return nil end
  if Codec.use_rapidjson then
    local ok, value = pcall(rapidjson.decode, text)
    if ok and type(value) == "table" then return value end
  end
  local ok, value = pcall(json.decode, text, json.decode.simple)
  return ok and type(value) == "table" and value or nil
end

return Codec
