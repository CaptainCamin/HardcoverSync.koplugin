-- The chrome around a cover list (the shelf, search results): the title bar the
-- Menu builds is already the family's (title centred, icon at the left, X at
-- the right), so what is left to restyle is the footer.
--
-- Menu builds "Page 1 of 4" as a plain regular-weight Button unless it is
-- handed one, so this hands it one in the family's small bold type. Everything
-- the stock button does is kept: tapping it does nothing, holding it opens the
-- "go to page" box (the same hold_input table Menu would have made).

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
  local page_info_text = Button:new {
    text = "",
    text_font_face = "cfont",
    text_font_size = Theme.type.small + 1,
    text_font_bold = true,
    bordersize = 0,
    call_hold_input_on_tap = true,
    hold_input = {
      title = _("Enter text, letter or page number"),
      input_func = function()
        local menu = get_menu()
        return menu and menu.search_index and menu.search_string
      end,
      hint_func = function()
        local menu = get_menu()
        return T(_("(a - z) or (1 - %1)"), menu and menu.page_num or 1)
      end,
      buttons = { { { text = _("Search"), callback = function() end } } },
    },
  }
  return { page_info_text = page_info_text }
end

return ListChrome
