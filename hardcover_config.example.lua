-- Configuration for the Hardcover KOReader plugin.
--
-- You do NOT need this file. The plugin comes with its own Hardcover app
-- registration: choose Account > Sign in in the plugin's menu. Copy this file to
-- hardcover_config.lua only to use your own OAuth app or a personal token.
--
-- Two ways to authenticate. Pick ONE:
--
-- 1. Your own OAuth app (instead of the bundled one)
--    Register a public app at
--      https://hardcover.app/account/developer-apps/new
--    Choose "Mobile, desktop, or CLI" as the application type, leave the
--    Device Authorization Grant toggle ON, and allow these scopes:
--      read:catalog read:catalog:search read:me:content read:library
--      read:social write:library
--    Put the client id below. There is no secret: this is a public client, and
--    the plugin uses the device flow so no browser is needed on the reader.
--
-- 2. A personal access token (instead of signing in)
--    Get one from https://hardcover.app/account/api and fill in `token` below.
--    Leave `client_id` empty. A token is a secret: do not share this file.
--
-- Tokens obtained through sign-in are stored separately by the plugin; only
-- the client id belongs in this file.

return {
  -- Option 1: your own OAuth client id (leave empty to use the bundled app)
  client_id = '',

  -- Option 2: personal access token, used instead of signing in
  token = 'your token here',
}