-- Live scope check: does the sign-in ask for every permission the plugin's requests need?
--
-- Hardcover publishes which OAuth scope allows each GraphQL operation
-- (https://api.hardcover.app/capabilities.json). This finds the operations named in the
-- plugin's GraphQL strings, looks up the scope each needs, and fails when the scope set the
-- plugin asks for at sign-in (default_config.lua, and auth.lua's DEFAULT_SCOPE) covers none of
-- them, or names a scope Hardcover does not publish. It then starts (and abandons) a device
-- sign-in with that scope set, which fails with invalid_scope if the registered OAuth app does
-- not allow one of them. A personal token has every scope, so hardcover_live.lua cannot see
-- any of this.
--
-- Needs the network, no token. Run with:  luajit spec/live/scope_check.lua [plugin-root]
-- HARDCOVER_CAPABILITIES=<file> reads the map from a file instead and skips the sign-in probe.

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_json(PLUGIN)
local json = require("json")

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function shell(cmd)
  local p = assert(io.popen(cmd, "r"))
  local out = p:read("*a")
  p:close()
  return out
end

local failures = 0
local function fail(msg)
  failures = failures + 1
  print("FAIL " .. msg)
end

-- What the plugin asks for -------------------------------------------------------------------

local config_scope = dofile(PLUGIN .. "/hardcover/lib/default_config.lua").scope
local auth_scope = read(PLUGIN .. "/hardcover/lib/auth.lua"):match('local DEFAULT_SCOPE = "([^"]*)"')
if config_scope ~= auth_scope then
  fail("default_config.lua and auth.lua's DEFAULT_SCOPE ask for different scopes")
end
local requested = {}
for s in (config_scope or ""):gmatch("%S+") do requested[#requested + 1] = s end

-- What Hardcover publishes -------------------------------------------------------------------

local caps_file = os.getenv("HARDCOVER_CAPABILITIES")
local caps = json.decode(caps_file and read(caps_file)
  or shell("curl -sS --fail --max-time 30 https://api.hardcover.app/capabilities.json"))
assert(type(caps) == "table" and type(caps.scopes) == "table", "capabilities.json has no scopes")

local scopes = {}
for _, s in ipairs(caps.scopes) do scopes[s.scope] = s end

-- Every scope a sign-in with `requested` holds, following "implies".
local held = {}
local function hold(name)
  if held[name] or not scopes[name] then return end
  held[name] = true
  for _, implied in ipairs(scopes[name].implies or {}) do hold(implied) end
end
for _, s in ipairs(requested) do
  if not scopes[s] then fail("asks for " .. s .. ", which Hardcover does not publish") end
  hold(s)
end

local needs = {} -- operation -> scopes that allow it ("all" left out: nobody is told to ask for it)
for name, s in pairs(scopes) do
  if name ~= "all" then
    for _, op in ipairs(s.operations or {}) do
      needs[op] = needs[op] or {}
      table.insert(needs[op], name)
    end
  end
end

-- What the plugin's requests use -------------------------------------------------------------

-- GraphQL lives in the plugin's string literals; a field is a name followed by "(" or "{".
-- Nested fields count too (lists { list_books { ... } }): asking for more than is needed is
-- harmless, missing one is not.
local function literals(src)
  local out = {}
  src = src:gsub("%-%-%[(=*)%[.-%]%1%]", "") -- block comments are not requests
  for _, body in src:gmatch("%[(=*)%[(.-)%]%1%]") do out[#out + 1] = body end
  for _, q in ipairs({ '"', "'" }) do
    for body in src:gmatch(q .. "([^" .. q .. "\n]*)" .. q) do out[#out + 1] = body end
  end
  return out
end

local used = {} -- operation -> first file using it
local files = shell("find '" .. PLUGIN .. "/hardcover' '" .. PLUGIN .. "/main.lua' -name '*.lua' | sort")
for path in files:gmatch("[^\n]+") do
  for _, text in ipairs(literals(read(path))) do
    if text:find("[{(]") then
      for name in text:gmatch("([%a_][%w_]*)%s*[({]") do
        if needs[name] and not used[name] then used[name] = path:sub(#PLUGIN + 2) end
      end
    end
  end
end

local ops = {}
for op in pairs(used) do ops[#ops + 1] = op end
table.sort(ops)
if #ops == 0 then fail("found no GraphQL operations in the plugin's source") end

for _, op in ipairs(ops) do
  local ok = false
  for _, s in ipairs(needs[op]) do ok = ok or held[s] == true end
  table.sort(needs[op])
  if ok then
    print("ok   " .. op)
  else
    fail(op .. " (" .. used[op] .. ") needs one of: " .. table.concat(needs[op], " "))
  end
end

-- Does the registered app accept that set? ---------------------------------------------------

if not caps_file then
  local client_id = dofile(PLUGIN .. "/hardcover/lib/default_config.lua").client_id
  local answer = shell("curl -sS --max-time 30 -w '\\n%{http_code}' https://api.hardcover.app/oauth2/device"
    .. " --data-urlencode 'client_id=" .. client_id .. "' --data-urlencode 'scope=" .. config_scope .. "'")
  local body, code = answer:match("^(.*)\n(%d+)$")
  local reply = body and pcall(json.decode, body) and json.decode(body) or {}
  -- the device and user codes are not printed: nothing is done with them, and they expire
  if code == "200" and reply.device_code then
    print("ok   the OAuth app accepts the scope set")
  else
    fail("device sign-in refused the scope set: HTTP " .. tostring(code) .. " "
      .. tostring(reply.error) .. " " .. tostring(reply.error_description))
  end
end

print(string.format("\n%d operations checked, %d failed", #ops, failures))
os.exit(failures == 0 and 0 or 1)
