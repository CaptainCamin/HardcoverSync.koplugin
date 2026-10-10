-- A paragraph cut to a number of lines, with an ellipsis, and whether it was cut.
--
-- A block on a screen that is a fixed size (a book's About, a review) must be the same height
-- whatever the text, so long text is clamped and a Read more opens the rest on a screen of its own.
-- Lines are worked out with the real font: the text is laid out once at full length to count them.

local TextBoxWidget = require("ui/widget/textboxwidget")

local Clamp = {}

-- opts { text, face, width, lines, fgcolor, bold }. Returns the widget and `cut` (true when the text
-- is longer than `lines`, so a Read more is owed).
function Clamp.text(opts)
  local full = TextBoxWidget:new {
    text = opts.text, face = opts.face, width = opts.width, bold = opts.bold,
    alignment = "left", fgcolor = opts.fgcolor,
  }
  local count = #(full.vertical_string_list or {})
  local line_h = full.line_height_px or opts.face.size
  if count <= opts.lines then return full, false end
  full:free()
  return TextBoxWidget:new {
    text = opts.text, face = opts.face, width = opts.width, bold = opts.bold,
    alignment = "left", fgcolor = opts.fgcolor,
    height = opts.lines * line_h, height_adjust = true, height_overflow_show_ellipsis = true,
  }, true
end

return Clamp
