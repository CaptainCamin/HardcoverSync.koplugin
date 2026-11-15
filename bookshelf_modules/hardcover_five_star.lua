-- Each finished book with a current five-star rating counts once.
local MODULE_DIR = ...
local _ = require("gettext")
local Kit = require("lib/bookshelf_module_kit")
if not Kit.plugin then return {} end
local M = require("hardcover/lib/bookshelf_modules")
return {
  key = "hardcover_five_star",
  title = _("Hardcover five-star books"),
  summary = _("Finished books you rated five stars. Works offline after loading Stats."),
  aspect = "square", min_w = 1,
  render = function(ctx) return M.totalWidget(M.app(MODULE_DIR), ctx, "five_star") end,
  on_tap = function(ctx) M.cardTap(M.app(MODULE_DIR), ctx, "showStats") end,
  show_settings = function(ctx) M.cardSettings(M.app(MODULE_DIR), ctx, "five_star") end,
}
