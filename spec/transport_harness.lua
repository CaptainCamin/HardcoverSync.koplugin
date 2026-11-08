-- The HTTP transport: what it hands back as "<code>:<body>", with socket.http faked.
--
-- Run with:  lua spec/transport_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
support.preload_json(PLUGIN)

local answer
package.preload["socket.http"] = function()
  return { request = function(req)
    if answer.body then req.sink(answer.body) end
    return 1, answer.code, answer.headers, "status"
  end }
end
package.preload["ltn12"] = function() return { source = { string = function(s) return s end } } end
package.preload["socketutil"] = function()
  return {
    TIMEOUT_CODE = "timeout", SSL_HANDSHAKE_CODE = "wantread", SINK_TIMEOUT_CODE = "sink timeout",
    set_timeout = function() end, reset_timeout = function() end,
    table_sink = function(t) return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end end,
  }
end

local r = support.reporter()
local check = r.test
local Transport = require("hardcover/lib/transport")

local function post(a)
  answer = a
  return Transport.post("https://example.test", {}, { query = "{ x }" })
end

check("a 200 is the code and the body", function()
  local out = post({ code = 200, body = '{"data":{}}', headers = {} })
  assert(out == '200:{"data":{}}', out)
end)

check("a 429 carries the Retry-After seconds after the code", function()
  local out = post({ code = 429, body = "{}", headers = { ["retry-after"] = "7" } })
  assert(out == "429;retry-after=7:{}", out)
end)

check("a 429 without Retry-After is the plain code", function()
  local out = post({ code = 429, body = "", headers = {} })
  assert(out == "429:", out)
end)

check("Retry-After is only passed on with a 429 or 503", function()
  local out = post({ code = 200, body = "{}", headers = { ["retry-after"] = "7" } })
  assert(out == "200:{}", out)
end)

check("a request cut short is the socket code and no body", function()
  local out = post({ code = "timeout", headers = nil })
  assert(out == "timeout:", out)
end)

r.finish()
