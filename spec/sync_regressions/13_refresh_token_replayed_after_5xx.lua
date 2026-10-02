-- BUG: a refresh token is presented again after a 5xx / garbled refresh reply.
--
-- Auth:refresh (hardcover/lib/auth.lua) marks the outcome "unknown" -- and so
-- blocks every further refresh until a fresh sign-in -- only for
-- error == "timeout". Anything else the client reports, e.g. "http_503",
-- "http_502" or "bad_response" (OAuthClient post_form,
-- hardcover/lib/oauth_client.lua), is recorded as a definitive "error", which
-- leaves canStartRefresh() true. But a 502/503/504 or an unparsable 200 from a
-- gateway does not prove the token endpoint did not process the request: the
-- single-use refresh token may already be rotated away. The next call re-presents
-- it, and per the module's own header that replay revokes the whole token chain.
--
-- A queue replay makes this likely: every API call of every entry asks Auth for
-- a token, and one entry makes up to three calls (findUserBook, me,
-- updateUserBook/updatePage), so one flush of two entries presents the same
-- refresh token six times.
--
-- Expected: an ambiguous refresh failure is treated like a timeout ("unknown":
-- no further refresh attempts with that token), or at minimum at most one
-- attempt per flush.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
table.unpack = table.unpack or unpack
KB.stub_koreader()
package.preload["luasettings"] = function() return { open = function() return {} end } end

package.preload["socket.http"] = function()
  return {
    request = function(req)
      req.sink('{"error":"Unable to verify token"}')
      return 1, 401, {}, "Unauthorized" -- nothing is ever accepted: no valid token exists
    end,
  }
end

local Api = require("hardcover/lib/hardcover_api")
local Auth = require("hardcover/lib/auth")

local function store()
  local s = {}
  return { store = s, readSetting = function(_, k) return s[k] end,
    saveSetting = function(_, k, v) s[k] = v end, flush = function() end }
end

print("\n== ambiguous refresh failures during a replay ==")

for _, case in ipairs({ "http_503", "http_502", "bad_response" }) do
  KB.check("refresh error '" .. case .. "' does not re-present the refresh token on every call", function()
    local refreshes = 0
    local settings = store()
    settings.store.access_token = "hc_at_old"
    settings.store.refresh_token = "hc_rt_1"
    settings.store.expires_at = os.time() - 3600
    local client = { refresh = function() refreshes = refreshes + 1 return "error", { error = case } end }
    Api.auth = Auth:new { config = { client_id = "c" }, settings = settings, client = client }

    local q = KB.newQueue()
    q:enqueuePage("/books/a.epub", { mapped_page = 1, book_id = 7, edition_id = 3 })
    q:enqueuePage("/books/b.epub", { mapped_page = 2, book_id = 8, edition_id = 3 })
    q:flush(Api, { user_id = 1 })
    KB.eq(refreshes <= 1, true, "times the same refresh token was presented in one flush: " .. refreshes)
  end)
end

KB.finish("ambiguous refresh failures must not lead to refresh-token replays")
