-- Configuration for the Hardcover KOReader plugin.
--
-- Two ways to authenticate. Pick ONE:
--
-- 1. Sign in from the plugin (recommended)
--    Register a public app at
--      https://hardcover.app/account/developer-apps/new
--    Choose "Mobile, desktop, or CLI" as the application type, leave the
--    Device Authorization Grant toggle ON, and allow these scopes:
--      read:catalog read:catalog:search read:me:content read:library
--      read:social write:library
--    Put the client id below. There is no secret: this is a public client, and
--    the plugin uses the device flow so no browser is needed on the reader.
--
-- 2. A personal access token (older setup, still supported)
--    Get one from https://hardcover.app/account/api
--
-- Tokens obtained through sign-in are stored separately by the plugin; only
-- the client id belongs in this file.

return {
  -- Option 1: OAuth client id from the developer apps page
  client_id = '',

  -- Option 2: personal access token, used only when client_id is empty
  token = 'your token here',
}