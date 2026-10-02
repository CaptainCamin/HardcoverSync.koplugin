--[[--
Refresh and decode probe for the emulator.

What it measures is the thing an e-ink panel pays for, not milliseconds (desktop
timings say nothing about a device):

  * refreshes  the rectangles UIManager hands to the framebuffer after it has
               merged everything queued, with their mode and area. A refresh is
               what the panel does; a full-screen one is the expensive, visible one.
  * paints     how many top-level widgets were repainted into the framebuffer
               (CPU cost: a repaint walks the whole widget tree).
  * decodes    how many times a cover image was decoded and scaled
               (RenderImage:renderImageData), the costliest single CPU step.

install() must run BEFORE ui/uimanager is first required: UIManager captures
Screen.refreshUI etc. into a table at load time, so wrapping later sees nothing.

    local probe = emu.probe
    probe:reset()
    ... drive the screen ...
    local s = probe:snapshot()   -- s.refreshes, s.area_screens, s.full, s.paints, s.decodes
]]

local Probe = {}
Probe.__index = Probe

local MODES = { "refreshA2", "refreshFast", "refreshUI", "refreshPartial", "refreshNoMergeUI",
  "refreshNoMergePartial", "refreshFlashUI", "refreshFlashPartial", "refreshFull" }

function Probe.install(Screen)
  local self = setmetatable({}, Probe)
  self.Screen = Screen
  self:reset()
  for _, name in ipairs(MODES) do
    local orig = Screen[name]
    if orig then
      Screen[name] = function(s, x, y, w, h, ...)
        local W, H = Screen:getWidth(), Screen:getHeight()
        w = w or W
        h = h or H
        self.log[#self.log + 1] = { mode = (name:gsub("^refresh", "")), x = x or 0, y = y or 0, w = w, h = h,
          full = (w * h) >= 0.95 * W * H }
        return orig(s, x, y, w, h, ...)
      end
    end
  end
  return self
end

-- called once UIManager exists
function Probe:hook(UIManager)
  if self.hooked then return end
  self.hooked = true
  local orig_repaint = UIManager._repaint
  UIManager._repaint = function(um, ...)
    for widget in pairs(um._dirty) do
      self.paints[#self.paints + 1] = widget.name or tostring(widget)
    end
    return orig_repaint(um, ...)
  end
  local RenderImage = require("ui/renderimage")
  local orig_render = RenderImage.renderImageData
  RenderImage.renderImageData = function(r, ...)
    self.decodes = self.decodes + 1
    return orig_render(r, ...)
  end
end

function Probe:reset()
  self.log = {}
  self.paints = {}
  self.decodes = 0
  self.t0 = os.clock()
end

function Probe:snapshot()
  local W, H = self.Screen:getWidth(), self.Screen:getHeight()
  local area, full, flashes = 0, 0, 0
  for _, r in ipairs(self.log) do
    area = area + r.w * r.h
    if r.full then full = full + 1 end
    if r.mode:find("Flash") or r.mode == "Full" then flashes = flashes + 1 end
  end
  return {
    refreshes = #self.log,
    full = full,                          -- refreshes covering (nearly) the whole panel
    flashes = flashes,                    -- refreshes in a flashing mode (full, flashui, flashpartial)
    area_screens = area / (W * H),        -- summed refreshed area, in screens
    paints = #self.paints,
    decodes = self.decodes,
    cpu = os.clock() - self.t0,           -- desktop CPU seconds: relative only
    log = self.log,
  }
end

function Probe:report(label)
  local s = self:snapshot()
  print(string.format("  probe %-34s refreshes=%d (full=%d, flashing=%d) area=%.2f screens  paints=%d  decodes=%d",
    label, s.refreshes, s.full, s.flashes, s.area_screens, s.paints, s.decodes))
  return s
end

return Probe
