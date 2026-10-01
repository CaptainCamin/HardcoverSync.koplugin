-- Pure logic for the Hardcover OAuth device authorization grant.
--
-- No KOReader requires and no network calls: this module owns the token
-- lifecycle rules, which are the part that is easy to get subtly wrong and
-- expensive when you do. The HTTP calls live in oauth_client.lua.
--
-- Why this is separated and fussy:
--  * Access tokens last 1 week, refresh tokens 6 months.
--  * A refresh token ROTATES on every use -- the one you spend stops working.
--  * If a spent refresh token is ever presented twice, Hardcover treats it as a
--    replay and revokes the entire chain, forcing the user through consent
--    again. So a refresh must never be retried, and the replacement token must
--    be persisted before anything else can run.

local OAuth = {}

local ACCESS_TOKEN_PREFIX = "hc_at_"
local REFRESH_TOKEN_PREFIX = "hc_rt_"

-- conservative skew: treat a token as expired slightly early so a request is
-- not sent with a token that dies in flight
local EXPIRY_SKEW = 60

--
-- classify a poll response from the token endpoint
--
function OAuth.classifyPoll(body, http_ok)
  body = body or {}

  if http_ok and body.access_token then
    return "success"
  end

  local err = body.error

  if err == "authorization_pending" then
    return "pending"
  elseif err == "slow_down" then
    -- keep polling, but back off as RFC 8628 requires
    return "slow_down"
  elseif err == "access_denied" then
    return "denied"
  elseif err == "expired_token" then
    return "expired"
  end

  -- anything else (invalid_client, bad scope, server trouble) is terminal:
  -- polling again would just burn the user's battery on the same answer
  return "error"
end

--
-- how long to wait before the next poll, honouring slow_down
--
function OAuth.nextPollDelay(interval, response)
  interval = tonumber(interval) or 5
  if response == "slow_down" then
    -- RFC 8628: increase the interval by 5s each time
    return interval + 5
  end
  return interval
end

--
-- has the device code run out of time?
--
function OAuth.isExpired(now, expires_in, started_at)
  started_at = started_at or now
  expires_in = tonumber(expires_in) or 900
  return (now - started_at) >= expires_in
end

--
-- Build the token set to persist from a successful token response.
-- Returns nil when the response is unusable.
--
function OAuth.tokenSetFrom(body, now)
  body = body or {}

  local access_token = body.access_token
  local refresh_token = body.refresh_token
  if not access_token or not refresh_token then
    return nil
  end

  -- access tokens last a week unless told otherwise
  local expires_in = tonumber(body.expires_in) or (7 * 24 * 60 * 60)

  return {
    access_token = access_token,
    refresh_token = refresh_token,
    token_type = body.token_type or "Bearer",
    -- absolute expiry, computed once, so no clock skew maths at read time
    expires_at = (now or os.time()) + expires_in,
    obtained_at = now or os.time(),
  }
end

--
-- Is an access token present and still usable?
--
function OAuth.isAccessValid(token_set, now)
  if not token_set or not token_set.access_token then
    return false
  end

  if not token_set.expires_at then
    return false
  end

  return (now or os.time()) < (token_set.expires_at - EXPIRY_SKEW)
end

--
-- Is there anything to refresh with?
--
function OAuth.canRefresh(token_set)
  return token_set ~= nil and token_set.refresh_token ~= nil and token_set.refresh_token ~= ""
end

--
-- Decide what should happen before an API call.
--
function OAuth.preflight(token_set, now)
  if not OAuth.canRefresh(token_set) then
    return "authenticate"
  end

  if OAuth.isAccessValid(token_set, now) then
    return "use"
  end

  return "refresh"
end

--
-- Fold a successful refresh into an existing token set, preserving fields we
-- do not receive back (obtained_at).
--
function OAuth.applyRefresh(previous, body, now)
  local fresh = OAuth.tokenSetFrom(body, now)
  if not fresh then
    return previous
  end

  if previous and previous.obtained_at then
    fresh.obtained_at = previous.obtained_at
  end

  return fresh
end

--
-- Should the stored token set be written back to disk?
--
-- Deliberately conservative: we persist whenever a NEW refresh token is
-- present, because losing it means the user redoes consent. The caller must
-- never write the same refresh token twice.
--
function OAuth.shouldPersist(new_set, stored_set)
  if not new_set then
    return false
  end

  -- no previous token, or the refresh token changed: definitely persist
  if not stored_set or stored_set.refresh_token ~= new_set.refresh_token then
    return true
  end

  -- same refresh token but a later expiry (non-rotating server): worth saving
  -- so we do not re-login sooner than necessary
  return (new_set.expires_at or 0) > (stored_set.expires_at or 0)
end

--
-- Guard against ever re-presenting a refresh token.
--
-- The client sets `refresh_in_flight` before the request and clears it only on
-- a definitive answer. While it is set, no second refresh may start: a retry
-- after a network timeout is exactly the replay that revokes the chain.
--
function OAuth.RefreshGuard()
  return {
    in_flight = false,
    -- result of the last completed refresh, if any
    last_error = nil,
  }
end

function OAuth.canStartRefresh(guard)
  if guard == nil or guard.in_flight then
    return false
  end

  -- After an unknown outcome the refresh token may already be spent, so a
  -- second attempt is exactly the replay that revokes the chain. Only a fresh
  -- sign in (which replaces the guard) clears this.
  return guard.last_error ~= "unknown"
end

function OAuth.beginRefresh(guard)
  guard.in_flight = true
  guard.last_error = nil
  return guard
end

--
-- Finish a refresh attempt. `outcome` is one of:
--   "ok"    -- tokens were received and should be persisted
--   "error" -- definitive failure; the old refresh token is still valid
--   "unknown" -- we do not know if the request landed. The refresh token MUST
--                be treated as spent: do not retry, do not reuse.
--
function OAuth.endRefresh(guard, outcome)
  guard.in_flight = false
  guard.last_error = outcome
  return guard
end

--
-- After an "unknown" refresh outcome the old refresh token is suspect. This
-- reports whether the user must re-authenticate rather than risk a replay.
--
function OAuth.needsReauth(guard, token_set)
  if guard and guard.last_error == "unknown" then
    return true
  end

  if not OAuth.canRefresh(token_set) then
    return true
  end

  if token_set and token_set.refresh_revoked then
    return true
  end

  return false
end

--
-- Recognise token shapes, for surfacing a helpful message when a token is
-- pasted into the config that belongs to the other flow.
--
function OAuth.tokenKind(token)
  if not token or token == "" then
    return nil
  end

  if string.sub(token, 1, #ACCESS_TOKEN_PREFIX) == ACCESS_TOKEN_PREFIX then
    return "access"
  end

  if string.sub(token, 1, #REFRESH_TOKEN_PREFIX) == REFRESH_TOKEN_PREFIX then
    return "refresh"
  end

  return "pat"
end

return OAuth