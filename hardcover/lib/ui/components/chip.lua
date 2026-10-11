-- Chip (MMD): a short bold label in a rounded box, 2 border, radius 20, 14 either side. `selected` is
-- filled black with a white label (the active choice or the state that is on); otherwise outlined.
-- State rests on the fill, never on grey. 1 to 2 words, no wrapping: the label is cut with an ellipsis
-- at `width` rather than wrapped.
--
-- Used for state (a goal's "On track", a book's shelf). The plugin has no filter chips: the owner decided
-- the Library has no filters ("no chips"), so there is no filter, input or suggestion chip here. A chip
-- that acts would be wrapped in a TapRow by its caller, with a visible control beside it (no hold-only).

local FrameContainer = require("ui/widget/container/framecontainer")

local Theme = require("hardcover/lib/ui/theme")

local Chip = {}

-- opts { label, selected, size (default Theme.mmd.chip.text), width (cut the label here) }
function Chip.new(opts)
  local m = Theme.mmd.chip
  local label = Theme.mmdText(opts.label, "strong", opts.size or m.text,
    { color = opts.selected and Theme.WHITE or Theme.BLACK,
      width = opts.width and (opts.width - 2 * (m.border + m.pad)) or nil })
  return FrameContainer:new {
    bordersize = m.border, radius = m.radius, color = Theme.BLACK,
    background = opts.selected and Theme.BLACK or Theme.WHITE,
    padding = m.pad_y, padding_left = m.pad, padding_right = m.pad, margin = 0,
    label,
  }
end

return Chip
