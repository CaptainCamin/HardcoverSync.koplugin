-- The API layer against a fake runtime and a fake transport, with no KOReader UI or
-- networking module available at all: requiring hardcover_api must not pull in
-- ui/trapper, ui/uimanager, socket.http, ltn12 or socketutil, and a request must go through
-- `Api.runtime` and `Api.transport` and nothing else.
--
-- Run with:  lua spec/api_runtime_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_koreader_stubs()
support.preload_json(PLUGIN)

-- Modules that belong to KOReader's UI and networking. Asking for one is a failure.
local forbidden_loaded = {}
for _, name in ipairs({ "ui/trapper", "ui/uimanager", "socket.http", "ltn12", "socketutil", "socket" }) do
  package.preload[name] = function()
    forbidden_loaded[#forbidden_loaded + 1] = name
    error("hardcover_api must not need " .. name)
  end
end

-- the few KOReader utilities the API does use
package.preload["ffi/util"] = function()
  local util = { template = function(t) return t end }
  setmetatable(util, { __call = function(_, s) return tostring(s) end })
  return util
end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
local online = true
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return online end, isOnline = function() return online end }
end

local r = support.reporter()
local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

local Api = require("hardcover/lib/hardcover_api")

-- A runtime that runs everything inline and records how it was used.
local ticks = {}
local runtime_log
local function new_runtime()
  runtime_log = { subprocess = {}, wrapped = 0 }
  return {
    subprocess = function(fn, background)
      runtime_log.subprocess[#runtime_log.subprocess + 1] = { background = background }
      return true, fn()
    end,
    wrap = function(fn) runtime_log.wrapped = runtime_log.wrapped + 1; fn() end,
    next_tick = function(fn) ticks[#ticks + 1] = fn end,
  }
end

-- A transport that answers from a script and records what it was asked.
local posts, reply
local function new_transport()
  posts = {}
  return { post = function(url, headers, body)
    posts[#posts + 1] = { url = url, headers = headers, body = body }
    return reply
  end }
end

local function setup(answer)
  Api.runtime, Api.transport = new_runtime(), new_transport()
  Api.auth = nil
  Api.enabled = true
  online = true
  reply = answer or '200:{"data":{"me":[{"id":7,"username":"reader"}]}}'
end

print("\n== no KOReader UI or networking is needed ==")

check("requiring the API loaded none of the UI or networking modules", function()
  assert(#forbidden_loaded == 0, "required: " .. table.concat(forbidden_loaded, ", "))
end)

check("a whole request and an async call work without them", function()
  setup()
  assert(Api:me().id == 7)
  local got
  Api:meAsync(function(me) got = me end)
  while #ticks > 0 do table.remove(ticks, 1)() end
  assert(got and got.id == 7)
  assert(#forbidden_loaded == 0, "required: " .. table.concat(forbidden_loaded, ", "))
end)

print("\n== what goes to the transport ==")

check("the request is posted to the GraphQL endpoint with the query and variables", function()
  setup()
  Api:query("{ me { id } }", { x = 1 })
  local post = posts[1]
  assert(post.url:find("^https://api%.hardcover%.app/"), tostring(post.url))
  assert(post.body.query == "{ me { id } }" and post.body.variables.x == 1)
  assert(post.headers["Content-Type"] == "application/json")
  assert(post.headers["User-Agent"]:find("hardcoversync.koplugin", 1, true))
end)

check("the token is resolved before the subprocess and sent as a Bearer header", function()
  setup()
  local order = {}
  Api.auth = {
    accessToken = function() order[#order + 1] = "token"; return "tok123" end,
    invalidateAccessToken = function() end,
  }
  local runtime = Api.runtime
  local inner = runtime.subprocess
  runtime.subprocess = function(fn, bg) order[#order + 1] = "subprocess"; return inner(fn, bg) end
  Api:query("{ me { id } }")
  assert(order[1] == "token" and order[2] == "subprocess",
    "resolved in the child, not the parent: " .. table.concat(order, ","))
  assert(posts[1].headers.Authorization == "Bearer tok123")
  assert(#order == 2, "the token was resolved " .. (#order - 1) .. " times")
end)

check("a background request is marked so a tap cannot cancel it", function()
  setup()
  Api:query("{ a }")
  Api:query("{ b }", nil, true)
  assert(runtime_log.subprocess[1].background == nil or runtime_log.subprocess[1].background == false)
  assert(runtime_log.subprocess[2].background == true)
end)

print("\n== what comes back ==")

check("data comes back as the result", function()
  setup('200:{"data":{"things":[1,2]}}')
  local data = Api:query("{ things }")
  assert(data.things[2] == 2)
end)

check("GraphQL errors come back as nil and the errors with the status", function()
  setup('200:{"errors":[{"message":"nope"}]}')
  local data, err = Api:query("{ x }")
  assert(data == nil and err.status == 200 and err.errors[1].message == "nope")
end)

check("a body that is not JSON (a CDN error page) does not throw", function()
  setup('502:<html>bad gateway</html>')
  local data, err = Api:query("{ x }")
  assert(data == nil and err.status == 502)
end)

check("a request cut short comes back as not completed", function()
  setup('408:')
  local data, err = Api:query("{ x }")
  assert(data == nil)
  -- 408 with no body is not JSON: reported by status, like any other
  assert(err.status == 408 or err.completed == false)
end)

check("a subprocess that did not finish comes back as not completed", function()
  setup()
  Api.runtime.subprocess = function() return false end
  local data, err = Api:query("{ x }")
  assert(data == nil and err.completed == false)
end)

check("a 401 invalidates the access token so the next call refreshes it", function()
  setup('401:{"error":"unauthorized"}')
  local invalidated = false
  Api.auth = {
    accessToken = function() return "old" end,
    invalidateAccessToken = function() invalidated = true end,
  }
  Api:query("{ x }")
  assert(invalidated)
end)

check("offline, nothing is sent", function()
  setup()
  online = false
  local data = Api:query("{ x }")
  assert(data == nil and #posts == 0)
end)

check("a disabled API sends nothing", function()
  setup()
  Api.enabled = false
  local data = Api:query("{ x }")
  Api.enabled = true
  assert(data == nil and #posts == 0)
end)

print("\n== the async path ==")

check("async calls are wrapped through the runtime and delivered on its tick", function()
  setup()
  local got
  Api:meAsync(function(me) got = me end)
  assert(runtime_log.wrapped == 1, "wrapped " .. runtime_log.wrapped)
  assert(got == nil, "delivered before the tick")
  while #ticks > 0 do table.remove(ticks, 1)() end
  assert(got and got.username == "reader")
end)

r.finish()
