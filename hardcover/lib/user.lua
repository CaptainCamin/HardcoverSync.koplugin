local SETTING = require("hardcover/lib/constants/settings")
local Api = require("hardcover/lib/hardcover_api")
local Network = require("hardcover/lib/network")

local User = {}

function User:getId()
  local user_id = self.settings:readSetting(SETTING.USER_ID)
  if not user_id then
    local me = Api:me()
    user_id = me.id
    self.settings:updateSetting(SETTING.USER_ID, user_id)
    if type(me.username) == "string" and me.username ~= "" then
      self.settings:updateSetting(SETTING.USER_NAME, me.username)
    end
  end

  return user_id
end

-- The signed-in account's username as last seen, or nil. Reads the saved copy only, so a
-- menu can ask for it while it draws; `refreshName` is what finds out.
function User:getName()
  local name = self.settings and self.settings:readSetting(SETTING.USER_NAME)
  if type(name) == "string" and name ~= "" then return name end
end

-- Find out the username when it is not known yet (an account signed in before it was
-- kept), without waiting: calls `done(name)` when the answer is in. Does nothing when the
-- name is known, a request is already on its way, there is no connection (nothing is
-- remembered then, so it is asked once there is), or an answer failed less than
-- RETRY_AFTER seconds ago (a menu that draws often must not send a request each time).
User.RETRY_AFTER = 300

function User:refreshName(done, now)
  now = now or os.time()
  if User:getName() or User.name_pending then return end
  if User.name_retry_at and now < User.name_retry_at then return end
  if not Network.connected() then return end

  User.name_pending = true
  Api:meAsync(function(me)
    User.name_pending = nil
    local name = type(me) == "table" and me.username
    if type(name) == "string" and name ~= "" then
      User.name_retry_at = nil
      self.settings:updateSetting(SETTING.USER_NAME, name)
      if done then done(name) end
    else
      User.name_retry_at = now + User.RETRY_AFTER
    end
  end)
end

-- Forget who was signed in (a different account may sign in next).
function User:forget()
  self.settings:updateSetting(SETTING.USER_ID, nil)
  self.settings:updateSetting(SETTING.USER_NAME, nil)
  User.name_pending, User.name_retry_at = nil, nil
end

return User
