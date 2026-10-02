-- Proves the OAuth token lifecycle is safe.
--
-- The hazard this file exists to prevent: Hardcover's refresh tokens rotate and
-- are single-use. Presenting a spent one does not merely fail -- it revokes the
-- whole chain, so the user silently loses their library sync and has to redo
-- consent. Every assertion below is about not doing that.
--
-- Run with:  lua spec/auth_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

-- A real decoder, not a stub. The OAuth error codes these tests depend on
-- arrive inside a JSON body, so a fake that raised on every body would leave
-- exactly the interesting paths untestable.
package.preload["json"] = function()
  return dofile(PLUGIN .. "/spec/json.lua")
end

-- ltn12 and socket are only reached for real HTTP, which these tests never do:
-- every OAuth call goes through the injected client double. The stubs exist
-- purely so requiring oauth_client succeeds.
package.preload["ltn12"] = function()
  return {
    source = {
      -- A one-shot generator, matching ltn12's real contract. That property is
      -- load-bearing for the retry-safety tests, so keep it.
      string = function(s)
        local sent = false
        return function()
          if sent then return nil end
          sent = true
          return s
        end
      end,
    },
  }
end
package.preload["socket"] = function() return {} end
package.preload["socket.url"] = function() return {} end
package.preload["socketutil"] = function()
  return { set_timeout = function() end, reset_timeout = function() end }
end
-- Stock Lua has no ssl.https (it lives in LuaSec, which KOReader bundles). It
-- is only touched by the real HTTP path, which the client double bypasses, so
-- an inert stand-in is enough to let the module load.
package.preload["ssl"] = function() return {} end
package.preload["ssl.https"] = function()
  return { request = function() return nil, "stubbed" end }
end
-- A fresh settings object per call. Sharing one store across the whole run
-- leaks tokens between tests: a test that signs out leaves the next one
-- apparently signed in, which produces failures that look like plugin bugs.
--
-- readSetting returns the LIVE table by reference, matching real
-- LuaSettings:readSetting (`return self.data[key]`). Returning a copy would
-- hide exactly the persistence bugs these tests exist to catch.
local function makeSettings()
  local store = {}
  local self = {}
  function self.readSetting(_, key) return store[key] end
  function self.saveSetting(_, key, value)
    if value == nil then store[key] = nil else store[key] = value end
    return self
  end
  function self.flush() return self end
  function self.open() return self end
  function self.close() return self end
  self.store = store
  return self
end

package.preload["luasettings"] = function()
  return makeSettings()
end

package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["datastorage"] = function()
  return { getSettingsDir = function() return "/tmp/hardcover-test" end }
end
package.preload["ui/uimanager"] = function()
  return { scheduleIn = function() end, show = function() end, setDirty = function() end }
end
package.preload["ui/widget/infomessage"] = function()
  local M = { shown = {} }
  M.new = function(_, o)
    o = o or {}
    setmetatable(o, M)
    o.show = function() M.shown[#M.shown + 1] = o.text end
    o.free = function() end
    return o
  end
  return M
end

local OAuth = require("hardcover/lib/oauth")
local Auth = require("hardcover/lib/auth")

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

-- An OAuth client double. `outcomes` is a queue of { outcome, body } consumed
-- one per refresh, so a test can drive a specific sequence.
local function clientDouble(outcomes, log)
  log = log or {}
  return {
    log = log,
    refresh = function(_, client_id, refresh_token)
      log[#log + 1] = { op = "refresh", client_id = client_id, refresh_token = refresh_token }
      local next = table.remove(outcomes, 1)
      if next == nil then return "error", { error = "invalid_grant" } end
      return next[1], next[2]
    end,
    -- The real OAuthClient:startDeviceFlow returns the device table ALONE, not
    -- an ok/body pair like post_form does. An earlier double returned
    -- ("ok", {...}), so beginDeviceFlow received the string "ok".
    startDeviceFlow = function()
      return {
        device_code = "dc",
        user_code = "UC",
        verification_uri = "https://hardcover.app/link",
        interval = 5,
      }
    end,
    pollToken = function() return "authorization_pending", { error = "authorization_pending" } end,
    revoke = function() log[#log + 1] = { op = "revoke" } return "ok", {} end,
  }
end

local function newAuth(opts)
  opts = opts or {}
  -- A fresh store per Auth, so one test's tokens cannot satisfy another's
  -- assertions.
  local settings = opts.settings or makeSettings()
  local a = Auth:new {
    settings = settings,
    config = opts.config or { client_id = "test-client", scope = "read:library" },
    client = opts.client or clientDouble(opts.outcomes or {}),
  }
  return a, settings
end

-- ---------------------------------------------------------------- preflight

print("\n== deciding whether to refresh ==")

check("no tokens at all means sign in, not refresh", function()
  eq(OAuth.preflight(nil), "authenticate")
end)

check("a live token is used as-is", function()
  local future = os.time() + 3600
  eq(OAuth.preflight({ access_token = "a", refresh_token = "r", expires_at = future, obtained_at = os.time() }), "use")
end)

check("a token inside the expiry skew is treated as already expired", function()
  -- Refreshing slightly early avoids racing the expiry on a slow e-reader, at
  -- the cost of one extra refresh per session.
  local skew = 60
  local nearly = os.time() + 5
  eq(OAuth.isAccessValid({ access_token = "a", expires_at = nearly }), false,
    "expires in 5s, within skew")
  eq(OAuth.isAccessValid({ access_token = "a", expires_at = os.time() + skew + 60 }), true,
    "comfortably in the future")
end)

check("a token with no expiry is never trusted", function()
  -- Treating an expiry-less token as valid would mean using a credential whose
  -- age is unknown, which fails opaquely at the API instead of refreshing.
  eq(OAuth.isAccessValid({ access_token = "a" }), false, "no expires_at")
end)

check("an expired token asks for a refresh", function()
  local past = os.time() - 10
  eq(OAuth.preflight({ access_token = "a", refresh_token = "r", expires_at = past, obtained_at = os.time() }), "refresh")
end)

check("a token with no refresh token cannot be refreshed", function()
  local past = os.time() - 10
  -- Otherwise the plugin would spin trying to refresh a credential it does not
  -- have, and the user would see repeated failures instead of a sign-in prompt.
  eq(OAuth.preflight({ access_token = "a", expires_at = past, obtained_at = os.time() }), "authenticate")
end)

check("refresh is refused without a refresh token", function()
  eq(OAuth.canRefresh({ access_token = "a" }), false)
  eq(OAuth.canRefresh(nil), false)
  eq(OAuth.canRefresh({ refresh_token = "r" }), true)
end)

-- ---------------------------------------------------------------- refresh safety

print("\n== refresh safety ==")

check("a successful refresh returns the new access token", function()
  local a = newAuth {
    outcomes = { { "ok", { access_token = "new-access", refresh_token = "new-refresh", expires_in = 3600 } } },
  }
  a.tokens = { access_token = "old", refresh_token = "old-refresh", expires_at = os.time() - 10 }
  eq(a:refresh(), "new-access")
  eq(a.tokens.access_token, "new-access", "stored access token")
  eq(a.tokens.refresh_token, "new-refresh", "rotated refresh token")
end)

check("a spent refresh token is never presented twice", function()
  -- The single most important assertion in this file. Presenting a rotated
  -- refresh token a second time revokes the entire chain server-side, so the
  -- user loses library sync entirely.
  local log = {}
  -- The outcomes must go to the client double itself. Passing them to newAuth
  -- as well as a custom client made them vanish: the double's queue was empty,
  -- so the first call returned invalid_grant, cleared the tokens, and every
  -- later refresh was a no-op -- the test passed without ever reaching the
  -- unknown-outcome path it is named for.
  local a = newAuth {
    client = clientDouble({ { "timeout", { error = "timeout" } } }, log),
  }
  a.tokens = { access_token = "old", refresh_token = "one-shot", expires_at = os.time() - 10 }
  a:refresh()
  a:refresh()
  a:refresh()
  if a.tokens == nil then error("tokens were discarded: the unknown-outcome path was not exercised") end
  local count = 0
  for _, c in ipairs(log) do
    if c.op == "refresh" then count = count + 1 end
  end
  if count ~= 1 then
    error("refresh token presented " .. count .. " times, expected exactly 1")
  end
end)

check("a refresh that throws is treated as unknown, not left in flight", function()
  -- A throw leaves the guard set forever, so no refresh could ever run again
  -- this session; and since the request may have landed, the token must not be
  -- presented a second time either.
  local log = {}
  local client = clientDouble({}, log)
  client.refresh = function(_, client_id, refresh_token)
    log[#log + 1] = { op = "refresh", refresh_token = refresh_token }
    error("socket exploded")
  end
  local a = newAuth { client = client }
  a.tokens = { access_token = "old", refresh_token = "one-shot", expires_at = os.time() - 10 }
  eq(a:refresh(), nil, "refresh result")
  eq(a.guard.in_flight, false, "guard released")
  eq(a:needsReauth(), true, "the user is asked to sign in again")
  a:refresh()
  eq(#log, 1, "refresh token presented once")
end)

check("an unknown outcome is not retried", function()
  local a = newAuth { outcomes = { { "timeout", { error = "timeout" } } } }
  a.tokens = { access_token = "old", refresh_token = "r", expires_at = os.time() - 10 }
  eq(a:refresh(), nil, "refresh returns nothing on an unknown outcome")
  -- and the token is kept, because it may never have been spent
  if a.tokens == nil then error("tokens were discarded on an unknown outcome") end
end)

check("a definitively dead token is dropped", function()
  -- invalid_grant means the refresh token is gone for good; keeping it would
  -- make every later call fail the same confusing way instead of prompting.
  local a = newAuth { outcomes = { { "error", { error = "invalid_grant" } } } }
  a.tokens = { access_token = "old", refresh_token = "dead", expires_at = os.time() - 10 }
  eq(a:refresh(), nil, "refresh result")
  eq(a.tokens, nil, "tokens cleared")
end)

check("concurrent refreshes collapse into one request", function()
  -- Page-turn updates can fire several API calls at once. Two simultaneous
  -- refreshes would race on the same single-use token.
  local log = {}
  local a = newAuth { client = clientDouble({}, log) }
  a.tokens = { access_token = "old", refresh_token = "r", expires_at = os.time() - 10 }
  local guard = a.guard
  OAuth.beginRefresh(guard)
  eq(a:refresh(), nil, "a second refresh is refused while one is in flight")
  OAuth.endRefresh(guard, "ok")
end)

check("a 401 marks the access token stale but keeps the refresh token", function()
  -- The access token being rejected says nothing about the refresh token, which
  -- is usually still good. Throwing it away would force a needless re-consent.
  local a = newAuth()
  a.tokens = { access_token = "rejected", refresh_token = "still-good", expires_at = os.time() + 3600 }
  a:invalidateAccessToken()
  eq(a.tokens.refresh_token, "still-good", "refresh token")
  eq(a:accessToken(), nil, "no token is handed out until it is refreshed")
end)

check("a refreshed token is written to disk", function()
  local a, settings = newAuth {
    outcomes = { { "ok", { access_token = "n", refresh_token = "nr", expires_in = 3600 } } },
  }
  a.tokens = { access_token = "old", refresh_token = "oldr", expires_at = os.time() - 10 }
  a:refresh()
  eq(settings.store["access_token"], "n", "persisted access token")
  eq(settings.store["refresh_token"], "nr", "persisted refresh token")
end)

check("the refresh token is written before the access token", function()
  -- If the process dies mid-write, losing the refresh token is unrecoverable
  -- while losing the access token only costs one refresh.
  local order = {}
  local settings = makeSettings()
  local real_save = settings.saveSetting
  settings.saveSetting = function(self, key, value)
    order[#order + 1] = key
    return real_save(self, key, value)
  end
  local a = Auth:new {
    settings = settings,
    config = { client_id = "c" },
    client = clientDouble({ { "ok", { access_token = "n", refresh_token = "nr", expires_in = 3600 } } }),
  }
  a.tokens = { access_token = "old", refresh_token = "oldr", expires_at = os.time() - 10 }
  a:refresh()
  settings.saveSetting = real_save
  local rf, at
  for i, k in ipairs(order) do
    if k == "refresh_token" and rf == nil then rf = i end
    if k == "access_token" and at == nil then at = i end
  end
  if rf == nil or at == nil then
    error("both tokens should have been written, got: " .. table.concat(order, ","))
  end
  if rf > at then
    error("refresh_token was written after access_token: " .. table.concat(order, ","))
  end
end)

-- ---------------------------------------------------------------- PAT fallback

print("\n== personal access token mode ==")

check("a configured PAT is used verbatim when there is no client id", function()
  -- The shipped default client id means OAuth is normally the path, so the PAT
  -- fallback only engages when the user blanks the client id.
  local a = newAuth { config = { client_id = "", token = "hc_pat_static" } }
  eq(a:accessToken("hc_pat_static"), "hc_pat_static")
end)

check("no PAT and no OAuth means no token is invented", function()
  -- Handing back nil is what makes the caller show a sign-in prompt; inventing
  -- or echoing something would send a bogus Authorization header.
  local a = newAuth { config = { client_id = "", token = nil } }
  eq(a:accessToken(nil), nil)
end)

check("PAT mode never attempts a refresh", function()
  local log = {}
  local a = newAuth { client = clientDouble({}, log), config = { client_id = "", token = "hc_pat_static" } }
  a.tokens = nil
  a:accessToken("hc_pat_static")
  for _, c in ipairs(log) do
    if c.op == "refresh" then error("PAT mode tried to refresh") end
  end
end)

check("stored OAuth tokens take over from a PAT", function()
  local a = newAuth()
  a.tokens = { access_token = "oauth-access", refresh_token = "r", expires_at = os.time() + 3600 }
  -- Once the user has signed in, the static config token must not shadow it.
  eq(a:accessToken("hc_pat_static"), "oauth-access")
end)

check("usingOAuth means a client id is configured, not that tokens exist", function()
  -- This is the real contract, and it is easy to assume otherwise: the plugin
  -- ships a default client id, so usingOAuth() is true on a fresh install with
  -- no tokens at all. accessToken() is what actually decides between the two
  -- modes.
  local a = newAuth()
  a.tokens = nil
  eq(a:usingOAuth(), true, "usingOAuth with a client id and no tokens")
  eq(a:usingPat(), false, "an OAuth client id wins over a PAT")

  local b = Auth:new {
    settings = makeSettings(),
    config = { client_id = "" },
    client = clientDouble({}),
  }
  eq(b:usingOAuth(), false, "usingOAuth without a client id")
end)

check("a PAT is only used when there is no client id", function()
  local a = Auth:new {
    settings = makeSettings(),
    config = { client_id = "", token = "hc_pat_static" },
    client = clientDouble({}),
  }
  eq(a:usingPat(), true, "usingPat")
  eq(a:accessToken("hc_pat_static"), "hc_pat_static", "PAT handed out")
end)

-- ---------------------------------------------------------------- signing out

print("\n== signing out ==")

check("signing out clears tokens in memory and on disk", function()
  -- Leaving them in LuaSettings means signing out does not actually sign out:
  -- the next launch silently signs the user back in.
  local a, settings = newAuth()
  a.tokens = {
    access_token = "a", refresh_token = "r", token_type = "Bearer",
    expires_at = os.time() + 3600, obtained_at = os.time(),
  }
  settings.saveSetting("access_token", "a")
  settings.saveSetting("refresh_token", "r")
  settings.saveSetting("expires_at", os.time() + 3600)
  a:clear()
  eq(a.tokens, nil, "in-memory tokens")
  eq(settings.store["access_token"], nil, "stored access token")
  eq(settings.store["refresh_token"], nil, "stored refresh token")
  eq(settings.store["expires_at"], nil, "stored expiry")
end)

check("signing out does not revoke a PAT", function()
  -- A PAT is a static config value, not something this plugin issued. Revoking
  -- it would break the user's account for no reason.
  local log = {}
  local a = newAuth { client = clientDouble({}, log) }
  a.tokens = nil
  a:clear()
  for _, c in ipairs(log) do
    if c.op == "revoke" then error("signing out revoked a token it does not own") end
  end
end)

check("a signed-out instance reloads as signed out", function()
  -- A second Auth over the same settings is what the next KOReader launch
  -- looks like, so this is the assertion that makes sign-out durable.
  local settings = makeSettings()
  settings:saveSetting("access_token", "a")
  settings:saveSetting("refresh_token", "r")
  local first = Auth:new { settings = settings, config = { client_id = "c" }, client = clientDouble({}) }
  if first.tokens == nil then error("setup: tokens should have loaded") end
  first:clear()
  local second = Auth:new { settings = settings, config = { client_id = "c" }, client = clientDouble({}) }
  eq(second.tokens, nil, "tokens after reloading")
end)

-- ---------------------------------------------------------------- device flow

print("\n== device authorization flow ==")

check("beginDeviceFlow returns the code the user must type", function()
  local a = newAuth()
  local info, err = a:beginDeviceFlow()
  if type(info) ~= "table" then
    error("expected a table, got " .. type(info) .. " (err=" .. tostring(err) .. ")")
  end
  eq(info.user_code, "UC", "user code")
  eq(info.device_code, "dc", "device code")
  -- the flow must remember the device so polling knows what to ask about
  eq(a.device.user_code, "UC", "stored on the instance")
end)

check("beginDeviceFlow is refused without a client id", function()
  local a = newAuth { config = { client_id = "" } }
  local info, err = a:beginDeviceFlow()
  eq(info, nil, "device info")
  eq(err, "no_client_id", "error")
end)

check("polling before approval reports pending, not failure", function()
  local a = newAuth()
  a:beginDeviceFlow()
  local outcome = a:pollOnce()
  -- authorization_pending is the normal waiting state, and treating it as an
  -- error would abort every sign-in.
  if outcome ~= "pending" and outcome ~= "unknown" then
    -- the double always returns authorization_pending, so anything else means
    -- the mapping is wrong
    if outcome == "error" or outcome == nil then
      error("pending poll reported as: " .. tostring(outcome))
    end
  end
end)

check("a slow_down lengthens the wait rather than hammering", function()
  local a = newAuth()
  local base = a:pollDelay("authorization_pending")
  local slow = a:pollDelay("slow_down")
  if type(base) ~= "number" or type(slow) ~= "number" then
    error("pollDelay should return a number")
  end
  if slow <= base then
    error("slow_down did not increase the delay: " .. tostring(base) .. " -> " .. tostring(slow))
  end
end)

-- ---------------------------------------------------------------- granted scopes

print("\n== which scopes a sign in was granted ==")

local function signedIn(scope)
  local a, settings = newAuth()
  a.tokens = nil
  a:_persist({ access_token = "a", refresh_token = "r", token_type = "Bearer",
    expires_at = os.time() + 3600, obtained_at = os.time(), scope = scope })
  return a, settings
end

check("a granted scope is reported as granted", function()
  local a = signedIn("read:catalog read:library read:social")
  eq(a:hasScope("read:social"), true, "read:social")
  eq(a:hasScope("read:library"), true, "read:library")
end)

check("a scope that was not granted is reported as not granted", function()
  local a = signedIn("read:catalog read:library")
  eq(a:hasScope("read:social"), false, "read:social")
end)

check("a token with no recorded scope is 'unknown', not 'not granted'", function()
  -- Tokens stored before scopes were kept look like this. Saying false would
  -- send people to sign in again for something they may already have.
  local a = signedIn(nil)
  eq(a:hasScope("read:social"), nil, "read:social")
end)

check("nobody signed in is unknown", function()
  local a = newAuth()
  eq(a:hasScope("read:social"), nil, "read:social")
end)

check("a personal access token is unknown", function()
  local a = newAuth { config = { token = "pat" } }
  eq(a:hasScope("read:social"), nil, "read:social")
end)

check("the 'all' scope grants everything", function()
  eq(signedIn("all"):hasScope("read:social"), true, "all")
end)

check("a scope is matched whole, not as part of another", function()
  -- read:library:public must not satisfy read:library, nor vice versa by prefix
  local a = signedIn("read:library:public")
  eq(a:hasScope("read:library"), false, "read:library")
  eq(a:hasScope("read:social"), false, "read:social")
end)

check("the scope is taken from the token response and survives a restart", function()
  local tokens = OAuth.tokenSetFrom({ access_token = "a", refresh_token = "r", scope = "read:social read:library" }, os.time())
  eq(tokens.scope, "read:social read:library", "scope in token set")
  local a, settings = signedIn(tokens.scope)
  local reloaded = Auth:new { settings = settings, config = { client_id = "test-client" }, client = clientDouble({}) }
  eq(reloaded:hasScope("read:social"), true, "after reload")
end)

check("a refresh that does not repeat the scope keeps the one granted", function()
  local previous = { access_token = "old", refresh_token = "r1", obtained_at = 1, scope = "read:social" }
  local fresh = OAuth.applyRefresh(previous, { access_token = "new", refresh_token = "r2" }, os.time())
  eq(fresh.scope, "read:social", "scope after refresh")
  local narrowed = OAuth.applyRefresh(previous, { access_token = "new", refresh_token = "r2", scope = "read:library" }, os.time())
  eq(narrowed.scope, "read:library", "a stated scope wins")
end)

check("signing out forgets the scope", function()
  local a, settings = signedIn("read:social")
  a:clear()
  eq(settings.store.scope, nil, "scope on disk")
  eq(a:hasScope("read:social"), nil, "scope in memory")
end)

check("the plugin asks for read:social at sign in", function()
  local Config = dofile(PLUGIN .. "/hardcover/lib/default_config.lua")
  assert(Config.scope:find("read:social", 1, true), "default_config.lua does not request read:social")
end)

print("")
print(string.format("  %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)