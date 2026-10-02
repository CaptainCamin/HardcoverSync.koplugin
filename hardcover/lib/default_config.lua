-- Default configuration, shipped with the plugin.
--
-- The client_id here is a PUBLIC identifier, not a secret. Hardcover's OAuth
-- docs are explicit that public clients get no client secret precisely because
-- the client id is readable in any installed app; the Device Authorization
-- Grant is what provides the security. Someone who reads this value can start
-- a device authorization, but the code it returns is only ever displayed on
-- your device, and tokens are issued only after you approve it.
--
-- You do not need to create hardcover_config.lua to use the plugin. Create one
-- only if you want to override these values -- for example to use a personal
-- access token instead of signing in, or to register your own OAuth app.

return {
  -- OAuth app registered for this plugin ("Mobile, desktop, or CLI", Device
  -- Authorization Grant enabled).
  client_id = "636a2d1e-c265-45cb-9811-7452d6e49240",

  -- Scope set requested at sign-in. There is no separate write:journal scope;
  -- journal reads and writes are both covered by the library scopes.
  -- read:social is what allows reading other readers' reviews. The OAuth app
  -- must allow every scope listed here: asking for one it does not allow fails
  -- the whole sign-in with invalid_scope.
  scope = "read:catalog read:catalog:search read:me:content read:library read:social write:library",

  -- Personal access token. Left empty on purpose: sign in from the plugin
  -- instead. A token set here is used only when client_id is empty.
  token = nil,
}