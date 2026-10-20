-- BUG: a progress update for a read with no start date wiped the read's start date.
--
-- Cache:syncPage and SyncQueue send the read's started_at with every page. When the read has
-- none (nil), HardcoverApi:updatePage still put `started_at: $startedAt` in the mutation and
-- the variable was left out, so Hardcover took it as null: it cleared the date on the read
-- and rewrote the journal's "started" entry without one (seen on the live API).
--
-- Expected: with no start date to send, updatePage leaves started_at out of the mutation.
local KB = dofile((arg[1] or ".") .. "/spec/sync_regressions/lib.lua")
KB.stub_koreader()
KB.support.preload_http_stubs()
KB.support.preload_json(KB.root)
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return true end, isOnline = function() return true end }
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

local json = require("json")
local Api = require("hardcover/lib/hardcover_api")
Api.auth = nil
Api.enabled = true
Api.runtime = { subprocess = function(fn) return true, fn() end }

local sent
Api.transport = {
  post = function(_, _, body)
    sent = body
    return "200:" .. json.encode({ data = { update_user_book_read = { user_book_read = {
      id = 7, progress_pages = 40, edition_id = 3,
      user_book = { id = 5, book_id = 1, status_id = 2 } } } } })
  end,
}

print("\n== started_at on a page update ==")

KB.check("a page update without a start date does not send started_at", function()
  Api:updatePage(7, 3, 40, nil)
  KB.eq(type(sent), "table", "request sent")
  local sends_it = sent.query:find("$startedAt", 1, true) ~= nil
    or (sent.variables and sent.variables.startedAt ~= nil)
  KB.eq(sends_it, false, "started_at is in the mutation")
end)

KB.check("a page update with a start date still sends it", function()
  Api:updatePage(7, 3, 40, "2026-01-01")
  KB.eq(sent.variables.startedAt, "2026-01-01", "startedAt variable")
  KB.eq(sent.query:find("started_at: $startedAt", 1, true) ~= nil, true, "started_at in the mutation")
end)

KB.finish("a page update must not clear the start date")
