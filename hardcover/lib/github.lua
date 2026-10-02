local http = require("socket.http")
local json = require("json")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")

local UIManager = require("ui/uimanager")

local VERSION = require("hardcover_version")

local RELEASE_API = "https://api.github.com/repos/CaptainCamin/HardcoverSync.koplugin/releases?per_page=1"

-- How long to wait for GitHub before giving up and showing the About box
-- without the version comparison. Kept short: this runs while the user is
-- waiting on a menu item, and the release check is a nicety, not the point.
local RELEASE_TIMEOUT = 5

local Github = {}

--
-- The version in a release tag if it is newer than `current` (a list of numbers,
-- e.g. { 0, 9, 0 }), else nil. Pure, and tolerant: a tag is whatever the
-- maintainer typed -- "v0.9.0", "0.7", "release-1.0", "0.9.0-beta" -- and this
-- runs from a menu callback, where an error takes KOReader down with it. (It
-- used to compare tonumber("v0") with a number: the first "v"-prefixed release
-- made the About box crash.) Missing parts count as 0; a tag with no numbers is
-- not a version.
--
function Github.newerVersion(tag, current)
  if type(tag) ~= "string" then return nil end

  local parts = {}
  for number in tag:gmatch("%d+") do
    parts[#parts + 1] = tonumber(number)
    if #parts == 3 then break end
  end
  if #parts == 0 then return nil end

  -- a prerelease suffix ("-beta", "-rc1") is not offered as an update
  if tag:match("%d%-%a") then return nil end

  for i = 1, math.max(#parts, #(current or {})) do
    local latest, installed = parts[i] or 0, (current or {})[i] or 0
    if latest > installed then
      return table.concat(parts, ".")
    elseif latest < installed then
      return nil
    end
  end
  return nil
end

function Github:newestRelease()
  local responseBody = {}

  -- A timeout is essential. This request used to have none, so on a device with
  -- no route to api.github.com it blocked until the TCP stack gave up -- tens of
  -- seconds to minutes -- and because the caller shows its dialog only after
  -- this returns, nothing appeared at all. On e-ink that reads as a dead screen
  -- until something forces a repaint.
  socketutil:set_timeout(RELEASE_TIMEOUT, RELEASE_TIMEOUT)

  local ok, res, code, responseHeaders = pcall(http.request, {
    url = RELEASE_API,
    sink = ltn12.sink.table(responseBody),
  })

  socketutil:reset_timeout()

  if not ok or type(code) ~= "number" then
    return nil
  end

  if code == 200 or code == 304 then
    local decoded_ok, data = pcall(json.decode, table.concat(responseBody), json.decode.simple)
    if not decoded_ok or type(data) ~= "table" or #data == 0 then
      return nil
    end
    local tag = data[1].tag_name
    if type(tag) ~= "string" then
      return nil
    end
    return Github.newerVersion(tag, VERSION)
  end
end

--
-- Fetch the latest release without blocking the caller.
--
-- Prefer this over newestRelease() from a menu callback: the About box should
-- appear immediately and fill in the version comparison if the answer arrives.
-- See the timeout note above for what the blocking version cost.
--
function Github:newestReleaseAsync(callback)
  UIManager:nextTick(function()
    -- never let a bad answer from GitHub raise out of a scheduled task
    local ok, release = pcall(Github.newestRelease, Github)
    callback(ok and release or nil)
  end)
end

return Github
