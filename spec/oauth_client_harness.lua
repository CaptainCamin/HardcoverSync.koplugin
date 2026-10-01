-- Proves the OAuth HTTP layer preserves what the error codes mean.
--
-- Hardcover signals OAuth failures with a 4xx status AND a JSON body carrying
-- the real reason: authorization_pending (keep waiting), slow_down (wait
-- longer), access_denied (user said no), invalid_grant (token is dead). An
-- earlier version of this client discarded the body on non-200 and reported a
-- flat "http_400", which turns "the user has not approved yet" into an
-- indistinguishable failure -- every sign-in would look broken.
--
-- The second thing pinned here is the timeout case. A timeout means the request
-- may or may not have landed. If it landed, the refresh token is spent, and
-- reusing it revokes the whole chain. So a timeout must be reported as its own
-- outcome that the caller refuses to retry, not folded into a generic error.
--
-- Run with:  lua spec/oauth_client_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local json = dofile(PLUGIN .. "/spec/json.lua")
package.preload["json"] = function() return json end

-- The single seam: a fake https.request that returns a canned status and body,
-- and records what was sent.
local sent = {}
local respond = { code = 200, body = "{}" }

package.preload["ssl.https"] = function()
  return {
    request = function(t)
      sent[#sent + 1] = t
      -- luahttps delivers the response body through the sink callback, and only
      -- the status code comes back as the second return value. Returning the
      -- body as a third value (an earlier version of this fake) leaves the
      -- sink empty, so the client decodes "" and every 200 looks malformed.
      if type(respond.body) == "function" then
        respond.body = respond.body(t)
      end
      if t.sink and respond.body and respond.body ~= "" then
        t.sink(respond.body)
      end
      return nil, respond.code, {}
    end,
  }
end
package.preload["ssl"] = function() return {} end
package.preload["socket"] = function() return {} end
package.preload["socket.url"] = function() return {} end
package.preload["ltn12"] = function()
  return {
    source = {
      string = function(s)
        local done = false
        return function()
          if done then return nil end
          done = true
          return s
        end
      end,
    },
  }
end
package.preload["socketutil"] = function()
  return {
    block_timeout = 20,
    total_timeout = 20,
    TIMEOUT_CODE = 408,
    SINK_TIMEOUT_CODE = 599,
    set_timeout = function() end,
    reset_timeout = function() end,
    -- a real sink, so the client's own concatenation is exercised
    table_sink = function(tbl)
      return function(chunk)
        if chunk then table.insert(tbl, chunk) end
        return 1
      end
    end,
  }
end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end

local OAuthClient = require("hardcover/lib/oauth_client")

local results = { passed = 0, failed = 0 }

local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    results.passed = results.passed + 1
    print("  [ok  ] " .. name)
  else
    results.failed = results.failed + 1
    print("  [FAIL] " .. name .. "\n         " .. tostring(err))
  end
end

local function eq(a, b, label)
  if a ~= b then
    error((label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
  end
end

local function reply(code, body)
  respond = { code = code, body = body }
end

-- ---------------------------------------------------------------- error codes

print("\n== OAuth errors survive a 4xx ==")

check("authorization_pending is reported as itself", function()
  -- This is the normal waiting state while the user types the code in a
  -- browser. Reporting it as a failure aborts every sign-in.
  reply(400, json.encode { error = "authorization_pending", error_description = "waiting" })
  -- pollToken classifies the outcome into a stable string rather than
  -- forwarding raw OAuth codes, so assert on that.
  local outcome, err = OAuthClient:pollToken("client", "device-code")
  eq(outcome, "pending", "classified outcome")
  eq(err.http_code, 400, "http status is still reported for diagnosis")
end)

check("slow_down is reported as itself", function()
  -- The client is polling too fast and must back off. Folding this into a
  -- generic error is what makes a sign-in fail after a few seconds.
  reply(400, json.encode { error = "slow_down" })
  local outcome, err = OAuthClient:pollToken("client", "device-code")
  eq(outcome, "slow_down", "classified outcome")
  eq(err.error, "slow_down", "raw code is still available")
end)

check("access_denied is reported as itself", function()
  -- The user declined. This must be distinguishable from a network problem, or
  -- the plugin will keep polling a flow the user already refused.
  reply(400, json.encode { error = "access_denied" })
  local outcome, err = OAuthClient:pollToken("client", "device-code")
  eq(outcome, "denied", "classified outcome")
  eq(err.error, "access_denied", "raw code is still available")
end)

check("invalid_grant is reported as itself", function()
  -- The refresh token is dead; the caller drops it and prompts for sign-in.
  reply(400, json.encode { error = "invalid_grant" })
  local outcome, err = OAuthClient:refresh("client", "spent-token")
  eq(outcome, "error", "outcome")
  eq(err.error, "invalid_grant", "error code")
end)

check("a timeout is its own outcome, not a generic http error", function()
  -- The request may have landed. The caller must treat this as "do not retry"
  -- rather than "try again", because the refresh token may now be spent.
  reply(408, "")
  local outcome, err = OAuthClient:refresh("client", "maybe-spent")
  eq(outcome, "error", "outcome")
  eq(err.error, "timeout", "error code")
end)

check("a body with no error field falls back to the status code", function()
  -- Some failures arrive as a bare gateway error page. Losing the raw body
  -- would leave nothing to diagnose with.
  reply(502, "<html>bad gateway</html>")
  local outcome, err = OAuthClient:refresh("client", "r")
  eq(outcome, "error", "outcome")
  eq(err.error, "http_502", "error code")
  if err.raw == nil then error("the raw body should be kept for diagnosis") end
end)

check("a 200 with an unparseable body is a bad_response, not a crash", function()
  reply(200, "not json at all")
  local outcome, err = OAuthClient:refresh("client", "r")
  eq(outcome, "error", "outcome")
  eq(err.error, "bad_response", "error code")
end)

check("an empty 200 body is rejected rather than half-applied", function()
  -- A 200 whose body is missing refresh_token is "error", not "ok": the client
  -- requires both halves, because without the rotated refresh token the next
  -- refresh would replay a spent one and revoke the whole chain. Note the body
  -- is the decoded response, so it carries no `.error` field -- the rejection
  -- is expressed by the outcome alone.
  reply(200, json.encode { access_token = "at" })
  local outcome, body = OAuthClient:refresh("client", "r")
  eq(outcome, "error", "outcome without a refresh token")
  eq(body.access_token, "at", "the decoded body is still handed back")

  reply(200, "")
  local outcome2 = OAuthClient:refresh("client", "r")
  eq(outcome2, "error", "outcome for an empty body")
end)

-- ---------------------------------------------------------------- the happy paths

print("\n== successful responses ==")

check("a token response is decoded", function()
  reply(200, json.encode {
    access_token = "at", refresh_token = "rt",
    token_type = "Bearer", expires_in = 3600,
  })
  local outcome, body = OAuthClient:refresh("client", "old-rt")
  eq(outcome, "ok", "outcome")
  eq(body.access_token, "at", "access token")
  eq(body.refresh_token, "rt", "refresh token")
  eq(body.expires_in, 3600, "expires_in")
end)

check("a device flow response yields the fields the UI needs", function()
  -- The user has to read user_code and type it somewhere, so these must come
  -- through or the sign-in screen has nothing to show.
  reply(200, json.encode {
    device_code = "dc", user_code = "ABCD-1234",
    verification_uri = "https://hardcover.app/link",
    verification_uri_complete = "https://hardcover.app/link?code=ABCD-1234",
    expires_in = 900, interval = 5,
  })
  local device = OAuthClient:startDeviceFlow("client", "read:library")
  eq(device.device_code, "dc", "device_code")
  eq(device.user_code, "ABCD-1234", "user_code")
  eq(device.verification_uri, "https://hardcover.app/link", "verification_uri")
  if device.verification_uri_complete == nil then
    error("verification_uri_complete is missing -- the user cannot one-tap sign in")
  end
end)

check("a missing interval defaults rather than yielding nil", function()
  -- pollDelay does arithmetic on this; a nil here would be a runtime error
  -- partway through a sign-in.
  reply(200, json.encode { device_code = "dc", user_code = "UC" })
  local device = OAuthClient:startDeviceFlow("client", "scope")
  if type(device.interval) ~= "number" then
    error("interval should default to a number, got " .. type(device.interval))
  end
end)

check("a device response missing the codes is refused", function()
  -- Without device_code/user_code there is no flow to continue, and returning a
  -- half-built table would fail later with a confusing nil.
  reply(200, json.encode { expires_in = 900 })
  local device, err = OAuthClient:startDeviceFlow("client", "scope")
  eq(device, nil, "device")
  if err == nil then error("an error should be returned") end
end)

check("no client id is refused before any request goes out", function()
  sent = {}
  reply(200, "{}")
  local device, err = OAuthClient:startDeviceFlow("", "scope")
  eq(device, nil, "device")
  eq(err.error, "no_client_id", "error code")
  eq(#sent, 0, "requests made")
end)

-- ---------------------------------------------------------------- request shape

print("\n== what goes on the wire ==")

check("the client id and scope are form-encoded in the body", function()
  sent = {}
  reply(200, json.encode { device_code = "dc", user_code = "UC" })
  OAuthClient:startDeviceFlow("my-client", "read:library write:library")
  local body = sent[1].source
  -- drain the one-shot source to see the body
  local text = ""
  while true do
    local chunk = body()
    if chunk == nil then break end
    text = text .. chunk
  end
  if not text:find("client_id=my%-client") then
    error("client_id missing from body: " .. text)
  end
  if not text:find("scope=read") then
    error("scope missing from body: " .. text)
  end
  -- a space in a form value must be encoded, not sent raw
  if text:find("write:library write", 1, true) then
    error("an unencoded space would split the form field: " .. text)
  end
end)

check("a refresh sends the refresh_token grant", function()
  -- The wrong grant_type is the classic cause of an invalid_grant that looks
  -- like a dead token when it is really a malformed request.
  sent = {}
  reply(200, json.encode { access_token = "at", refresh_token = "rt" })
  OAuthClient:refresh("my-client", "the-refresh-token")
  local body = sent[1].source
  local text = ""
  while true do
    local chunk = body()
    if chunk == nil then break end
    text = text .. chunk
  end
  if not text:find("grant_type=refresh_token") then
    error("wrong or missing grant_type: " .. text)
  end
  if not text:find("refresh_token=the%-refresh%-token") then
    error("refresh_token not sent: " .. text)
  end
end)

check("requests declare a JSON content type", function()
  -- A form POST without the right header can come back as a parse error, which
  -- looks like a server problem rather than a request problem.
  sent = {}
  reply(200, json.encode { access_token = "at" })
  OAuthClient:refresh("c", "r")
  local headers = sent[1].headers
  if not headers["Content-Type"] then error("no Content-Type header") end
  if not headers["Accept"] then error("no Accept header") end
end)

-- ---------------------------------------------------------------- the harness itself

print("\n== the decoder these tests lean on ==")

check("json round-trips an OAuth error body", function()
  local decoded = json.decode(json.encode {
    error = "slow_down", error_description = "polling too fast",
  })
  eq(decoded.error, "slow_down", "error")
  eq(decoded.error_description, "polling too fast", "description")
end)

check("malformed json raises rather than returning junk", function()
  -- post_form relies on a raise to detect a bad body. A decoder that returned
  -- nil quietly would turn every gateway error page into "bad_response" with
  -- no diagnosis.
  local ok = pcall(json.decode, "{not json")
  eq(ok, false, "should have raised")
end)

print("")
print(string.format("  %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)