-- The year as twelve bars, for Bookshelf's start menu and hero grid.
--
-- Pages per month (or books, where no edition has a page count), from the stats
-- already saved on the device, with the month still counting drawn hollow. A
-- module pack file (Bookshelf's micromodules/README.md).
local MODULE_DIR = ...

local _ = require("gettext")
local Kit = require("lib/bookshelf_module_kit")

-- Kit.plugin arrived in Bookshelf 6.1.0. Older Bookshelf cannot reach the
-- plugin, so offer nothing rather than a card whose tap does nothing.
if not Kit.plugin then return {} end

local M = require("hardcover/lib/bookshelf_modules")

local function app()
  local ok, instance = pcall(Kit.plugin, MODULE_DIR)
  return ok and instance or nil
end

return {
  key = "hardcover_year",
  title = _("Hardcover year in bars"),
  summary = _("Pages a month this year, as twelve bars. Works offline."),
  min_w = 2,
  render = function(ctx)
    return M.yearWidget(app(), ctx)
  end,
  on_tap = function(ctx)
    M.cardTap(app(), ctx, "showStats")
  end,
  show_settings = function(ctx) M.cardSettings(app(), ctx, "year") end,
}
