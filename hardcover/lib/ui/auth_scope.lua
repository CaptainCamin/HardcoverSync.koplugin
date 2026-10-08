-- Whether the sign-in is known to lack a permission.
--
-- A sign-in from before a scope was asked for lacks it, and the screens that need it
-- then say to sign out and back in instead of sending a request that would only be
-- refused. Unknown (no sign-in object, as with a personal token, or not yet learned)
-- counts as fine: the request itself will say.

local Api = require("hardcover/lib/hardcover_api")

local AuthScope = {}

function AuthScope.missing(scope)
  return Api.auth and Api.auth:hasScope(scope) == false
end

return AuthScope
