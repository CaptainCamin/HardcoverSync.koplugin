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

print("\n== beta versions ==")

check("a beta is offered only when betas are on", function()
  assert(Github.newerVersion("v1.5.0-beta.2", CURRENT) == nil)
  assert(Github.newerVersion("v1.5.0-beta.2", CURRENT, true) == "1.5.0-beta.2")
  assert(Github.newerVersion("v0.9.1", CURRENT, true) == "0.9.1", "a stable release is still offered")
end)

check("a beta of the version you have, or an older one, is not an update", function()
  assert(Github.newerVersion("v0.9.0-beta.3", CURRENT, true) == nil, "a beta of what you already run stable")
  assert(Github.newerVersion("v0.8.0-beta.1", CURRENT, true) == nil)
end)

check("from a beta: the next beta, the stable release of it, but not an older beta", function()
  local beta2 = { 1, 4, 1, beta = 2 }
  assert(Github.newerVersion("v1.4.1-beta.3", beta2, true) == "1.4.1-beta.3")
  assert(Github.newerVersion("v1.4.1-beta.2", beta2, true) == nil)
  assert(Github.newerVersion("v1.4.1-beta.1", beta2, true) == nil)
  assert(Github.newerVersion("v1.4.1", beta2) == "1.4.1", "the stable release comes without betas on")
  assert(Github.newerVersion("v1.4.2-beta.1", beta2, true) == "1.4.2-beta.1")
  assert(Github.newerVersion("v1.4.0", beta2, true) == nil)
end)

check("the number in a beta suffix is not a version part", function()
  local p = Github.parse("v1.5-beta.2")
  assert(#p.parts == 2 and p.parts[1] == 1 and p.parts[2] == 5 and p.beta == 2, #p.parts .. " parts")
  assert(Github.newerVersion("v1.5-beta.2", { 1, 5, 1 }, true) == nil, "ranked above 1.5.1")
  assert(Github.newerVersion("v1.5-beta.2", { 1, 4, 9 }, true) == "1.5-beta.2")
  local q = Github.parse("v2-beta.7")
  assert(#q.parts == 1 and q.parts[1] == 2 and q.beta == 7)
  local plain = Github.parse("release-1.0")
  assert(plain.beta == nil and plain.parts[1] == 1)
end)

check("tags that are not versions never raise, betas on or off", function()
  for _, tag in ipairs({ "latest", "", "v-beta", "1.0.0-", "x-beta.9" }) do
    assert(pcall(Github.newerVersion, tag, { 1, 0, 0, beta = 1 }, true), tag)
  end
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

check("with betas on, the newest version in the list is taken, not just the first", function()
  local real = require("json")
  local requested
  local http = require("socket.http")
  local original = http.request
  http.request = function(req) requested = req.url; return original(req) end
  real.decode = setmetatable({ simple = true }, { __call = function() return {
    { tag_name = "v0.9.5-beta.1", assets = { { name = "a.koplugin.zip", browser_download_url = "https://beta1" } } },
    { tag_name = "v1.0.0", draft = true },
    { tag_name = "v0.9.5-beta.3", assets = { { name = "a.koplugin.zip", browser_download_url = "https://beta3" } } },
    { tag_name = "v0.9.4", assets = { { name = "a.koplugin.zip", browser_download_url = "https://stable" } } },
  } end })
  body = "{}"
  local got
  Github:latestReleaseAsync(function(release) got = release end, true)
  http.request = original
  assert(requested and requested:find("/releases?", 1, true), "asked for " .. tostring(requested))
  assert(got and got.tag == "v0.9.5-beta.3" and got.version == "0.9.5-beta.3", tostring(got and got.tag))
  assert(got.zip_url == "https://beta3")
  -- the same answer with betas off asks for the latest stable release only
  requested = nil
  http.request = function(req) requested = req.url; return original(req) end
  Github:latestReleaseAsync(function(release) got = release end)
  http.request = original
  assert(requested and requested:find("/releases/latest", 1, true), "asked for " .. tostring(requested))
end)

check("the reason a check failed is told: no answer, refused for now, or not a release list", function()
  local http = require("socket.http")
  local original = http.request
  local why
  local function ask() local got; Github:latestReleaseAsync(function(rel, w) got = rel; why = w end); return got end

  http.request = function() return nil, "timeout" end
  assert(ask() == nil and why == "network", tostring(why))
  http.request = function() error("socket exploded") end
  assert(ask() == nil and why == "network", tostring(why))
  code = 403
  http.request = function(req) if req.sink then req.sink("{}") end return 1, 403 end
  assert(ask() == nil and why == "limited", tostring(why))
  http.request = function(req) if req.sink then req.sink("{}") end return 1, 429 end
  assert(ask() == nil and why == "limited", tostring(why))
  http.request = function(req) if req.sink then req.sink("<html>") end return 1, 502 end
  assert(ask() == nil and why == "answer", tostring(why))
  http.request = original
  code = 200
end)

check("the release check waits long enough for the list of releases on a slow connection", function()
  local su = require("socketutil")
  local block, total
  local original = su.set_timeout
  su.set_timeout = function(_, b, t) block, total = b, t end
  body = "{}"
  Github:latestReleaseAsync(function() end, true)
  su.set_timeout = original
  assert(block and block >= 10 and total and total >= 20, "timeouts " .. tostring(block) .. "/" .. tostring(total))
end)

r.finish()
