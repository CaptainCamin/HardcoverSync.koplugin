-- Owns the OAuth token lifecycle for the plugin: runs the device grant,
-- persists tokens, refreshes when needed, and hands Api a Bearer token.
--
-- PAT remains supported: if hardcover_config.lua supplies a token and no OAuth
-- client id is set, the plugin keeps using it exactly as before.

local LuaSettings = require("luasettings")
local logger = require("logger")
local _ = require("gettext")

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")

local InfoMessage = require("ui/widget/infomessage")

local OAuth = require("hardcover/lib/oauth")
local OAuthClient = require("hardcover/lib/oauth_client")

-- read:catalog: book, edition and author lookups
-- read:catalog:search: title/author search
-- read:me:content: the user id we key local state on
-- read:library: shelf listings and reading progress
-- write:library: status/progress updates AND reading journal entries
--
-- There is no separate write:journal scope: requesting one fails the whole
-- authorization with `invalid_scope`. Journal writes are part of
-- write:library, and read:journal is implied by read:library.
local DEFAULT_SCOPE = "read:catalog read:catalog:search read:me:content read:library write:library"

local Auth = {}
Auth.__index = Auth

function Auth:new(o)
  o = o or {}
  setmetatable(o, self)

  o.guard = OAuth.RefreshGuard()
  o.config = o.config or require("hardcover/lib/config")
  o.client = o.client or OAuthClient

  if not o.settings then
    o.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/hardcoversync_auth.lua")
  end

  -- o, not self: self is the class table here, so self:_load() would look for
  -- settings on the class and fail
  o.tokens = o:_load()

  return o
end

--
-- persistence
--
function Auth:_load()
  local access_token = self.settings:readSetting("access_token")
  if not access_token then
    return nil
  end

  return {
    access_token = access_token,
    refresh_token = self.settings:readSetting("refresh_token"),
    token_type = self.settings:readSetting("token_type") or "Bearer",
    expires_at = self.settings:readSetting("expires_at"),
    obtained_at = self.settings:readSetting("obtained_at"),
  }
end

function Auth:_persist(tokens)
  if not OAuth.shouldPersist(tokens, self.tokens) then
    return false
  end

  -- write the refresh token FIRST: it is single-use, and if we lose it the
  -- user has to redo consent
  self.settings:saveSetting("refresh_token", tokens.refresh_token)
  self.settings:saveSetting("access_token", tokens.access_token)
  self.settings:saveSetting("token_type", tokens.token_type)
  self.settings:saveSetting("expires_at", tokens.expires_at)
  self.settings:saveSetting("obtained_at", tokens.obtained_at)
  self.settings:flush()

  self.tokens = tokens

  return true
end

--
-- Forget the stored tokens, on disk as well as in memory. Leaving them in
-- LuaSettings would mean signing out did not actually sign out.
--
function Auth:clear()
  self.settings:saveSetting("access_token", nil)
  self.settings:saveSetting("refresh_token", nil)
  self.settings:saveSetting("token_type", nil)
  self.settings:saveSetting("expires_at", nil)
  self.settings:saveSetting("obtained_at", nil)
  self.settings:flush()

  self.tokens = nil
  self.guard = OAuth.RefreshGuard()
end

--
-- which auth mode are we in?
--
function Auth:clientId()
  return self.config.client_id
end

function Auth:usingOAuth()
  return self:clientId() ~= nil and self:clientId() ~= ""
end

function Auth:usingPat()
  if self:usingOAuth() then
    return false
  end

  local token = self.config.token
  return token ~= nil and token ~= ""
end

--
-- The Bearer token to send, refreshing first if needed.
--
-- `pat_token` is the legacy static token from hardcover_config.lua, used only
-- when OAuth is not configured.
--
function Auth:accessToken(pat_token)
  if self:usingOAuth() then
    local action = OAuth.preflight(self.tokens)

    if action == "use" then
      return self.tokens.access_token
    end

    if action == "refresh" then
      local token = self:refresh()
      if token then
        return token
      end

      -- refresh failed; fall through so the caller can react
      return nil
    end

    return nil
  end

  return pat_token
end

--
-- Perform at most one refresh at a time. Never retries: a second attempt with
-- the same (now spent) refresh token would get the chain revoked.
--
function Auth:refresh()
  if not OAuth.canStartRefresh(self.guard) then
    logger.warn("hardcover oauth: refresh already in flight")
    return nil
  end

  if not OAuth.canRefresh(self.tokens) then
    return nil
  end

  OAuth.beginRefresh(self.guard)

  -- If the request throws we cannot know whether it reached the server, which
  -- is the same position as a timeout: treat the refresh token as possibly
  -- spent. Without the pcall the guard would stay "in flight" forever and no
  -- refresh could ever run again in this session.
  local called, outcome, body = pcall(self.client.refresh, self.client, self:clientId(), self.tokens.refresh_token)
  if not called then
    logger.warn("hardcover oauth: refresh raised, outcome unknown", outcome)
    OAuth.endRefresh(self.guard, "unknown")
    return nil
  end

  if outcome == "ok" then
    local fresh = OAuth.applyRefresh(self.tokens, body, os.time())
    self:_persist(fresh)
    OAuth.endRefresh(self.guard, "ok")
    return fresh.access_token
  end

  local error_code = body and body.error

  if error_code == "timeout" then
    -- The request may or may not have landed. Retrying is not safe: if it did,
    -- our refresh token is spent and reusing it revokes the chain.
    OAuth.endRefresh(self.guard, "unknown")
    logger.warn("hardcover oauth: refresh outcome unknown, not retrying")
    return nil
  end

  OAuth.endRefresh(self.guard, "error")

  if error_code == "invalid_grant" then
    -- the refresh token is definitively dead: drop it so the next call
    -- reports "needs sign in" instead of retrying a dead credential
    self:clear()
  end

  return nil
end

--
-- The server rejected our access token (401). Force a refresh on the next
-- call by treating the access token as already expired. The refresh token is
-- untouched -- it may still be perfectly good.
--
function Auth:invalidateAccessToken()
  if not self.tokens then
    return
  end

  self.tokens.expires_at = 0

  self.settings:saveSetting("expires_at", 0)
  self.settings:flush()
end

--
-- Does the user need to (re)authenticate?
--
function Auth:needsReauth()
  return OAuth.needsReauth(self.guard, self.tokens)
end

--
-- Step 1+2 of the device flow: request a code and show it to the user.
-- Returns a table describing what to display, or nil on failure.
--
function Auth:beginDeviceFlow()
  if not self:usingOAuth() then
    return nil, "no_client_id"
  end

  local device, err = self.client:startDeviceFlow(self:clientId(), self.config.scope or DEFAULT_SCOPE)
  if not device then
    logger.warn("hardcover oauth: device flow failed", err and err.error)
    return nil, err
  end

  self.device = device
  self.device_started_at = os.time()

  return device
end

--
-- Step 3: poll once. Returns outcome plus, on success, the stored token set.
--
function Auth:pollOnce()
  if not self.device then
    return "error", nil
  end

  if OAuth.isExpired(os.time(), self.device.expires_in, self.device_started_at) then
    return "expired", nil
  end

  local outcome, body = self.client:pollToken(self:clientId(), self.device.device_code)

  if outcome == "success" then
    local tokens = OAuth.tokenSetFrom(body, os.time())
    if tokens then
      self:_persist(tokens)
      -- a fresh successful flow clears any prior unknown-outcome suspicion
      self.guard = OAuth.RefreshGuard()
      self.device = nil
      return "success", tokens
    end
  end

  if outcome == "denied" or outcome == "expired" or outcome == "error" then
    self.device = nil
  end

  return outcome, nil
end

--
-- How long to wait before the next poll.
--
function Auth:pollDelay(outcome)
  return OAuth.nextPollDelay(self.device and self.device.interval or 5, outcome)
end

--
-- Sign out: revoke server-side, then drop local copies.
--
function Auth:signOut()
  local token = self.tokens and (self.tokens.refresh_token or self.tokens.access_token)

  if token and self:usingOAuth() then
    self.client:revoke(self:clientId(), token, self.tokens.refresh_token and "refresh_token" or "access_token")
  end

  self:clear()

  UIManager:show(InfoMessage:new {
    text = _("Signed out of Hardcover"),
    timeout = 2,
  })
end

--
-- Human-readable state for the settings menu.
--
function Auth:statusText()
  if self:usingOAuth() then
    if OAuth.needsReauth(self.guard, self.tokens) then
      return _("Sign in to Hardcover")
    end

    if OAuth.isAccessValid(self.tokens) then
      return _("Signed in to Hardcover")
    end

    if OAuth.canRefresh(self.tokens) then
      return _("Signed in (token expired, will refresh)")
    end

    return _("Sign in to Hardcover")
  end

  if self:usingPat() then
    return _("Using API key")
  end

  return _("Not configured")
end

return Auth