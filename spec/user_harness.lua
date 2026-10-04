-- The signed-in account's id and username: kept in the settings, the name asked for once
-- (never from a menu's draw, never again after a failure), and forgotten on a new sign-in.
--
-- Run with:  lua spec/user_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local function check(label, fn) local ok, err = pcall(fn); r.check(label, ok, err) end

local online = true
package.preload["ui/network/manager"] = function()
  return { isConnected = function() return online end, getConnectionState = function() return online end }
end
local asked, answer = 0, nil
package.preload["hardcover/lib/hardcover_api"] = function()
  return {
    me = function() return answer or {} end,
    meAsync = function(_, cb) asked = asked + 1; cb(answer) end,
  }
end

local User = dofile(PLUGIN .. "/hardcover/lib/user.lua")

local function settings(initial)
  local store = initial or {}
  return { readSetting = function(_, k) return store[k] end, updateSetting = function(_, k, v) store[k] = v end }, store
end

check("the first id lookup keeps the username too", function()
  local s, store = settings()
  User.settings = s
  answer = { id = 7, username = "ChananyaMinster" }
  assert(User:getId() == 7)
  assert(store.user_id == 7 and store.user_name == "ChananyaMinster" and User:getName() == "ChananyaMinster")
end)

check("getName only reads: no name is nil, and it asks for nothing", function()
  User.settings = settings()
  asked = 0
  assert(User:getName() == nil and asked == 0)
  User.settings = nil
  assert(User:getName() == nil, "no settings at all")
end)

local function fresh(initial)
  local s, store = settings(initial)
  User.settings = s
  User.name_pending, User.name_retry_at = nil, nil
  asked, answer, online = 0, nil, true
  return store
end

check("refreshName finds an account signed in before names were kept, once, and tells the caller", function()
  local store = fresh({ user_id = 7 })
  answer = { id = 7, username = "chan" }
  local got
  User:refreshName(function(name) got = name end)
  assert(asked == 1 and store.user_name == "chan" and got == "chan")
  User:refreshName()
  assert(asked == 1, "asked again with the name known")
end)

check("offline nothing is asked and nothing is remembered: it is asked once there is a connection", function()
  fresh({ user_id = 7 })
  online = false
  User:refreshName()
  User:refreshName()
  assert(asked == 0, "asked while offline")
  assert(User.name_retry_at == nil and User.name_pending == nil, "an offline try was remembered")
  online, answer = true, { id = 7, username = "back" }
  User:refreshName()
  assert(asked == 1 and User:getName() == "back", "not asked after coming online")
end)

check("a failed answer is tried again later, not on every draw, and not for ever", function()
  fresh({ user_id = 7 })
  local t0 = 1000
  User:refreshName(nil, t0)
  User:refreshName(nil, t0 + 10)
  User:refreshName(nil, t0 + 200)
  assert(asked == 1, "asked " .. asked .. " times inside the wait")
  answer = { id = 7, username = "later" }
  User:refreshName(nil, t0 + User.RETRY_AFTER + 1)
  assert(asked == 2 and User:getName() == "later", "not asked again after the wait")
end)

check("a known name is never asked for", function()
  fresh({ user_name = "known" })
  User:refreshName()
  assert(asked == 0)
end)

check("a new sign-in forgets the old account", function()
  local s, store = settings({ user_id = 7, user_name = "old" })
  User.settings = s
  User.name_pending, User.name_retry_at = true, 99
  User:forget()
  assert(store.user_id == nil and store.user_name == nil and User.name_pending == nil and User.name_retry_at == nil)
end)

r.finish()
