-- Proves the plugin loads with NO hardcover_config.lua present.
--
-- This was a real failure: main.lua required the user config at load time, so
-- a fresh install threw during loading and the plugin never appeared in the
-- menu, with no explanation. These tests pin the tolerant behaviour.
--
-- Run with:  lua spec/config_harness.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local results = { passed = 0, failed = 0 }

local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    results.passed = results.passed + 1
    print("ok   " .. name)
  else
    results.failed = results.failed + 1
    print("FAIL " .. name .. "\n     " .. tostring(err))
  end
end

local function eq(a, b)
  if a ~= b then
    error("expected " .. tostring(b) .. ", got " .. tostring(a), 2)
  end
end

-- load config.lua fresh under a given availability of hardcover_config
--
-- Both package.loaded AND package.preload must be reset: require consults
-- loaded first, and a preload entry is a cached factory, so leaving the old
-- closure in place would silently keep serving the first test's config.
local function loadConfig(user_config)
  for key in pairs(package.loaded) do
    if key:match("^hardcover/") then
      package.loaded[key] = nil
    end
  end
  package.loaded["hardcover_config"] = nil
  package.preload["hardcover_config"] = nil

  if user_config == nil then
    -- simulate a fresh install: no user file at all
    package.preload["hardcover_config"] = function()
      error("module 'hardcover_config' not found")
    end
  else
    local snapshot = user_config
    package.preload["hardcover_config"] = function()
      return snapshot
    end
  end

  return require("hardcover/lib/config")
end

print("== defaults with no user config ==")

check("loads without hardcover_config.lua", function()
  local Config = loadConfig(nil)
  if Config == nil then
    error("config did not load")
  end
end)

check("ships a usable client id by default", function()
  local Config = loadConfig(nil)
  if not Config.client_id or Config.client_id == "" then
    error("no default client_id")
  end
end)

check("has no token by default", function()
  local Config = loadConfig(nil)
  eq(Config.token, nil)
end)

check("requests the corrected scope set", function()
  local Config = loadConfig(nil)
  -- write:journal does not exist and fails the whole authorization
  if Config.scope:find("write:journal", 1, true) then
    error("scope set still requests the invalid write:journal")
  end
  if not Config.scope:find("write:library", 1, true) then
    error("scope set is missing write:library")
  end
end)

check("reports that no user config was supplied", function()
  local Config = loadConfig(nil)
  eq(Config.has_user_config, false)
end)

print("== user overrides ==")

check("a user token is honoured", function()
  local Config = loadConfig { token = "hc_pat_example" }
  eq(Config.token, "hc_pat_example")
  eq(Config.has_user_config, true)
end)

check("a user can override the client id", function()
  local Config = loadConfig { client_id = "my-own-app" }
  eq(Config.client_id, "my-own-app")
end)

check("an empty token falls back rather than blanking the default", function()
  local Config = loadConfig { token = "" }
  eq(Config.token, nil)
end)

check("an empty client id does not wipe the shipped default", function()
  local Config = loadConfig { client_id = "" }
  -- the shipped client id must survive, or the plugin cannot sign in
  if not Config.client_id or Config.client_id == "" then
    error("empty override blanked the default client id")
  end
end)

check("the example placeholder is treated as no token", function()
  local Config = loadConfig { token = "your token here" }
  eq(Config.token, nil)
end)

check("an explicit nil token does not error", function()
  local Config = loadConfig { token = nil, client_id = "x" }
  eq(Config.client_id, "x")
end)

check("a malformed user config does not break loading", function()
  local Config = loadConfig { unexpected = true, token = "hc_pat_x" }
  eq(Config.token, "hc_pat_x")
end)

print("")
print(string.format("%d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)