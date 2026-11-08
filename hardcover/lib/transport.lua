-- One HTTPS POST to the GraphQL endpoint, and nothing else.
--
-- This is what runs in the forked subprocess (see runtime.lua), so it must not touch
-- anything the parent needs afterwards: the headers, token included, are resolved by the
-- caller and passed in. The answer is a string, "<code>:<body>", because a subprocess can
-- only hand back text: code is the HTTP status, or a socketutil code when the request was
-- cut short (then the body is empty). A 429 or 503 may carry ";retry-after=N" after the code.

local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local socketutil = require("socketutil")

local Transport = {}

local MAX_TIME = 12
local TIMEOUT = 6

-- How long Hardcover said to wait (Retry-After) with a 429 or 503, passed on after the code
-- ("429;retry-after=7") because the answer is one string.
local function retryAfter(code, headers)
  if (code ~= 429 and code ~= 503) or type(headers) ~= "table" then return "" end
  local seconds = tonumber(headers["retry-after"])
  return seconds and (";retry-after=" .. math.floor(seconds)) or ""
end

function Transport.post(url, headers, body)
  local sink = {}
  socketutil:set_timeout(TIMEOUT, MAX_TIME)
  local request = {
    url = url,
    method = "POST",
    headers = headers,
    source = ltn12.source.string(json.encode(body)),
    sink = socketutil.table_sink(sink),
  }

  local _, code, response_headers, _status = http.request(request)
  socketutil:reset_timeout()

  local content = table.concat(sink) -- empty or content accumulated till now
  if code == socketutil.TIMEOUT_CODE or
    code == socketutil.SSL_HANDSHAKE_CODE or
    code == socketutil.SINK_TIMEOUT_CODE
  then
    logger.warn("request interrupted:", code)
    return code .. ':'
  end

  if type(code) == "string" then
    logger.dbg("Request error", code)
  end

  if type(code) == "number" and (code < 200 or code > 299) then
    logger.dbg("Request error", code, content)
  end

  return code .. retryAfter(code, response_headers) .. ':' .. content
end

return Transport
