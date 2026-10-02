-- The update checker: when it asks GitHub, what it remembers, and installing a
-- release zip over the plugin folder (with a real zip, in a temp directory).
--
-- Run with:  lua spec/updater_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

package.preload["hardcover_version"] = function() return { 1, 0, 0 } end
package.preload["hardcover/lib/github"] = function()
  return { newerVersion = function(tag, current)
    return tag:gsub("^v", "") ~= table.concat(current, ".") and tag:gsub("^v", "") or nil
  end }
end

local Updater = dofile(PLUGIN .. "/hardcover/lib/updater.lua")

local function settings(initial)
  local store = initial or {}
  return {
    readSetting = function(_, k) return store[k] end,
    updateSetting = function(_, k, v) store[k] = v end,
  }, store
end

print("\n== when to ask ==")

check("a first run asks, and so does a check over a day old", function()
  assert(Updater.due(settings(), 1000))
  assert(Updater.due(settings({ update_last_check = 1000 }), 1000 + 86400))
end)

check("a check within the day, or checking turned off, does not", function()
  assert(not Updater.due(settings({ update_last_check = 1000 }), 1000 + 3600))
  assert(not Updater.due(settings({ update_check = false }), 1000))
end)

print("\n== what is remembered ==")

check("a newer release is kept, and goes away once installed", function()
  local s = settings()
  Updater.remember(s, { version = "1.1.0", notes = "n", zip_url = "u" }, 5)
  local found = Updater.available(s, { 1, 0, 0 })
  assert(found and found.version == "1.1.0" and found.zip_url == "u")
  assert(Updater.available(s, { 1, 1, 0 }) == nil, "already installed")
end)

check("an up-to-date answer clears it", function()
  local s = settings()
  Updater.remember(s, { version = "1.1.0" }, 5)
  Updater.remember(s, { tag = "v1.0.0" }, 6)
  assert(Updater.available(s, { 1, 0, 0 }) == nil)
end)

print("\n== installing ==")

local function sh(cmd) assert(os.execute(cmd) == 0 or os.execute(cmd) == true, cmd) end
local tmp = os.tmpname(); os.remove(tmp)
sh("mkdir -p " .. tmp)

local function make_zip(name, with_main)
  local src = tmp .. "/src"
  sh("rm -rf " .. src .. " && mkdir -p " .. src .. "/" .. name)
  sh("echo 'new' > " .. src .. "/" .. name .. "/_meta.lua")
  if with_main then sh("echo 'new' > " .. src .. "/" .. name .. "/main.lua") end
  sh("cd " .. src .. " && zip -qr " .. tmp .. "/release.zip " .. name)
  return tmp .. "/release.zip"
end

local function read(path) local f = io.open(path); local c = f and f:read("*a"); if f then f:close() end return c end

local function installed()
  sh("rm -rf " .. tmp .. "/plugins && mkdir -p " .. tmp .. "/plugins/x.koplugin")
  sh("echo old > " .. tmp .. "/plugins/x.koplugin/main.lua")
  return tmp .. "/plugins/x.koplugin"
end

local function fetch_zip(zip)
  return function(_, to) sh("cp " .. zip .. " " .. to); return true end
end

check("a good zip replaces the plugin and leaves nothing behind", function()
  local dir = installed()
  sh("rm -f " .. tmp .. "/release.zip")
  local ok, err = Updater.install({ zip_url = "u" }, dir, fetch_zip(make_zip("x.koplugin", true)))
  assert(ok, err)
  assert(read(dir .. "/main.lua") == "new\n")
  local left = io.popen("ls -A " .. tmp .. "/plugins"):read("*a")
  assert(left == "x.koplugin\n", left)
end)

check("a zip that is not a plugin is refused and the old copy stays", function()
  local dir = installed()
  sh("rm -f " .. tmp .. "/release.zip")
  local ok, err = Updater.install({ zip_url = "u" }, dir, fetch_zip(make_zip("x.koplugin", false)))
  assert(not ok and err:find("not a plugin"), tostring(err))
  assert(read(dir .. "/main.lua") == "old\n")
end)

check("a damaged download is refused and the old copy stays", function()
  local dir = installed()
  local ok, err = Updater.install({ zip_url = "u" }, dir, function(_, to)
    local f = io.open(to, "wb"); f:write("junk"); f:close(); return true
  end)
  assert(not ok and err:find("damaged"), tostring(err))
  assert(read(dir .. "/main.lua") == "old\n")
end)

check("a failed download and a release with no zip are reported", function()
  local dir = installed()
  local ok, err = Updater.install({ zip_url = "u" }, dir, function() return false, "offline" end)
  assert(not ok and err == "offline")
  ok, err = Updater.install({}, dir)
  assert(not ok and err:find("no download"))
  assert(read(dir .. "/main.lua") == "old\n")
end)

sh("rm -rf " .. tmp)
r.finish()
