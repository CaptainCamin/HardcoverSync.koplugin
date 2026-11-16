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
    local privacy = tonumber(me.account_privacy_setting_id)
    if privacy then self.settings:updateSetting(SETTING.ACCOUNT_PRIVACY, privacy) end
  end

  return user_id
end

-- The account's default visibility for new notes, quotes and other entries, as
-- last seen from Hardcover. nil when it has not been seen yet; callers must not
-- turn that into a public default.
function User:getAccountPrivacy()
  return self.settings and tonumber(self.settings:readSetting(SETTING.ACCOUNT_PRIVACY))
end

-- Ask Hardcover for the account's default visibility, independently of the
-- cached id and username. Called when a new journal entry needs it, so an
-- account that was already signed in before this setting existed gets a value
-- too. Offline or unanswered, the saved value stays; with none, callers get nil
-- and use Private.
function User:refreshAccountPrivacy(done, now)
  now = now or os.time()
  if not self.settings then
    if done then done(nil) end
    return
  end
  if User.privacy_pending then
    if done then
      User.privacy_waiters = User.privacy_waiters or {}
      table.insert(User.privacy_waiters, done)
    end
    return
  end
  if User.privacy_retry_at and now < User.privacy_retry_at then
    if done then done(self:getAccountPrivacy()) end
    return
  end
  if not Network.connected() or type(Api.meAsync) ~= "function" then
    if done then done(self:getAccountPrivacy()) end
    return
  end

  local generation = User.account_generation or 0
  User.privacy_pending = true
  User.privacy_waiters = {}
  local waiters = User.privacy_waiters
  Api:meAsync(function(me)
    if generation ~= (User.account_generation or 0) then
      User.privacy_pending, User.privacy_waiters = nil, nil
      local value = self:getAccountPrivacy()
      if done then done(value) end
      for _, cb in ipairs(waiters) do cb(value) end
      return
    end

    User.privacy_pending, User.privacy_waiters = nil, nil
    local privacy = tonumber(me and me.account_privacy_setting_id)
    if privacy then
      User.privacy_retry_at = nil
      self.settings:updateSetting(SETTING.ACCOUNT_PRIVACY, privacy)
    else
      User.privacy_retry_at = now + User.RETRY_AFTER
    end
    local value = self:getAccountPrivacy()
    if done then done(value) end
    for _, cb in ipairs(waiters) do cb(value) end
  end)
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

  local generation = User.account_generation or 0
  User.name_pending = true
  Api:meAsync(function(me)
    User.name_pending = nil
    if generation ~= (User.account_generation or 0) then
      if done then done(self:getName()) end
      return
    end
    local name = type(me) == "table" and me.username
    if type(name) == "string" and name ~= "" then
      User.name_retry_at = nil
      self.settings:updateSetting(SETTING.USER_NAME, name)
      local privacy = tonumber(me.account_privacy_setting_id)
      if privacy then self.settings:updateSetting(SETTING.ACCOUNT_PRIVACY, privacy) end
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
  self.settings:updateSetting(SETTING.ACCOUNT_PRIVACY, nil)
  User.name_pending, User.name_retry_at = nil, nil
  User.privacy_pending, User.privacy_retry_at = nil, nil
  User.privacy_waiters = nil
  User.account_generation = (User.account_generation or 0) + 1
end

return User
