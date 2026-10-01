-- Proves the API resolves its access token in the parent process.
--
-- HardcoverApi:query runs the HTTP request in a forked subprocess. Resolving
-- the token can refresh it, and OAuth refresh tokens rotate and are single
-- use. A refresh performed in the child updates the file on disk but not the
-- parent's memory, so the parent refreshes again with the spent token, which
-- makes Hardcover revoke the whole chain. This harness fakes the fork by
-- flagging "in child" while the subprocess body runs.
--
-- Run with:  lua spec/api_token_fork_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_ui_stubs()
support.preload_http_stubs()
support.preload_json(PLUGIN)

local in_child = false
local sent_headers

package.preload["socket.http"] = function()
  return {
    request = function(req)
      sent_headers = req.headers
      req.sink('{"data":{"me":[{"id":1}]}}')
      return 1, 200, {}, "OK"
    end,
  }
end
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return true end, isOnline = function() return true end }
end
package.preload["ui/trapper"] = function()
  return {
    dismissableRunInSubprocess = function(_, fn)
      in_child = true
      local ok, result = pcall(fn)
      in_child = false
      if not ok then error(result, 0) end
      return true, result
    end,
  }
end
package.preload["ffi/util"] = function()
  local util = { template = function(t) return t end }
  setmetatable(util, { __call = function(_, s) return tostring(s) end })
  return util
end
package.preload["ffi"] = function() return {} end
package.preload["ffi/pointer"] = function() return {} end
package.preload["ffi/utf8"] = function() return { char = string.char, len = string.len } end
package.preload["blitbuffer"] = function() return {} end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end

local Api = require("hardcover/lib/hardcover_api")

local r = support.reporter()
local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local function newAuth()
  local auth = { calls = 0, called_in_child = false }
  function auth:accessToken()
    self.calls = self.calls + 1
    if in_child then self.called_in_child = true end
    return "hc_at_fresh"
  end
  function auth:invalidateAccessToken() end
  return auth
end

print("\n== the access token is resolved in the parent ==")

check("a request never resolves (and so never refreshes) the token in the subprocess", function()
  local auth = newAuth()
  Api.auth = auth
  Api:query("{ me { id } }")
  assert(auth.calls == 1, "token resolved " .. auth.calls .. " times")
  assert(not auth.called_in_child, "token was resolved inside the forked subprocess")
end)

check("the token resolved in the parent is the one sent", function()
  Api.auth = newAuth()
  Api:query("{ me { id } }")
  assert(sent_headers and sent_headers.Authorization == "Bearer hc_at_fresh",
    "sent " .. tostring(sent_headers and sent_headers.Authorization))
end)

check("each request resolves the token once", function()
  local auth = newAuth()
  Api.auth = auth
  Api:query("{ me { id } }")
  Api:query("{ me { id } }")
  assert(auth.calls == 2, "calls: " .. auth.calls)
end)

r.finish()
