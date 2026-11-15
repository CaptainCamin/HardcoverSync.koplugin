-- The year as twelve bars, for Bookshelf's start menu and hero grid.
--
-- Books or pages per month, from the stats already saved on the device,
-- with the month still counting drawn hollow. A
-- module pack file (Bookshelf's micromodules/README.md).
local MODULE_DIR = ...

local _ = require("gettext")
local Kit = require("lib/bookshelf_module_kit")

-- Kit.plugin arrived in Bookshelf 6.1.0. Older Bookshelf cannot reach the
-- plugin, so offer nothing rather than a card whose tap does nothing.
if not Kit.plugin then return {} end

local M = require("hardcover/lib/bookshelf_modules")

return {
  key = "hardcover_year",
  title = _("Hardcover year in bars"),
  summary = _("Books or pages a month, as columns or stacked rows. Works offline."),
  min_w = 2,
  render = function(ctx)
    return M.yearWidget(M.app(MODULE_DIR), ctx)
  end,
  on_tap = function(ctx)
    M.cardTap(M.app(MODULE_DIR), ctx, "showStats")
  end,
  show_settings = function(ctx) M.cardSettings(M.app(MODULE_DIR), ctx, "year") end,
}
