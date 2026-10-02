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
    local index = 1
    for str in string.gmatch(tag, "([^.]+)") do
      local part = tonumber(str)

      if part < VERSION[index] then
        return nil
      elseif part > VERSION[index] then
        return tag
      end
      index = index + 1
    end
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
    local release = Github:newestRelease()
    callback(release)
  end)
end

return Github
