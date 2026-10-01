-- HTTP for the OAuth device authorization grant.
--
-- Thin wrapper over socket.http: form-encode a POST, parse the JSON reply.
-- All the decisions live in oauth.lua; this file only moves bytes.
--
-- Device grant needs no PKCE here -- the device flow exchanges a device_code
-- directly, so no SHA-256 or base64url is required on the device.

local json = require("json")
local ltn12 = require("ltn12")
local logger = require("logger")
local socketutil = require("socketutil")

local https = require("ssl.https")

local OAuth = require("hardcover/lib/oauth")

-- Overridable so the HTTP layer can be pointed at a local fake server in
-- tests. Uses a plain Lua global rather than os.getenv, which LuaJIT's 5.1
-- dialect does not provide.
local base_url = rawget(_G, "HARDCOVER_OAUTH_BASE") or "https://api.hardcover.app"

local TOKEN_ENDPOINT = base_url .. "/oauth2/token"
local DEVICE_ENDPOINT = base_url .. "/oauth2/device"
local REVOKE_ENDPOINT = base_url .. "/oauth2/revoke"
local DISCOVERY_ENDPOINT = base_url .. "/.well-known/oauth-authorization-server"

local DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"

local OAuthClient = {}

--
-- Percent-encode for application/x-www-form-urlencoded.
-- socketutil has no urlencode, and socket.url is not guaranteed to expose one,
-- so do it here. Unreserved characters pass through; spaces become '+'.
--
local function urlencode(value)
  value = tostring(value)
  local encoded = value:gsub("([^%w%-%._~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
  return (encoded:gsub("%+", "%%20"))
end

--
-- form-encode a table of key/value pairs
--
local function form_encode(params)
  local parts = {}
  for key, value in pairs(params) do
    if value ~= nil then
      table.insert(parts, urlencode(key) .. "=" .. urlencode(value))
    end
  end
  return table.concat(parts, "&")
end

--
-- POST form-encoded data and return (http_ok, decoded_body)
--
local function post_form(url, params, timeout)
  local body = form_encode(params)
  local sink = {}

  local previous_block, previous_total = socketutil.block_timeout, socketutil.total_timeout
  socketutil:set_timeout(timeout or 20, timeout or 20)

  local _, code = https.request {
    url = url,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/x-www-form-urlencoded",
      ["Accept"] = "application/json",
    },
    source = ltn12.source.string(body),
    sink = socketutil.table_sink(sink),
  }

  socketutil:set_timeout(previous_block, previous_total)

  local content = table.concat(sink)

  -- OAuth signals its errors in the JSON body with a 4xx status, so the body
  -- must be decoded even on failure: `authorization_pending` and
  -- `invalid_grant` arrive this way and carry the whole meaning.
  local decoded_ok, decoded = pcall(json.decode, content, json.decode.simple)
  if decoded_ok and type(decoded) == "table" then
    decoded = decoded
  else
    decoded = nil
  end

  if code ~= 200 and code ~= 201 then
    -- a timeout is the dangerous case: we do not know whether the request
    -- landed. The caller decides what that means.
    local is_timeout = (code == socketutil.TIMEOUT_CODE or code == socketutil.SINK_TIMEOUT_CODE)

    local err = { http_code = code, raw = content }

    if is_timeout then
      err.error = "timeout"
    elseif decoded and decoded.error then
      -- keep the OAuth error code (authorization_pending, slow_down, ...)
      err.error = decoded.error
      err.description = decoded.error_description
    else
      err.error = "http_" .. tostring(code)
    end

    if decoded then
      err.body = decoded
    end

    return false, err
  end

  local ok = decoded_ok
  if not ok or not decoded then
    return false, { error = "bad_response", raw = content }
  end

  return true, decoded
end

--
-- Step 1 of the device flow: ask for a device code.
-- Returns a table with device_code, user_code, verification_uri,
-- verification_uri_complete, expires_in, interval.
--
function OAuthClient:startDeviceFlow(client_id, scope)
  if not client_id or client_id == "" then
    return nil, { error = "no_client_id" }
  end

  local ok, body = post_form(DEVICE_ENDPOINT, {
    client_id = client_id,
    scope = scope,
  })

  if not ok then
    return nil, body
  end

  if not body.device_code or not body.user_code then
    return nil, body
  end

  return {
    device_code = body.device_code,
    user_code = body.user_code,
    verification_uri = body.verification_uri,
    verification_uri_complete = body.verification_uri_complete,
    expires_in = body.expires_in,
    interval = body.interval or 5,
  }
end

--
-- One poll of the token endpoint. Classifies the outcome via oauth.lua so the
-- caller gets a stable string rather than raw OAuth error codes.
--
function OAuthClient:pollToken(client_id, device_code)
  local ok, body = post_form(TOKEN_ENDPOINT, {
    grant_type = DEVICE_GRANT,
    device_code = device_code,
    client_id = client_id,
  })

  local outcome = OAuth.classifyPoll(body, ok)

  if outcome == "success" then
    return outcome, body
  end

  return outcome, body
end

--
-- Exchange a refresh token for a new pair.
-- Returns (outcome, body) where outcome is "ok" or "error".
--
function OAuthClient:refresh(client_id, refresh_token)
  local ok, body = post_form(TOKEN_ENDPOINT, {
    grant_type = "refresh_token",
    client_id = client_id,
    refresh_token = refresh_token,
  })

  if ok and body.access_token and body.refresh_token then
    return "ok", body
  end

  return "error", body
end

--
-- Revoke on sign-out. Local deletion alone leaves a session showing as active
-- on the user's Authorized Apps page.
--
function OAuthClient:revoke(client_id, token, token_type_hint)
  local ok, body = post_form(REVOKE_ENDPOINT, {
    token = token,
    token_type_hint = token_type_hint,
    client_id = client_id,
  })

  if ok then
    return true
  end

  -- a failed revoke is worth logging but must not block sign-out: the local
  -- tokens still have to go
  logger.warn("hardcover oauth: revoke failed", body and body.error)
  return false
end

--
-- Discovery, so endpoint URLs are not hardcoded against our will.
-- Falls back to the documented constants when discovery is unavailable.
--
function OAuthClient:discover()
  local ok, body = post_form(DISCOVERY_ENDPOINT, {}, 15)

  -- discovery is a GET in practice; a POST failure is expected and harmless
  if not ok then
    return nil
  end

  if type(body) ~= "table" then
    return nil
  end

  return body
end

return OAuthClient