-- The plugin's choose-one dialog (the sort menu, the shelf picker): a stock
-- ButtonDialog, dressed in the family's type.
--
-- ButtonDialog is KOReader's own and cannot be restyled much, so this does what
-- it can: a bold centred title in the family's title size, every choice in body
-- size, the current one in bold (the callers add their own marker to its text),
-- and a width that is a share of the screen so the labels are not squeezed.

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")

local Theme = require("hardcover/lib/ui/theme")

local Picker = {}

--
-- opts: title, rows (a list of { text, callback, current, bold, id }; one button
-- per row, in order; an id lets setRow find it later), close_callback (when it is
-- dismissed by a tap outside it or Back; a row's own callback closes it itself).
--
function Picker.new(opts)
  local buttons = {}
  for _, row in ipairs(opts.rows or {}) do
    buttons[#buttons + 1] = { {
      text = row.text,
      callback = row.callback,
      font_size = Theme.type.body,
      font_bold = row.current or row.bold or false,
      id = row.id,
    } }
  end
  return ButtonDialog:new {
    title = opts.title,
    title_align = "center",
    title_face = (Theme.serif("title")),
    use_info_style = false, -- a bold title
    width_factor = 0.85,
    buttons = buttons,
    tap_close_callback = opts.close_callback,
  }
end

--
-- Change one row of a shown picker in place (its words, and whether it can be
-- tapped), without rebuilding the dialog: a choice that is being saved shows it
-- and cannot be tapped again until the answer is in.
--
function Picker.setRow(picker, id, text, enabled)
  local button = picker and picker.getButtonById and picker:getButtonById(id)
  if not button then return end
  button:setText(text, button.width)
  button:enableDisable(enabled ~= false)
  UIManager:setDirty(picker, "ui")
end

return Picker
