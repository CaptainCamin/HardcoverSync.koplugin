-- The installed version as the plugin reads it from _meta.lua: stable and beta.
--
-- Run with:  lua spec/version_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local function load(version)
  package.loaded["hardcover_version"] = nil
  package.preload["_meta"] = function() return { version = version } end
  package.loaded["_meta"] = nil
  return dofile(PLUGIN .. "/hardcover_version.lua")
end

check("a stable version is its three numbers, with no beta", function()
  local v = load("1.4.1")
  assert(#v == 3 and v[1] == 1 and v[2] == 4 and v[3] == 1, table.concat(v, ","))
  assert(v.beta == nil and v.text == "1.4.1")
  assert(table.concat(v, ".") == "1.4.1")
end)

check("a beta carries its number and its full text", function()
  local v = load("1.4.1-beta.2")
  assert(#v == 3 and v[3] == 1 and v.beta == 2 and v.text == "1.4.1-beta.2")
  assert(load("2.0.0-beta").beta == 0, "a suffix with no number is beta 0")
  assert(load("2.0.0-rc1").beta == 1)
end)

check("an odd version does not raise", function()
  assert(pcall(load, "1.4"))
  assert(pcall(load, "weird"))
end)

r.finish()
