-- The cover boxes of a screen that lays out many covers (Home, Lists): a box of
-- its final size with the generic book icon in it until the picture arrives, so
-- nothing moves when it does.
--
-- Three things this owns, because doing them per screen had each screen doing them
-- slightly differently and none of them cheaply:
--
--   * Decoding. Decoding and scaling a cover is the costliest step on a weak CPU,
--     and a screen that rebuilds itself (Home does, as its data arrives) used to
--     throw every picture away and decode it again. Decoded pictures are kept
--     across rebuilds of the same screen, keyed by (url, size); a box asks for
--     one with the same url and size and gets it at once, with no placeholder
--     flash and no loader round trip. Whatever the new layout no longer shows is
--     freed when the pass ends. One decode serves every box of that url and size.
--   * Refreshing. A picture arriving refreshes its own box, not the panel.
--   * Memory. Every picture is freed when the screen releases it.
--
-- Usage, from a screen's build():
--
--     self.covers:begin()
--     ... self.covers:cell(url, w, h) wherever a cover goes ...
--     self.covers:finish()      -- frees what is no longer shown, asks for the rest
--
-- and from its close handler: self.covers:release().

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")

local Refresh = require("hardcover/lib/ui/refresh")
local Theme = require("hardcover/lib/ui/theme")

local CoverCells = {}
CoverCells.__index = CoverCells

--
-- opts:
--   window   the screen (what is repainted and refreshed)
--   loader   function() -> something with loadImages(urls, callback) -> batch, halt
--   clip     function() -> the rectangle that is visible (a scroll area), or nil
--
function CoverCells:new(opts)
  local o = setmetatable(opts or {}, self)
  o.cells = {}   -- url -> { { cell, w, h }, ... } still showing the placeholder
  o.bbs = {}     -- key -> decoded picture, in use by the current layout
  o.prev = {}    -- key -> decoded picture from the layout before this pass
  return o
end

local function key(url, w, h)
  return url .. "|" .. w .. "x" .. h
end

local function show(cell, bb, w, h)
  local old = cell[1]
  cell[1] = CenterContainer:new {
    dimen = Geom:new { w = w, h = h },
    ImageWidget:new {
      image = bb,
      -- the picture is shared by every box of its size and freed by this module
      image_disposable = false,
      width = w,
      height = h,
      -- fit inside the box keeping the proportions
      scale_factor = 0,
    },
  }
  if old and type(old.free) == "function" then pcall(old.free, old) end
end

-- Start laying out: pictures from the last layout stay available to be reused.
function CoverCells:begin()
  for k, bb in pairs(self.bbs) do
    self.prev[k] = bb
  end
  self.bbs = {}
  self.cells = {}
  self:halt()
end

-- A box of the given size for this cover (a plain box when there is no url).
function CoverCells:cell(url, w, h)
  local icon_size = math.floor(w * 0.5)
  local cell = FrameContainer:new {
    bordersize = Theme.line.hair,
    padding = 0,
    margin = 0,
    CenterContainer:new {
      dimen = Geom:new { w = w, h = h },
      IconWidget:new { icon = "book.opened", width = icon_size, height = icon_size },
    },
  }
  if not url or url == "" then return cell end

  local k = key(url, w, h)
  local kept = self.bbs[k] or self.prev[k]
  if kept then
    self.prev[k] = nil
    self.bbs[k] = kept
    show(cell, kept, w, h)
  else
    self.cells[url] = self.cells[url] or {}
    table.insert(self.cells[url], { cell = cell, w = w, h = h })
  end
  return cell
end

-- The layout is done: free the pictures it does not show, and fetch the ones it lacks.
function CoverCells:finish()
  for k, bb in pairs(self.prev) do
    if bb.free then bb:free() end
  end
  self.prev = {}
  self:load()
end

function CoverCells:load()
  local urls = {}
  for url in pairs(self.cells) do urls[#urls + 1] = url end
  if #urls == 0 then return end
  table.sort(urls)

  local window = self.window
  local loader = self.loader()
  local _batch, halt = loader:loadImages(urls, function(url, content)
    if window.closed then return end
    local specs = self.cells and self.cells[url]
    if not specs then return end
    self.cells[url] = nil

    local RenderImage = require("ui/renderimage")
    for _i, spec in ipairs(specs) do
      local k = key(url, spec.w, spec.h)
      local bb = self.bbs[k]
      if not bb then
        bb = RenderImage:renderImageData(content, #content, false, spec.w, spec.h)
        if bb then self.bbs[k] = bb end
      end
      if bb then
        show(spec.cell, bb, spec.w, spec.h)
        local cell = spec.cell
        Refresh.box(window, function() return cell.dimen end, self.clip)
      end
    end
  end)
  self.halt_loading = halt
end

-- Stop fetching.
function CoverCells:halt()
  if self.halt_loading then
    self.halt_loading()
    self.halt_loading = nil
  end
end

-- The pictures in use, as a list.
function CoverCells:list()
  local out = {}
  for _k, bb in pairs(self.bbs) do out[#out + 1] = bb end
  return out
end

-- The screen is going away (or being rebuilt for good): stop and free everything.
function CoverCells:release()
  self:halt()
  for _k, bb in pairs(self.bbs) do
    if bb.free then bb:free() end
  end
  for _k, bb in pairs(self.prev) do
    if bb.free then bb:free() end
  end
  self.bbs, self.prev, self.cells = {}, {}, {}
end

return CoverCells
