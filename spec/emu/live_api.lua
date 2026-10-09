--[[--
The real Hardcover API for the live scenarios (live.lua, live_lists.lua): Api:query is
replaced by a synchronous curl to api.hardcover.app with the access token from
KO_LIVE_TOKEN_FILE (JSON with an "access_token" key, as the OAuth sign-in stores it).

The token is written to a header file (mode 0600) so it is never on a command line, and
is never printed or logged; the request log (KO_LIVE_OUT/live_requests.log) records only
the operation, the status and the size. Returns nil when no token file is set, so a
scenario can skip itself and never runs in CI.
]]

local LiveApi = {}

local function read_token(path)
  local f = assert(io.open(path, "r"), "cannot read " .. path)
  local body = f:read("*a")
  f:close()
  return assert(body:match('"access_token"%s*:%s*"([^"]+)"'), "no access_token in " .. path)
end

-- Point the plugin's API at the real server. Returns a handle with `bytes` (received so
-- far), `requests` and close(), or nil when KO_LIVE_TOKEN_FILE is not set.
function LiveApi.install()
  local token_file = os.getenv("KO_LIVE_TOKEN_FILE")
  if not token_file or token_file == "" then return nil end
  local out = os.getenv("KO_LIVE_OUT") or "/tmp"
  local token = read_token(token_file)

  local Api = require("hardcover/lib/hardcover_api")
  local json = require("json")
  local log = assert(io.open(out .. "/live_requests.log", "w"))

  local headers_path = out .. "/live_headers.txt"
  local hf = assert(io.open(headers_path, "w"))
  os.execute("chmod 600 '" .. headers_path .. "'")
  hf:write("Authorization: Bearer " .. token .. "\ncontent-type: application/json\n")
  hf:close()
  local body_path = out .. "/live_body.json"

  local handle = { bytes = 0, requests = 0 }

  function Api:query(query, parameters)
    local bf = assert(io.open(body_path, "w"))
    bf:write(json.encode({ query = query, variables = parameters }))
    bf:close()
    local p = io.popen("curl -s -m 30 -w '\\n%{http_code}' -X POST https://api.hardcover.app/v1/graphql "
      .. "-H @" .. headers_path .. " --data-binary @" .. body_path)
    local raw = p:read("*a")
    p:close()
    local content, code = raw:match("^(.*)\n(%d+)$")
    local op = query:match("(%a+)%s*%(") or query:match("{%s*(%a+)") or "?"
    handle.requests = handle.requests + 1
    handle.bytes = handle.bytes + #(content or "")
    log:write(string.format("%s %s %d bytes\n", code or "?", op, #(content or "")))
    if os.getenv("KO_LIVE_DEBUG") then log:write(content or "", "\n") end
    log:flush()
    if not content then return nil, { completed = false } end
    local ok, data = pcall(json.decode, content, json.decode.simple) -- nulls become nil, as in the plugin
    if not ok or type(data) ~= "table" then return nil, { status = tonumber(code) } end
    if data.data then return data.data end
    return nil, { errors = data.errors or { data.error }, status = tonumber(code) }
  end
  Api.enabled = true

  function handle.close()
    log:close()
    os.remove(headers_path)
    os.remove(body_path)
  end
  return handle
end

return LiveApi
