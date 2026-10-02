-- BUG: an HTTP error with a non-JSON body makes the request throw, so the
-- page that was being synced is neither sent nor queued.
--
-- HardcoverApi:query (hardcover/lib/hardcover_api.lua, `json.decode(response,
-- json.decode.simple)` then `data.data`) assumes every numeric-status reply has
-- a JSON body. Hardcover sits behind a CDN: a 502/503/504/429 normally comes
-- back as an HTML or empty body. json.decode then raises (or returns nil, and
-- `data.data` raises), and nothing in the chain catches it:
--   * Cache:syncPage (online branch) -> Api:updatePage -> query  => the error
--     escapes before `return enqueue()`, so the progress is NOT queued. From
--     onSuspend / onDocumentClose (updatePageNow is called directly, not through
--     Trapper:wrap) the error also propagates out of the event handler.
--   * SyncQueue:flush survives only thanks to its pcall; it just reports failure.
--
-- Expected: query returns nil, { status = 502, ... } for any such reply and
-- syncPage queues the page.
local KB = dofile((arg[1] or ".") .. "/spec/known_bugs/lib.lua")
KB.stub_koreader()

local reply
package.preload["socket.http"] = function()
  return {
    request = function(req)
      req.sink(reply.body)
      return 1, reply.code, {}, "status"
    end,
  }
end

local Api = require("hardcover/lib/hardcover_api")
Api.auth = nil
local Cache = require("hardcover/lib/cache")

print("\n== non-JSON error bodies ==")

for _, case in ipairs({
  { "502 with an HTML body", { code = 502, body = "<html><body>Bad gateway</body></html>" } },
  { "503 with an empty body", { code = 503, body = "" } },
  { "429 with a plain-text body", { code = 429, body = "Too Many Requests" } },
}) do
  KB.check("query does not throw on " .. case[1], function()
    reply = case[2]
    local ok, result, err = pcall(function() return Api:query("{ me { id } }") end)
    if not ok then error("query raised: " .. tostring(result), 0) end
    KB.eq(result, nil, "data")
    KB.eq(err ~= nil and err.status, case[2].code, "error status")
  end)
end

KB.check("an online page update that hits a 502 is queued, not lost", function()
  reply = { code = 502, body = "<html>Bad gateway</html>" }
  local q = KB.newQueue()
  local settings = {
    getFilePath = function() return "/books/a.epub" end,
    readBookSetting = function(_, _, key) return ({ book_id = 7, edition_id = 3 })[key] end,
    saveBookSnapshot = function() end,
  }
  local cache = Cache:new {
    settings = settings,
    sync_queue = q,
    state = { book_status = { id = 500, book_id = 7, status_id = 2,
      user_book_reads = { { id = 900, progress_pages = 10, edition_id = 3 } } } },
  }
  local ok, err = pcall(cache.syncPage, cache, "/books/a.epub", 120)
  if not ok then error("syncPage raised: " .. tostring(err), 0) end
  KB.eq(q:get("/books/a.epub") and q:get("/books/a.epub").mapped_page, 120, "queued page")
end)

KB.finish("non-JSON HTTP error replies must be handled, not thrown")
