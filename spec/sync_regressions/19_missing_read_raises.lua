-- BUG: a page update for a read Hardcover does not have threw instead of failing.
--
-- Hardcover answers update_user_book_read / insert_user_book_read for an unknown read id with
-- an error and `user_book_read: null`. normalizeUserBookRead indexed that nil, so the page
-- sync raised in the page-turn handler instead of returning nil to be queued and retried.
--
-- Expected: updatePage and createRead return nil.
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

Api.transport = {
  post = function()
    return "200:" .. json.encode({ data = { update_user_book_read = { error = "Not found" },
      insert_user_book_read = { error = "Not found" } } })
  end,
}

print("\n== a read Hardcover does not have ==")

KB.check("updatePage returns nil instead of raising", function()
  KB.eq(Api:updatePage(999, 3, 40, "2026-01-01"), nil, "result")
end)

KB.check("createRead returns nil instead of raising", function()
  KB.eq(Api:createRead(999, 3, 40, "2026-01-01"), nil, "result")
end)

KB.finish("a missing read must not raise")
