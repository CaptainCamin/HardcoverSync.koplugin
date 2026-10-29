-- signIn calls its on_done only once the user has signed in, not when the dialog opens.
--
-- Run with:  lua spec/signin_done_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local KB = dofile(PLUGIN .. "/spec/sync_regressions/lib.lua")
local App = KB.load_main()
local r = KB.support.reporter()
local check = r.test

local shown
package.loaded["hardcover/lib/ui/signin_dialog"] = {
  new = function(_, o)
    shown = o
    o.onShowSignIn = function() end
    return o
  end,
}
local User = require("hardcover/lib/user")
User.settings = { readSetting = function() end, updateSetting = function() end, saveSetting = function() end, delSetting = function() end }

check("on_done waits for the sign-in to succeed", function()
  local app = KB.new_app {
    auth = {
      usingOAuth = function() return true end,
      beginDeviceFlow = function() return { user_code = "ABCD" } end,
    },
  }
  local done = 0
  app:signIn(function() done = done + 1 end)
  assert(shown, "the sign-in dialog was not opened")
  assert(done == 0, "called while the dialog was only opening")
  shown.success_callback()
  assert(done == 1, "not called after signing in")
end)

r.finish()
