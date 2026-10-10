-- The shell: one screen that holds the plugin's main tabs (Home, Library, Goals, Stats), so moving
-- between them is a tap on the navigation bar and not one screen stacked on another.
--
-- It owns the top bar (the tab's title and its actions), the body and the nav bar. Each tab's body
-- is built the first time the tab is opened and kept, so coming back finds it as it was left: the
-- same scroll position, and whatever arrived while it was hidden. Switching tabs redraws the
-- screen once and nothing else; nothing animates.
--
-- Bodies are the plugin's own screens built hosted (ui/hosted.lua): no title bar, the body's size,
-- repaints through the shell. A screen that was opened over the shell (book details, a shelf's
-- books) is a separate window above it, so closing it reveals the shell as it was.
--
-- Back: on any tab but the first it goes to the first tab; on the first it leaves the shell.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local NavBar = require("hardcover/lib/ui/components/nav_bar")
local Theme = require("hardcover/lib/ui/theme")
local TopBar = require("hardcover/lib/ui/components/top_bar")

local Screen = Device.screen

local Shell = InputContainer:extend {
  name = "hardcover_shell",
  -- { { id, label, title (the top bar's; default the label), icon_name, actions, make } }; make is
  -- function(shell, width, height) -> the tab's body, built hosted
  tabs = nil,
  active = nil, -- the id shown (default the first)
  on_close = nil,
}

function Shell:init()
  self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
  self.covers_fullscreen = true
  self.bodies = {}
  self.active = self.active or self.tabs[1].id
  if Device:hasKeys() then
    self.key_events.Back = { { Device.input.group.Back } }
  end
  self:build()
end

-- A body leaving: late answers must find it gone, and what it holds (decoded covers) is let go.
local function release(body)
  body.unmounted = true
  if body.onCloseWidget then pcall(body.onCloseWidget, body) end
end

function Shell:tab(id)
  for _, tab in ipairs(self.tabs) do
    if tab.id == id then return tab end
  end
end

-- The tab's body, built on first use.
function Shell:body(id)
  if not self.bodies[id] then
    self.bodies[id] = self:tab(id).make(self, self.body_w, self.body_h)
  end
  return self.bodies[id]
end

function Shell:isActive(body)
  local active = self.bodies[self.active]
  if body == active then return true end
  -- an inner body of the Library tab is on screen while its tab is and it is the one shown
  return body.parent ~= nil and body.parent == active and active:isCurrent(body)
end

function Shell:build()
  local sw, sh = Screen:getWidth(), Screen:getHeight()
  local tab = self:tab(self.active)

  local items = {}
  for _, t in ipairs(self.tabs) do
    items[#items + 1] = {
      label = t.label, icon_name = t.icon_name, active = t.id == self.active,
      callback = function() self:setTab(t.id) end,
    }
  end
  local nav = NavBar.new { width = sw, items = items }
  -- MMD top bar: a back arrow where you can go back (any tab but the first goes to the first), and
  -- on the first tab a close, the last of its actions, so a device with no Back key can leave
  local actions, on_back = {}, nil
  for _, a in ipairs(tab.actions or {}) do actions[#actions + 1] = a end
  if self.active == self.tabs[1].id then
    actions[#actions + 1] = { icon = "close", callback = function() self:onClose() end }
  else
    on_back = function() self:setTab(self.tabs[1].id) end
  end
  local top = TopBar.new { width = sw, title = tab.title or tab.label, actions = actions, on_back = on_back }

  self.body_w = sw
  self.body_h = sh - top:getSize().h - nav:getSize().h
  local body = self:body(self.active)

  self.frame = FrameContainer:new {
    width = sw, height = sh, background = Blitbuffer.COLOR_WHITE,
    bordersize = 0, padding = 0, margin = 0,
    VerticalGroup:new { align = "left", top, body, nav },
  }
  self[1] = self.frame
end

-- Show another tab: one redraw of the screen.
function Shell:setTab(id)
  if id == self.active or not self:tab(id) then return end
  self.active = id
  self:build()
  UIManager:setDirty(self, "ui")
end

-- A screen taken out of the shell (the registry discards it before building its replacement):
-- forget it, so the tab builds a new one when it is next shown.
function Shell:unmount(body)
  if body.parent then return body.parent:unmount(body) end
  for id, b in pairs(self.bodies) do
    if b == body then
      release(body)
      self.bodies[id] = nil
    end
  end
end

-- Build the tab's body again in place (its replacement is already registered by the caller).
function Shell:remount(id, body)
  self.bodies[id] = body
  if id == self.active then
    self:build()
    UIManager:setDirty(self, "ui")
  end
end

function Shell:onBack()
  if self.active ~= self.tabs[1].id then
    self:setTab(self.tabs[1].id)
    return true
  end
  return self:onClose()
end

function Shell:onCloseWidget()
  self.closed = true -- what the cover cells check before they refresh
  for _, body in pairs(self.bodies) do release(body) end
  UIManager:setDirty(nil, "ui")
end

function Shell:onClose()
  UIManager:close(self)
  if self.on_close then self.on_close() end
  return true
end

return Shell
