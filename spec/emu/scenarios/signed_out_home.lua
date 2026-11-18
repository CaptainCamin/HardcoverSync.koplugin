--[[--
Signed-out Home: no account means no shelves, counts or reading card, and one clear way in.

Screens: signed_out_home.
]]--

local fixtures = require("fixtures")
local UIManager = require("ui/uimanager")
local Api = require("hardcover/lib/hardcover_api")

local function find_button(root, label, seen)
  seen = seen or {}
  if type(root) ~= "table" or seen[root] then return end
  seen[root] = true
  if root.text == label and root.callback and root.dimen and root.dimen.w and root.dimen.w > 0 then
    return root
  end
  for _, child in pairs(root) do
    local found = find_button(child, label, seen)
    if found then return found end
  end
end

return {
  name = "signed_out_home",

  run = function(emu)
    local settings = fixtures.real_settings(emu)
    fixtures.install({ settings = settings })
    Api.auth = {
      usingOAuth = function() return true end,
      usingPat = function() return false end,
      needsReauth = function() return true end,
      hasScope = function() return false end,
      statusText = function() return "Sign in again" end,
    }

    local sign_ins = 0
    local DialogManager = require("hardcover/lib/ui/dialog_manager")
    local manager = DialogManager:new {
      settings = settings,
      sign_in = function() sign_ins = sign_ins + 1 end,
    }
    manager:showHome()
    emu:pump()

    emu:expectText("Sign in to Hardcover")
    emu:expectText("Your shelves, reading and sync will appear here after you sign in.")
    local text = emu:screenText()
    assert(not text:find("CURRENTLY READING", 1, true), "signed-out Home still shows the reading section")
    assert(not text:find("All synced", 1, true), "signed-out Home still shows the sync box")
    assert(not text:find("Shelves", 1, true), "signed-out Home still shows shelves")
    emu:shot("signed_out_home")

    emu:screenNodes()
    local sign_in = find_button(UIManager:getTopmostVisibleWidget(), "Sign in")
    assert(sign_in, "the signed-out Home has no Sign in button")
    emu:tapExpecting(sign_in.dimen.x + math.floor(sign_in.dimen.w / 2),
      sign_in.dimen.y + math.floor(sign_in.dimen.h / 2))
    emu:pump()
    assert(sign_ins == 1, "Sign in did not start the sign-in flow")
  end,
}
