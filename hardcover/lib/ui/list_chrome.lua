-- The chrome around a cover list (the shelf, search results): the title bar is a
-- ListHeader (the family's title bar and a row of buttons), so what is left to restyle
-- is the footer.
--
-- Menu builds "Page 1 of 4" as a plain regular-weight Button unless it is
-- handed one, so this hands it one in the family's small bold type. Tapping or
-- holding it opens a "Go to page" box with a number keyboard: Go jumps to that
-- page (clamped to the list's pages), Cancel closes the box. The box only jumps
-- pages, so it takes no text or letters.

local Button = require("ui/widget/button")
local T = require("ffi/util").template
local _ = require("gettext")

local Theme = require("hardcover/lib/ui/theme")

local ListChrome = {}

--
-- Menu options to merge into the options a list is built with. `get_menu` is a
-- function returning the menu once it exists (the hold box asks it for the page
-- count when it opens, which is long after construction).
--
function ListChrome.options(get_menu)
  -- declared first: the buttons below close over it, and a local is not in
  -- scope inside its own initialiser
  local page_info_text
  page_info_text = Button:new {
    text = "",
    text_font_face = "cfont",
    text_font_size = Theme.type.small + 1,
    text_font_bold = true,
    bordersize = 0,
    call_hold_input_on_tap = true,
    hold_input = {
      title = _("Go to page"),
      input_type = "number",
      hint_func = function()
        local menu = get_menu()
        return T(_("1 - %1"), menu and menu.page_num or 1)
      end,
      buttons = {
        {
          {
            text = _("Cancel"),
            id = "close",
            callback = function()
              page_info_text:closeInputDialog()
            end,
          },
          {
            text = _("Go"),
            is_enter_default = true,
            callback = function()
              -- onInput stores the box on the button it was opened from
              local n = tonumber(page_info_text.input_dialog:getInputText())
              -- nothing typed, or not a whole number: leave the box open
              if not n or n ~= math.floor(n) then return end
              local menu = get_menu()
              if menu then
                menu:onGotoPage(math.max(1, math.min(n, menu.page_num)))
              end
              page_info_text:closeInputDialog()
            end,
          },
        },
      },
    },
  }
  return { page_info_text = page_info_text }
end

return ListChrome
