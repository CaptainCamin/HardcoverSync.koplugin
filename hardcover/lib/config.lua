-- Resolves plugin configuration, tolerating a missing user config file.
--
-- hardcover_config.lua is optional. It exists so a user can override the
-- defaults (own OAuth app, or a personal access token instead of signing in),
-- and it cannot be shipped because it may hold a credential.
--
-- The plugin previously did a bare `require("hardcover_config")` at load time,
-- so a fresh install with no config threw during loading and the plugin
-- silently never appeared in the menu. Resolving through here means the plugin
-- always loads: defaults first, user overrides on top.
--
-- An override that is an empty string is treated as "not set", so a
-- half-filled config does not blank out a working default.

local defaults = require("hardcover/lib/default_config")

local Config = {}

for key, value in pairs(defaults) do
  Config[key] = value
end

local ok, user_config = pcall(require, "hardcover_config")

if ok and type(user_config) == "table" then
  for key, value in pairs(user_config) do
    -- an empty string means "unset"; keep the default in that case
    if value ~= "" then
      Config[key] = value
    end
  end
end

-- The example file ships with the placeholder text rather than a real token,
-- so treat that as "no token" instead of sending it as a credential.
if Config.token == "your token here" then
  Config.token = nil
end

-- Whether the user supplied their own file, used to explain the setup in the UI
Config.has_user_config = ok and type(user_config) == "table"

return Config