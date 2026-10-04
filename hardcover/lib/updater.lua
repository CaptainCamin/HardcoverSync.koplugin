-- Updating the plugin from its GitHub releases.
--
-- `due` / `remember` decide when to ask GitHub (at most once a day, and only
-- when the reader hasn't turned checking off). `install` downloads the release
-- zip, checks it, and swaps it in for the installed folder; the new version
-- runs after a KOReader restart. Every step reports failure rather than
-- raising, and the installed plugin is only touched once the new copy has been
-- unpacked and looks like this plugin.

local SETTING = require("hardcover/lib/constants/settings")

local Updater = {}

local DAY = 24 * 60 * 60

-- Ask GitHub if checking is on (default on) and the last check was over a day ago.
function Updater.due(settings, now)
  if settings:readSetting(SETTING.UPDATE_CHECK) == false then return false end
  local last = settings:readSetting(SETTING.UPDATE_LAST_CHECK)
  if type(last) ~= "number" then return true end
  return (now or os.time()) - last >= DAY
end

-- Record a check's outcome: the newer version, or nil for "up to date".
function Updater.remember(settings, release, now)
  settings:updateSetting(SETTING.UPDATE_LAST_CHECK, now or os.time())
  settings:updateSetting(SETTING.UPDATE_AVAILABLE, release and release.version and {
    version = release.version,
    notes = release.notes,
    zip_url = release.zip_url,
  } or false)
end

-- { version, notes, zip_url } of a known newer release that is still newer than
-- `current` (it may have been installed since the check), else nil.
function Updater.available(settings, current)
  local found = settings:readSetting(SETTING.UPDATE_AVAILABLE)
  if type(found) ~= "table" or type(found.version) ~= "string" then return nil end
  local beta = settings:readSetting(SETTING.UPDATE_BETA) == true
  if not require("hardcover/lib/github").newerVersion(found.version, current, beta) then return nil end
  return found
end

-- Where the plugin is installed, from where this file was loaded.
function Updater.pluginDir()
  local source = debug.getinfo(1, "S").source
  return source:match("^@(.*)/hardcover/lib/updater%.lua$")
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function run(cmd)
  local ok, how, code = os.execute(cmd)
  -- LuaJIT returns the status number, Lua 5.2+ returns true/"exit"/code
  if type(ok) == "number" then return ok == 0 end
  return ok == true and (how == nil or how == "exit") and (code == nil or code == 0)
end

local function download(url, path)
  local http = require("socket.http")
  local ltn12 = require("ltn12")
  local socketutil = require("socketutil")
  local file = io.open(path, "wb")
  if not file then return false, "cannot write " .. path end
  socketutil:set_timeout(15, 120)
  local ok, res, code = pcall(http.request, {
    url = url,
    sink = ltn12.sink.file(file),
  })
  socketutil:reset_timeout()
  if not ok or code ~= 200 then
    return false, "download failed (" .. tostring(ok and code or res) .. ")"
  end
  return true
end

--
-- Install a release over `plugin_dir` (the installed folder). `fetch` is the
-- download step, replaceable for tests. Returns true, or false and a reason.
--
function Updater.install(release, plugin_dir, fetch)
  if not release or not release.zip_url then return false, "this release has no download" end
  fetch = fetch or download

  local parent, name = plugin_dir:match("^(.*)/([^/]+)/?$")
  if not parent then return false, "cannot tell where the plugin is installed" end

  local zip = parent .. "/." .. name .. ".update.zip"
  local staging = parent .. "/." .. name .. ".update"
  local backup = parent .. "/." .. name .. ".old"

  local function cleanup()
    os.remove(zip)
    run("rm -rf " .. shell_quote(staging))
  end

  local ok, err = fetch(release.zip_url, zip)
  if not ok then cleanup(); return false, err end

  run("rm -rf " .. shell_quote(staging))
  if not run("unzip -tq " .. shell_quote(zip) .. " >/dev/null 2>&1") then
    cleanup(); return false, "the download is damaged"
  end
  if not run("mkdir -p " .. shell_quote(staging) .. " && unzip -oq " .. shell_quote(zip)
    .. " -d " .. shell_quote(staging) .. " >/dev/null 2>&1") then
    cleanup(); return false, "cannot unpack the download"
  end

  -- the zip holds one folder; it must be a plugin with a main.lua and _meta.lua
  local new_dir
  for dir in io.popen("ls -1 " .. shell_quote(staging) .. " 2>/dev/null"):lines() do
    new_dir = staging .. "/" .. dir
    break
  end
  local function exists(path) local f = io.open(path, "r"); if f then f:close() end return f ~= nil end
  if not new_dir or not exists(new_dir .. "/main.lua") or not exists(new_dir .. "/_meta.lua") then
    cleanup(); return false, "the download is not a plugin"
  end

  -- keep the old copy until the new one is in place, and put it back on failure
  run("rm -rf " .. shell_quote(backup))
  if not run("mv " .. shell_quote(plugin_dir) .. " " .. shell_quote(backup)) then
    cleanup(); return false, "cannot replace the installed plugin"
  end
  if not run("mv " .. shell_quote(new_dir) .. " " .. shell_quote(plugin_dir)) then
    run("mv " .. shell_quote(backup) .. " " .. shell_quote(plugin_dir))
    cleanup(); return false, "cannot move the new version into place"
  end
  run("rm -rf " .. shell_quote(backup))
  cleanup()
  return true
end

return Updater
