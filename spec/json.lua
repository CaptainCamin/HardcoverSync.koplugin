-- A minimal JSON decoder, enough for the OAuth and GraphQL responses these
-- harnesses exercise.
--
-- This exists because the plugin decodes HTTP bodies with json.decode, and the
-- OAuth error codes (authorization_pending, slow_down, invalid_grant) ride on
-- that decode succeeding. A stub that raised on every body -- which is what a
-- cheap fake would do -- would make those paths untestable, and those paths are
-- exactly where the subtle bugs live.
--
-- Handles the subset JSON actually uses here: objects, arrays, strings with
-- escapes, numbers, true/false/null. Not a general-purpose implementation, and
-- deliberately strict so malformed input raises rather than returning nonsense.

local json = {}

-- ---------------------------------------------------------------- decoding

local function skipWhitespace(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return j + 1
end

local ESCAPES = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
  b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

local function decodeString(s, i)
  -- s:sub(i) must begin with a quote
  local out = {}
  local j = i + 1
  while j <= #s do
    local c = s:sub(j, j)
    if c == '"' then
      return table.concat(out), j + 1
    elseif c == "\\" then
      local nxt = s:sub(j + 1, j + 1)
      if nxt == "u" then
        local hex = s:sub(j + 2, j + 5)
        local code = tonumber(hex, 16)
        if not code then
          error("json: bad \\u escape at " .. j)
        end
        -- encode as UTF-8
        if code < 0x80 then
          out[#out + 1] = string.char(code)
        elseif code < 0x800 then
          out[#out + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
        else
          out[#out + 1] = string.char(0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
        end
        j = j + 6
      else
        local rep = ESCAPES[nxt]
        if not rep then
          error("json: bad escape \\" .. tostring(nxt) .. " at " .. j)
        end
        out[#out + 1] = rep
        j = j + 2
      end
    elseif c == "" then
      error("json: unterminated string")
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
  error("json: unterminated string")
end

local function decodeValue(s, i)
  i = skipWhitespace(s, i)
  local c = s:sub(i, i)

  if c == "" then
    error("json: unexpected end of input")
  elseif c == "{" then
    local obj = {}
    i = skipWhitespace(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      i = skipWhitespace(s, i)
      if s:sub(i, i) ~= '"' then
        error("json: expected a key at " .. i)
      end
      local key
      key, i = decodeString(s, i)
      i = skipWhitespace(s, i)
      if s:sub(i, i) ~= ":" then
        error("json: expected ':' at " .. i)
      end
      local val
      val, i = decodeValue(s, i + 1)
      obj[key] = val
      i = skipWhitespace(s, i)
      local d = s:sub(i, i)
      if d == "," then
        i = i + 1
      elseif d == "}" then
        return obj, i + 1
      else
        error("json: expected ',' or '}' at " .. i)
      end
    end
  elseif c == "[" then
    local arr = {}
    i = skipWhitespace(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
      local val
      val, i = decodeValue(s, i)
      arr[#arr + 1] = val
      i = skipWhitespace(s, i)
      local d = s:sub(i, i)
      if d == "," then
        i = i + 1
      elseif d == "]" then
        return arr, i + 1
      else
        error("json: expected ',' or ']' at " .. i)
      end
    end
  elseif c == '"' then
    return decodeString(s, i)
  elseif s:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif s:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif s:sub(i, i + 3) == "null" then
    return nil, i + 4
  else
    local num = s:match("^%-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if not num or num == "" then
      error("json: unexpected character '" .. c .. "' at " .. i)
    end
    return tonumber(num), i + #num
  end
end

function json.decode(s)
  if type(s) ~= "string" then
    error("json.decode expects a string, got " .. type(s))
  end
  local value, next_i = decodeValue(s, 1)
  next_i = skipWhitespace(s, next_i)
  if next_i <= #s then
    error("json: trailing content at " .. next_i)
  end
  return value
end

-- KOReader calls json.decode(body, json.decode.simple), so `simple` must be
-- readable as a field of `decode`.
--
-- `json.decode = function() end` followed by `json.decode.simple = false` does
-- NOT work: Lua cannot index a function value on the assignment side and raises
-- "attempt to index a function value". The fix is to make `decode` a table with
-- a __call metamethod -- then it is still callable, but indexing it to store a
-- field is legal.
local raw_decode = json.decode
json.decode = setmetatable({ simple = false }, {
  __call = function(_, s, simple) return raw_decode(s, simple) end,
})

-- ---------------------------------------------------------------- encoding
-- Only used to build fixtures, but a decoder without an encoder makes tests
-- awkward to write.

local ESCAPE_MAP = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
                     ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return ESCAPE_MAP[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function encodeValue(v, out)
  local t = type(v)
  if v == nil then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = tostring(v)
  elseif t == "number" then
    out[#out + 1] = string.format("%.14g", v)
  elseif t == "string" then
    out[#out + 1] = encodeString(v)
  elseif t == "table" then
    if #v > 0 or next(v) == nil then
      out[#out + 1] = "["
      for i, item in ipairs(v) do
        if i > 1 then out[#out + 1] = "," end
        encodeValue(item, out)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      -- sorted keys so encoded output is stable and diffable
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for _, k in ipairs(keys) do
        if not first then out[#out + 1] = "," end
        first = false
        out[#out + 1] = encodeString(tostring(k))
        out[#out + 1] = ":"
        encodeValue(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else
    error("json.encode cannot handle a " .. t)
  end
end

function json.encode(v)
  local out = {}
  encodeValue(v, out)
  return table.concat(out)
end

return json
