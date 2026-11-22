--[[--
First-run landing screen: with no account the plugin opens a standalone
welcome screen that explains itself and has one clear way to sign in.

Screens: first_run_welcome.
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
  name = "first_run_welcome",

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

    local shell = UIManager:getTopmostVisibleWidget()
    assert(shell.name == "hardcover_shell", "the landing screen is not in the shell")
    assert(#shell.tabs == 1 and shell.bodies.home.name == "hardcover_welcome",
      "the landing screen still offers tabs that need an account")

    emu:expectText("Welcome to Hardcover Sync")
    emu:expectText("Hardcover Sync connects the books on this reader to your Hardcover account.")
    emu:expectText("WHAT IT DOES")
    emu:expectText("Track your reading")
    emu:expectText("Keep shelves in sync")
    emu:expectText("See your progress")
    local text = emu:screenText()
    assert(not text:find("Get started", 1, true), "the sign-in button still has a section header")
    assert(not text:find("No API key needed", 1, true), "the sign-in button has a paragraph under it")
    assert(not text:find("CURRENTLY READING", 1, true), "the landing screen shows the reading section")
    assert(not text:find("All synced", 1, true), "the landing screen shows the sync box")
    assert(not text:find("Shelves", 1, true), "the landing screen shows shelves")
    assert(not text:find("Library", 1, true) and not text:find("Stats", 1, true),
      "the landing screen still shows empty tabs")
    emu:shot("first_run_welcome")

    -- the primary action is a real button, and it starts the same sign-in flow
    emu:screenNodes()
    local sign_in = find_button(UIManager:getTopmostVisibleWidget(), "Sign in to Hardcover")
    assert(sign_in, "the landing screen has no Sign in button")
    emu:tapExpecting(sign_in.dimen.x + math.floor(sign_in.dimen.w / 2),
      sign_in.dimen.y + math.floor(sign_in.dimen.h / 2))
    emu:pump()
    assert(sign_ins == 1, "Sign in did not start the sign-in flow")

    -- Signing in (or out) while the shell is up swaps the tabs as well as Home:
    -- the four account tabs come back, and signing out lands on the welcome again.
    local NetworkManager = require("ui/network/manager")
    local was_connected, was_state = NetworkManager.isConnected, NetworkManager.getConnectionState
    NetworkManager.isConnected = function() return false end
    NetworkManager.getConnectionState = function() return false end
    Api.auth = {
      usingOAuth = function() return true end,
      usingPat = function() return false end,
      needsReauth = function() return false end,
    }
    manager:refreshHome()
    emu:pump()
    assert(#shell.tabs == 4 and shell.bodies.home.name == "hardcover_home_body",
      "signing in did not bring the account tabs back")
    emu:expectText("CURRENTLY READING")

    shell:setTab("stats")
    Api.auth = {
      usingOAuth = function() return true end,
      usingPat = function() return false end,
      needsReauth = function() return true end,
    }
    manager:refreshHome()
    emu:pump()
    assert(#shell.tabs == 1 and shell.active == "home" and shell.bodies.home.name == "hardcover_welcome",
      "signing out from another tab did not return to the landing screen")
    emu:expectText("Welcome to Hardcover Sync")
    NetworkManager.isConnected, NetworkManager.getConnectionState = was_connected, was_state
  end,
}
