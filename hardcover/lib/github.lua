local http = require("socket.http")
local json = require("json")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")

local UIManager = require("ui/uimanager")

local VERSION = require("hardcover_version")

local RELEASE_API = "https://api.github.com/repos/CaptainCamin/HardcoverSync.koplugin/releases/latest"
-- every release including pre-releases, newest first (used when beta updates are on)
local RELEASE_LIST_API = "https://api.github.com/repos/CaptainCamin/HardcoverSync.koplugin/releases?per_page=15"

-- How long to wait for GitHub before giving up and showing the About box
-- without the version comparison. Kept short: this runs while the user is
-- waiting on a menu item, and the release check is a nicety, not the point.
local RELEASE_TIMEOUT = 5

local Github = {}

--
-- A release tag as { parts = { major, minor, patch }, beta = n | nil }: whatever the
-- maintainer typed -- "v0.9.0", "0.7", "release-1.0", "1.4.1-beta.2" -- or nil when
-- there are no numbers in it (not a version). Pure and tolerant: this runs from a
-- menu callback, where an error takes KOReader down with it. A suffix after a
-- number ("-beta", "-rc1", "-beta.2") makes it a pre-release; its number is the
-- last one in the suffix (0 when it has none).
--
function Github.parse(tag)
  if type(tag) ~= "string" then return nil end

  local parts = {}
  for number in tag:gmatch("%d+") do
    parts[#parts + 1] = tonumber(number)
    if #parts == 3 then break end
  end
  if #parts == 0 then return nil end

  local beta
  local suffix = tag:match("%d%-(%a.*)$")
  if suffix then beta = tonumber(suffix:match("(%d+)%s*$")) or 0 end
  return { parts = parts, beta = beta }
end

-- 1, 0 or -1: a is newer than, the same as, or older than b (both from Github.parse,
-- or the installed version, which has the same shape in `parts` and `beta`). A stable
-- release is newer than any beta of the same numbers.
local function compare(a, b)
  for i = 1, math.max(#a.parts, #b.parts) do
    local x, y = a.parts[i] or 0, b.parts[i] or 0
    if x ~= y then return x > y and 1 or -1 end
  end
  if a.beta == b.beta then return 0 end
  if a.beta == nil then return 1 end
  if b.beta == nil then return -1 end
  return a.beta > b.beta and 1 or -1
end

local function text(parsed)
  local out = table.concat(parsed.parts, ".")
  if parsed.beta then out = out .. "-beta." .. parsed.beta end
  return out
end

--
-- The version in a release tag if it is newer than `current` (a list of numbers,
-- e.g. { 0, 9, 0 }, with `.beta` when the installed one is a beta), else nil. A
-- pre-release tag only counts when `include_beta` is on. Missing parts count as 0.
--
function Github.newerVersion(tag, current, include_beta)
  local latest = Github.parse(tag)
  if not latest then return nil end
  if latest.beta and not include_beta then return nil end

  local installed = { parts = {}, beta = type(current) == "table" and current.beta or nil }
  for i, n in ipairs(type(current) == "table" and current or {}) do installed.parts[i] = tonumber(n) or 0 end

  if compare(latest, installed) > 0 then return text(latest) end
  return nil
end

--
-- The newest release, or nil when GitHub can't be reached or answers oddly:
-- { tag, version (only when newer than the installed one), notes, zip_url }.
-- Blocks for at most RELEASE_TIMEOUT seconds; callers use the Async wrapper.
--
function Github:latestRelease(include_beta)
  local responseBody = {}

  -- A timeout is essential. This request used to have none, so on a device with
  -- no route to api.github.com it blocked until the TCP stack gave up -- tens of
  -- seconds to minutes -- and because the caller shows its dialog only after
  -- this returns, nothing appeared at all. On e-ink that reads as a dead screen
  -- until something forces a repaint.
  socketutil:set_timeout(RELEASE_TIMEOUT, RELEASE_TIMEOUT)

  local ok, res, code = pcall(http.request, {
    url = include_beta and RELEASE_LIST_API or RELEASE_API,
    sink = ltn12.sink.table(responseBody),
  })

  socketutil:reset_timeout()

  if not ok or type(code) ~= "number" then
    return nil
  end

  if code == 200 or code == 304 then
    local decoded_ok, data = pcall(json.decode, table.concat(responseBody), json.decode.simple)
    if not decoded_ok or type(data) ~= "table" or (data[1] == nil and data.tag_name == nil) then
      return nil
    end
    -- /releases/latest is one release (never a pre-release or draft). With beta
    -- updates on the answer is a list, newest first by date: take the highest
    -- version in it, a stable release counting above a beta of the same numbers.
    local release = data[1] or data
    if include_beta and data[1] ~= nil then
      local best
      for _, candidate in ipairs(data) do
        local parsed = type(candidate) == "table" and candidate.draft ~= true and Github.parse(candidate.tag_name)
        if parsed and (not best or compare(parsed, best.parsed) > 0) then
          best = { release = candidate, parsed = parsed }
        end
      end
      release = best and best.release or release
    end
    local tag = release.tag_name
    if type(tag) ~= "string" then
      return nil
    end

    local zip_url
    if type(release.assets) == "table" then
      for _, asset in ipairs(release.assets) do
        if type(asset) == "table" and type(asset.name) == "string"
          and asset.name:match("%.koplugin%.zip$") then
          zip_url = asset.browser_download_url
          break
        end
      end
    end

    return {
      tag = tag,
      version = Github.newerVersion(tag, VERSION, include_beta),
      notes = type(release.body) == "string" and release.body or nil,
      zip_url = type(zip_url) == "string" and zip_url or nil,
    }
  end
end

-- The version of the newest release if it is newer than the installed one.
function Github:newestRelease(include_beta)
  local release = self:latestRelease(include_beta)
  return release and release.version or nil
end

--
-- Fetch the latest release without blocking the caller.
--
-- Prefer this over newestRelease() from a menu callback: the About box should
-- appear immediately and fill in the version comparison if the answer arrives.
-- See the timeout note above for what the blocking version cost.
--
function Github:latestReleaseAsync(callback, include_beta)
  UIManager:nextTick(function()
    local ok, release = pcall(Github.latestRelease, Github, include_beta)
    callback(ok and release or nil)
  end)
end

function Github:newestReleaseAsync(callback, include_beta)
  UIManager:nextTick(function()
    -- never let a bad answer from GitHub raise out of a scheduled task
    local ok, release = pcall(Github.newestRelease, Github, include_beta)
    callback(ok and release or nil)
  end)
end

return Github
