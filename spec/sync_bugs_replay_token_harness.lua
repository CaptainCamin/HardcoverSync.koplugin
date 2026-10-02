-- Offline replay with an expired / rotating OAuth token.
--
-- The queue is replayed through the real HardcoverApi and the real Auth, with
-- only the HTTP boundary and the OAuth client faked. What matters here:
--   * an access token that expired while offline is refreshed ONCE for the whole
--     replay, not once per queued book (refresh tokens are single-use);
--   * every request after the refresh carries the NEW access token;
--   * a refresh whose outcome is unknown (timeout) is never retried by later
--     entries or later flushes (a replayed refresh token revokes the chain), and
--     nothing is lost from the queue;
--   * a 401 marks the token expired so the next flush refreshes, and keeps the
--     queue intact.
--
-- Run with:  lua spec/sync_bugs_replay_token_harness.lua [plugin-root]

if not jit then
  -- Api:query reaches Trapper; the stub below is inline so this runs anywhere,
  -- but table.unpack differs. Keep the same guard as the other API harnesses.
  table.unpack = table.unpack or unpack
end

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_ui_stubs()
support.preload_http_stubs()
support.preload_json(PLUGIN)

local connected = true
package.preload["luasettings"] = function() return { open = function() return {} end } end
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return connected end, isOnline = function() return connected end }
end
package.preload["ui/trapper"] = function()
  return {
    wrap = function(_, fn) fn() end,
    dismissableRunInSubprocess = function(_, fn) return true, fn() end,
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

-- the fake server: records the Authorization header of every request
local requests = {}
local respond_status = 200
package.preload["socket.http"] = function()
  return {
    request = function(req)
      local body = ""
      -- the request body is a one-shot ltn12 source
      local chunk = req.source and req.source()
      body = chunk or ""
      requests[#requests + 1] = { auth = req.headers.Authorization, body = body }
      local reply
      if body:find("update_user_book_read", 1, true) then
        reply = '{"data":{"update_user_book_read":{"error":null,"user_book_read":{"id":900,"progress_pages":120,'
          .. '"user_book":{"id":500,"book_id":7,"status_id":2,"edition_id":3,"privacy_setting_id":1,"rating":null}}}}}'
      else
        reply = '{"data":{"user_books":[{"id":500,"book_id":7,"status_id":2,"edition_id":3,"privacy_setting_id":1,'
          .. '"user_book_reads":[{"id":900,"progress_pages":1,"edition_id":3,"started_at":"2026-01-01"}]}]}}'
      end
      local status = respond_status
      -- the server only honours the freshly issued token
      if req.headers.Authorization ~= "Bearer hc_at_new" then status = 401 end
      if status ~= 200 then reply = '{"error":"Unable to verify token"}' end
      req.sink(reply)
      return 1, status, {}, "OK"
    end,
  }
end

local function makeSettings()
  local store = {}
  return {
    store = store,
    readSetting = function(_, k) return store[k] end,
    saveSetting = function(_, k, v) store[k] = v end,
    flush = function() end,
  }
end

local Api = require("hardcover/lib/hardcover_api")
local Auth = require("hardcover/lib/auth")
local SyncQueue = require("hardcover/lib/sync_queue")

local r = support.reporter()
local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local function setup(client_refresh)
  requests = {}
  respond_status = 200
  connected = true
  local refreshes = {}
  local settings = makeSettings()
  settings.store.access_token = "hc_at_old"
  settings.store.refresh_token = "hc_rt_1"
  settings.store.expires_at = os.time() - 3600 -- expired while the device was offline
  local client = {
    refresh = function(_, _, refresh_token)
      refreshes[#refreshes + 1] = refresh_token
      return client_refresh(#refreshes, refresh_token)
    end,
  }
  local auth = Auth:new { config = { client_id = "client" }, settings = settings, client = client }
  Api.auth = auth
  local queue = SyncQueue:new { settings = makeSettings() }
  for i = 1, 3 do
    queue:enqueuePage("/books/" .. i .. ".epub", { mapped_page = 100 + i, book_id = 7, edition_id = 3 })
  end
  return queue, auth, refreshes, settings
end

print("\n== replaying the queue with an expired access token ==")

check("one refresh serves the whole replay and later requests use the new token", function()
  local queue, _, refreshes, settings = setup(function(n, rt)
    return "ok", { access_token = "hc_at_new", refresh_token = "hc_rt_2", expires_in = 3600 }
  end)
  assert(queue:flush(Api, { user_id = 1 }) == true, "flush should succeed")
  assert(#refreshes == 1, "refreshed " .. #refreshes .. " times, expected once")
  assert(refreshes[1] == "hc_rt_1", "refreshed with the wrong token")
  assert(settings.store.refresh_token == "hc_rt_2", "rotated refresh token was not persisted")
  for i, req in ipairs(requests) do
    assert(req.auth == "Bearer hc_at_new", "request " .. i .. " sent " .. tostring(req.auth))
  end
  assert(queue:hasPending() == false, "queue should be drained")
end)

check("a refresh with an unknown outcome is not retried by later entries or flushes", function()
  local queue, _, refreshes = setup(function() return "error", { error = "timeout" } end)
  assert(queue:flush(Api, { user_id = 1 }) == false)
  assert(queue:flush(Api, { user_id = 1 }) == false)
  assert(#refreshes == 1, "the possibly-spent refresh token was presented " .. #refreshes .. " times")
  assert(queue:pendingCount() == 3, "queued entries were lost")
end)

check("a refresh that fails outright loses nothing from the queue", function()
  -- (that such a refresh is re-attempted on every call is a separate known bug:
  -- spec/known_bugs/13_refresh_token_replayed_after_5xx.lua)
  local queue = setup(function() return "error", { error = "http_500" } end)
  assert(queue:flush(Api, { user_id = 1 }) == false)
  assert(queue:pendingCount() == 3, "queued entries were lost")
end)

check("an invalid_grant refresh signs out cleanly and keeps the queue", function()
  local queue, auth, refreshes = setup(function() return "error", { error = "invalid_grant" } end)
  assert(queue:flush(Api, { user_id = 1 }) == false)
  assert(auth.tokens == nil, "dead tokens should be cleared")
  assert(#refreshes == 1, "a dead refresh token was presented " .. #refreshes .. " times")
  assert(queue:pendingCount() == 3, "queued entries were lost")
end)

check("a 401 invalidates the token; the next flush refreshes once and drains", function()
  local queue, auth, refreshes = setup(function() return "ok", { access_token = "hc_at_new", refresh_token = "hc_rt_2", expires_in = 3600 } end)
  -- start with a token that looks valid locally, but the server rejects it
  auth.tokens.expires_at = os.time() + 3600
  queue:flush(Api, { user_id = 1 })
  assert(#refreshes == 1, "the 401 should trigger exactly one refresh, got " .. #refreshes)
  assert(queue:pendingCount() == 1, "only the entry that hit the 401 should remain, got " .. queue:pendingCount())
  assert(queue:flush(Api, { user_id = 1 }) == true, "second flush should drain")
  assert(#refreshes == 1, "refreshed " .. #refreshes .. " times in total")
end)

r.finish()
