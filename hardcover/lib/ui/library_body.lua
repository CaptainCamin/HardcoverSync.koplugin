-- The Library tab: Shelves | Lists | Vibes as three tabs of its own under the tab row, one body
-- shown at a time. No chips, no "All books", no filter. Each inner body is built the first time it
-- is opened and kept, like the shell's own tabs, so a list keeps its scroll position and an answer
-- that arrived while another tab was showing is there when you come back.
--
-- The inner bodies are the plugin's own screens built hosted (see hosted.lua), with this body as
-- their `parent` so the shell knows when they are the ones on screen.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")

local Hosted = require("hardcover/lib/ui/hosted")
local Tabs = require("hardcover/lib/ui/components/tabs")

local LibraryBody = InputContainer:extend {
  name = "hardcover_library",
  -- { { id, label, make } }; make is function(shell, width, height, parent) -> the inner body
  subs = nil,
  sub = nil, -- the id shown (default the first)
  shell = nil,
  width = nil,
  height = nil,
}

function LibraryBody:init()
  local w, h = Hosted.size(self)
  self.dimen = Geom:new { x = 0, y = 0, w = w, h = h }
  self.bodies = {}
  self.sub = self.sub or self.subs[1].id
  self:build()
end

function LibraryBody:build()
  local w, h = Hosted.size(self)
  local items = {}
  for _, sub in ipairs(self.subs) do
    items[#items + 1] = { label = sub.label, active = sub.id == self.sub, callback = function() self:setSub(sub.id) end }
  end
  local tabs = Tabs.new { width = w, tabs = items }
  local inner_h = h - tabs:getSize().h
  if not self.bodies[self.sub] then
    for _, sub in ipairs(self.subs) do
      if sub.id == self.sub then self.bodies[sub.id] = sub.make(self.shell, w, inner_h, self) end
    end
  end
  self[1] = FrameContainer:new { width = w, height = h, background = Blitbuffer.COLOR_WHITE,
    bordersize = 0, padding = 0, margin = 0,
    VerticalGroup:new { align = "left", tabs, self.bodies[self.sub] } }
end

function LibraryBody:setSub(id)
  if id == self.sub then return end
  self.sub = id
  if self[1] and type(self[1].free) == "function" then pcall(function() self[1]:free() end) end
  self[1] = nil
  self:build()
  Hosted.dirty(self)
end

-- Is this inner body the one on screen?
function LibraryBody:isCurrent(body)
  return self.bodies[self.sub] == body
end

-- An inner body was replaced (a retry built a new one): show the new one.
function LibraryBody:remount(id, body)
  self.bodies[id] = body
  if id == self.sub then
    if self[1] and type(self[1].free) == "function" then pcall(function() self[1]:free() end) end
    self[1] = nil
    self:build()
    Hosted.dirty(self)
  end
end

-- An inner body was discarded by the registry: forget it, so it is built again when opened.
function LibraryBody:unmount(body)
  for id, b in pairs(self.bodies) do
    if b == body then
      body.unmounted = true
      if body.onCloseWidget then pcall(body.onCloseWidget, body) end
      self.bodies[id] = nil
    end
  end
end

-- The shell is closing this tab's body: let go of what the inner bodies hold.
function LibraryBody:onCloseWidget()
  for _, body in pairs(self.bodies) do
    body.unmounted = true
    if body.onCloseWidget then pcall(body.onCloseWidget, body) end
  end
end

function LibraryBody:onClose() return true end

return LibraryBody
