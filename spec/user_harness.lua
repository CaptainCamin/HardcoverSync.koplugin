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
local Api = require("hardcover/lib/hardcover_api")

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

check("the first id lookup keeps the account privacy default", function()
  local s, store = settings()
  User.settings = s
  answer = { id = 7, username = "ChananyaMinster", account_privacy_setting_id = 2 }
  assert(User:getId() == 7)
  assert(store.account_privacy_setting_id == 2)
  assert(User:getAccountPrivacy() == 2)
end)

check("no account privacy default stays nil, not Public", function()
  local s, store = settings({ user_id = 7 })
  User.settings = s
  assert(User:getAccountPrivacy() == nil)
  assert(store.account_privacy_setting_id == nil)
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
  User.privacy_pending, User.privacy_retry_at = nil, nil
  User.name_request, User.privacy_request, User.account_generation = nil, nil, nil
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

check("privacy refresh works with a cached id and name", function()
  local store = fresh({ user_id = 7, user_name = "old" })
  answer = { id = 7, username = "old", account_privacy_setting_id = 2 }
  local got
  User:refreshAccountPrivacy(function(value) got = value end)
  assert(asked == 1 and store.account_privacy_setting_id == 2 and got == 2)
end)

check("privacy refresh replaces an older saved default", function()
  local store = fresh({ user_id = 7, user_name = "old", account_privacy_setting_id = 2 })
  answer = { id = 7, username = "old", account_privacy_setting_id = 3 }
  User:refreshAccountPrivacy()
  assert(store.account_privacy_setting_id == 3)
end)

check("privacy refresh keeps the saved value when Hardcover has no answer", function()
  local store = fresh({ user_id = 7, user_name = "old", account_privacy_setting_id = 3 })
  answer = { id = 7, username = "old" }
  local got
  User:refreshAccountPrivacy(function(value) got = value end)
  assert(store.account_privacy_setting_id == 3 and got == 3, "a saved Private default was lost")
end)

check("privacy refresh offline asks nothing and keeps the saved value", function()
  local store = fresh({ user_id = 7, user_name = "old", account_privacy_setting_id = 2 })
  online = false
  local got
  User:refreshAccountPrivacy(function(value) got = value end)
  assert(asked == 0 and store.account_privacy_setting_id == 2 and got == 2)
end)

check("a form opened while privacy is pending gets the answer too", function()
  local store = fresh({ user_id = 7, user_name = "old" })
  local saved = Api.meAsync
  local pending
  Api.meAsync = function(_, cb) pending = cb end
  local first, second
  User:refreshAccountPrivacy(function(value) first = value end)
  User:refreshAccountPrivacy(function(value) second = value end)
  assert(pending and first == nil and second == nil)
  pending({ id = 7, username = "old", account_privacy_setting_id = 2 })
  assert(first == 2 and second == 2 and store.account_privacy_setting_id == 2)
  Api.meAsync = saved
end)

check("a privacy response from the old account is ignored", function()
  local store = fresh({ user_id = 7, user_name = "old" })
  local saved = Api.meAsync
  local pending
  Api.meAsync = function(_, cb) pending = cb end
  local got
  User:refreshAccountPrivacy(function(value) got = value end)
  User:forget()
  pending({ id = 7, username = "old", account_privacy_setting_id = 1 })
  assert(store.account_privacy_setting_id == nil and got == nil)
  Api.meAsync = saved
end)

check("a name response from the old account is ignored", function()
  local store = fresh({ user_id = 7 })
  local saved = Api.meAsync
  local pending
  Api.meAsync = function(_, cb) pending = cb end
  User:refreshName()
  User:forget()
  pending({ id = 7, username = "old", account_privacy_setting_id = 1 })
  assert(store.user_name == nil and store.account_privacy_setting_id == nil)
  Api.meAsync = saved
end)

check("an old privacy reply does not clear the new account's request", function()
  local store = fresh({ user_id = 7, user_name = "old" })
  local saved = Api.meAsync
  local old_cb, new_cb
  local calls = 0
  Api.meAsync = function(_, cb)
    calls = calls + 1
    if calls == 1 then old_cb = cb else new_cb = cb end
  end
  User:refreshAccountPrivacy()
  User:forget()
  User:refreshAccountPrivacy()
  assert(User.privacy_pending and User.privacy_request)
  old_cb({ id = 7, username = "old", account_privacy_setting_id = 1 })
  assert(User.privacy_pending and User.privacy_request, "an old reply cleared the new request")
  local third
  User:refreshAccountPrivacy(function(value) third = value end)
  assert(calls == 2, "a third request started after the stale reply")
  new_cb({ id = 8, username = "new", account_privacy_setting_id = 2 })
  assert(third == 2 and store.account_privacy_setting_id == 2)
  Api.meAsync = saved
end)

check("an old name reply does not clear the new account's request", function()
  local store = fresh({ user_id = 7 })
  local saved = Api.meAsync
  local old_cb, new_cb
  local calls = 0
  Api.meAsync = function(_, cb)
    calls = calls + 1
    if calls == 1 then old_cb = cb else new_cb = cb end
  end
  User:refreshName()
  User:forget()
  User:refreshName()
  assert(User.name_pending and User.name_request)
  old_cb({ id = 7, username = "old", account_privacy_setting_id = 1 })
  assert(User.name_pending and User.name_request, "an old reply cleared the new request")
  new_cb({ id = 8, username = "new", account_privacy_setting_id = 2 })
  assert(store.user_name == "new" and store.account_privacy_setting_id == 2)
  Api.meAsync = saved
end)

check("a new sign-in forgets the old account", function()
  local store = fresh({ user_id = 7, user_name = "old", account_privacy_setting_id = 3 })
  User.name_pending, User.name_retry_at = true, 99
  User.privacy_pending, User.privacy_retry_at = true, 99
  User:forget()
  assert(store.user_id == nil and store.user_name == nil and store.account_privacy_setting_id == nil
    and User.name_pending == nil and User.name_retry_at == nil
    and User.privacy_pending == nil and User.privacy_retry_at == nil
    and User.name_request == nil and User.privacy_request == nil
    and User.account_generation == 1)
end)

r.finish()
