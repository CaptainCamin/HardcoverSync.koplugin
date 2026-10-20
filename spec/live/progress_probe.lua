local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

if (os.getenv("HARDCOVER_DEV_KEY") or "") == "" then
  io.stderr:write("HARDCOVER_DEV_KEY is not set\n")
  os.exit(2)
end

local support = dofile(PLUGIN .. "/spec/support.lua")
support.preload_ui_stubs()
support.preload_http_stubs()
support.preload_json(PLUGIN)
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
package.preload["hardcover_version"] = function() return { "0", "0", "0", "live" } end

local json = require("json")
local Api = require("hardcover/lib/hardcover_api")
Api.auth = nil
Api.enabled = true

-- Requests run inline, and go out through curl. The request body and the Authorization header
-- are read by curl from stdin / the environment, so the token is never on a command line.
Api.runtime = { subprocess = function(fn) return true, fn() end }

local failures_http = {}
local API_URL = "https://api.hardcover.app/v1/graphql"
Api.transport = {
  post = function(url, headers, body)
    assert(url == API_URL, "unexpected endpoint " .. tostring(url))
    local agent = (headers["User-Agent"] or "hardcoversync-live-check"):gsub("[^%w%.%-%s%(%)/:]", "")
    agent = tostring(agent)
    local cmd = "curl -sS --max-time 30 -w '\\n%{http_code}'"
      .. " -H 'Content-Type: application/json'"
      .. " -H 'User-Agent: " .. agent .. "'"
      .. " -H \"Authorization: Bearer ${HARDCOVER_DEV_KEY#Bearer }\""
      .. " --data-binary @- '" .. url .. "'"
    local tmp = os.tmpname()
    local f = assert(io.open(tmp, "w"))
    f:write(json.encode(body))
    f:close()
    local p = assert(io.popen(cmd .. " < " .. tmp, "r"))
    local out = p:read("*a")
    p:close()
    os.remove(tmp)
    local content, code = out:match("^(.*)\n(%d+)$")
    if not code then return "0:" end
    if not code:match("^2") then
      failures_http[#failures_http + 1] = code
    end
    return code .. ":" .. content
  end,
}

-- every GraphQL error counts, even in a call whose wrapper would swallow it
local graphql_errors = {}
Api.on_error = function(e)
  graphql_errors[#graphql_errors + 1] = type(e) == "table" and (e.message or json.encode(e)) or tostring(e)
end

local r = support.reporter()

local function show(label, v) print(label, json.encode(v)) end
local me = Api:me(); local uid = tonumber(me.id)
local books = Api:search("Dune", "Frank Herbert", uid)
local book_id = tonumber(books[1].book_id)
local eds = Api:findEditions(book_id, uid)
local edition_id = tonumber(eds[1].edition_id or eds[1].id)
local left = Api:findUserBook(book_id, uid)
if type(left) == "table" and left.id then Api:removeUserBook(left.id) end

local Q_BOOK = [[query($b:Int!,$u:Int!){ user_books(where:{book_id:{_eq:$b},user_id:{_eq:$u}}){ id status_id edition_id
  user_book_reads(order_by:{id:asc}){ id started_at finished_at progress_pages edition_id } } }]]
local Q_J = [[query($b:Int!,$u:Int!){ reading_journals(where:{book_id:{_eq:$b},user_id:{_eq:$u}},order_by:{id:asc}){ id event metadata action_at } }]]
local today = os.date("!%Y-%m-%d")
local ok, err = pcall(function()
  local ub = Api:updateUserBook(book_id, 2, nil, edition_id)
  show("A added (status reading)", ub)
  local r1 = ub.user_book_reads[1].id
  show("B update auto read to 10", Api:updatePage(r1, edition_id, 10, today))
  show("B raw", Api:query(Q_BOOK, { b = book_id, u = uid }))
  show("B journal", Api:query(Q_J, { b = book_id, u = uid }))
  show("C update auto read to 25", Api:updatePage(r1, edition_id, 25, today))
  show("C journal", Api:query(Q_J, { b = book_id, u = uid }))
  show("D update with nil started_at to 40", Api:updatePage(r1, edition_id, 40, nil))
  show("D raw", Api:query(Q_BOOK, { b = book_id, u = uid }))
  show("D journal", Api:query(Q_J, { b = book_id, u = uid }))
  show("E createRead 50 (second read)", Api:createRead(ub.id, edition_id, 50, today))
  show("E raw", Api:query(Q_BOOK, { b = book_id, u = uid }))
  show("E journal", Api:query(Q_J, { b = book_id, u = uid }))
  Api:removeUserBook(ub.id)
end)
if not ok then print("PROBE ERROR", err) end
local left2 = Api:findUserBook(book_id, uid)
if type(left2) == "table" and left2.id then Api:removeUserBook(left2.id) end
