-- The plugin's choose-one dialog (the sort menu, the shelf picker): a stock
-- ButtonDialog, dressed in the family's type.
--
-- ButtonDialog is KOReader's own and cannot be restyled much, so this does what
-- it can: a bold centred title in the family's title size, every choice in body
-- size, the current one in bold (the callers add their own marker to its text),
-- and a width that is a share of the screen so the labels are not squeezed.

local ButtonDialog = require("ui/widget/buttondialog")

local Theme = require("hardcover/lib/ui/theme")

local Picker = {}

--
-- opts: title, rows (a list of { text, callback, current, bold }; one button
-- per row, in order).
--
function Picker.new(opts)
  local buttons = {}
  for _, row in ipairs(opts.rows or {}) do
    buttons[#buttons + 1] = { {
      text = row.text,
      callback = row.callback,
      font_size = Theme.type.body,
      font_bold = row.current or row.bold or false,
    } }
  end
  return ButtonDialog:new {
    title = opts.title,
    title_align = "center",
    title_face = Theme.face("title"),
    use_info_style = false, -- a bold title
    width_factor = 0.85,
    buttons = buttons,
  }
end

return Picker
