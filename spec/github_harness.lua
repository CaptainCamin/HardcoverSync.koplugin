-- Reading a release tag from GitHub for the About box.
--
-- A tag is whatever the maintainer typed. The About box used to compare
-- tonumber("v0") with a number, so the first release whose tag began with "v"
-- crashed KOReader the moment GitHub answered.
--
-- Run with:  lua spec/github_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

-- the KOReader modules github.lua loads, as stand-ins
local body = nil
local code = 200
package.preload["socket.http"] = function() return { request = function(req)
  if req.sink then req.sink(body) end
  return 1, code
end } end
package.preload["json"] = function()
  local j = { decode = setmetatable({ simple = true }, { __call = function() end }) }
  return j
end
package.preload["ltn12"] = function() return { sink = { table = function(t) return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end end } } end
package.preload["socketutil"] = function() return { set_timeout = function() end, reset_timeout = function() end } end
package.preload["ui/uimanager"] = function() return { nextTick = function(_, fn) fn() end } end
package.preload["hardcover_version"] = function() return { 0, 9, 0 } end

local Github = require("hardcover/lib/github")

print("\n== is a tag newer? ==")

local CURRENT = { 0, 9, 0 }

check("a newer tag is offered, without any leading v", function()
  assert(Github.newerVersion("v0.9.1", CURRENT) == "0.9.1")
  assert(Github.newerVersion("0.10.0", CURRENT) == "0.10.0")
  assert(Github.newerVersion("v1.0.0", CURRENT) == "1.0.0")
end)

check("the same or an older tag is not", function()
  assert(Github.newerVersion("v0.9.0", CURRENT) == nil)
  assert(Github.newerVersion("0.9.0", CURRENT) == nil)
  assert(Github.newerVersion("v0.8.0", CURRENT) == nil)
  assert(Github.newerVersion("0.7", CURRENT) == nil)
end)

check("a tag with fewer parts is padded: 0.9 is 0.9.0, 0.10 is newer", function()
  assert(Github.newerVersion("0.9", CURRENT) == nil)
  assert(Github.newerVersion("0.10", CURRENT) == "0.10")
end)

check("odd tags never raise (this crashed KOReader)", function()
  for _, tag in ipairs({ "v", "", "latest", "release-", "nightly", "v.1", "...", "v0.9.0.1" }) do
    local ok, err = pcall(Github.newerVersion, tag, CURRENT)
    assert(ok, "raised on '" .. tag .. "': " .. tostring(err))
  end
  assert(Github.newerVersion("latest", CURRENT) == nil and Github.newerVersion("", CURRENT) == nil)
  assert(Github.newerVersion(nil, CURRENT) == nil and Github.newerVersion(42, CURRENT) == nil)
  assert(Github.newerVersion("v0.9.0.1", CURRENT) == nil, "a fourth part must be ignored, not compared")
end)

check("a prerelease is not offered as an update", function()
  assert(Github.newerVersion("v1.0.0-beta", CURRENT) == nil)
  assert(Github.newerVersion("1.0.0-rc1", CURRENT) == nil)
end)

check("it still works with no current version", function()
  assert(Github.newerVersion("v1.0.0", nil) == "1.0.0" and Github.newerVersion("v1.0.0", {}) == "1.0.0")
end)

print("\n== asking GitHub ==")

check("the async check hands back nil, not an error, when the answer is junk", function()
  body = { "not json at all" }
  -- decode raising is what junk looks like; the stub json.decode returns nil
  local got = "unset"
  Github:newestReleaseAsync(function(release) got = release end)
  assert(got == nil, tostring(got))
end)

check("the async check survives the check itself raising", function()
  local original = Github.newestRelease
  Github.newestRelease = function() error("boom") end
  local got = "unset"
  Github:newestReleaseAsync(function(release) got = release end)
  Github.newestRelease = original
  assert(got == nil, "the error escaped or was passed on: " .. tostring(got))
end)

check("the latest release carries its tag, version, notes and zip", function()
  local real = require("json")
  real.decode = setmetatable({ simple = true }, { __call = function() return { { tag_name = "v1.2.0", body = "notes", assets = {
    { name = "other.txt", browser_download_url = "x" },
    { name = "hardcoversync.koplugin.zip", browser_download_url = "https://z" } } } } end })
  body = "{}"
  local got
  Github:latestReleaseAsync(function(release) got = release end)
  assert(got and got.tag == "v1.2.0" and got.version == "1.2.0", tostring(got and got.version))
  assert(got.notes == "notes" and got.zip_url == "https://z")
end)

r.finish()
