-- Search field (MMD): a pill 48 tall with a leading magnifier (20, touch 28), the words in full Black
-- (the placeholder too: MMD keeps it black so it never rests on grey) and, once there is a query and a
-- `on_clear` to go with it, a clear X (28, touch 48) at the end. A fixed width, so nothing moves when
-- the query changes.
--
-- KOReader types into its own box, so the field does not take keys itself: tapping it calls `on_tap`
-- (the caller opens the input with the current query) and the X calls `on_clear`.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")

local Draw = require("hardcover/lib/ui/components/draw")
local TapRow = require("hardcover/lib/ui/tap_row")
local Theme = require("hardcover/lib/ui/theme")

local BLACK = Blitbuffer.COLOR_BLACK

local SearchField = {}

SearchField.HEIGHT = Theme.mmd.search.h

-- What the field shows for `query`: the query, or the placeholder when there is none; and whether
-- there is something to clear.
function SearchField.content(query, placeholder)
  local has_query = type(query) == "string" and query:match("%S") ~= nil
  return has_query and query or placeholder or "", has_query
end

-- opts { width, query, placeholder, on_tap(query), on_clear, viewport }
function SearchField.new(opts)
  local m = Theme.mmd.search
  local w, h = opts.width, m.h
  local shown, has_query = SearchField.content(opts.query, opts.placeholder)
  local border = Theme.line.firm

  -- a clear X only where there is a query and a handler for it: a button that does nothing is a lie
  local clearable = has_query and opts.on_clear ~= nil
  local clear_w = clearable and m.clear_touch or 0
  local left_w = w - 2 * border - clear_w
  local side = Theme.px(14)
  local icon_cell = CenterContainer:new { dimen = Geom:new { w = m.icon_touch, h = h - 2 * border },
    Draw.icon("search", m.icon) }
  local text = Theme.mmdText(shown, "text", 21,
    { width = left_w - side - m.icon_touch - Theme.px(8), color = BLACK })
  local left = TapRow:new {
    callback = function() if opts.on_tap then opts.on_tap(has_query and opts.query or "") end end,
    viewport = opts.viewport,
    LeftContainer:new { dimen = Geom:new { w = left_w, h = h - 2 * border },
      HorizontalGroup:new { align = "center", Theme.hspan(side), icon_cell, Theme.hspan(Theme.px(8)), text } },
  }
  local row = HorizontalGroup:new { align = "center", left }
  local clear
  if clearable then
    clear = TapRow:new {
      callback = function() if opts.on_clear then opts.on_clear() end end,
      viewport = opts.viewport,
      CenterContainer:new { dimen = Geom:new { w = m.clear_touch, h = h - 2 * border },
        Draw.icon("close", m.clear) },
    }
    row[#row + 1] = clear
  end
  local box = Theme.box(w, h, row, { round = true, border = border })
  box.field_button, box.clear_button, box.shown = left, clear, shown
  return box
end

return SearchField
