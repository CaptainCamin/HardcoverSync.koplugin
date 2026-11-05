-- Each finished book with a current five-star rating counts once.
local MODULE_DIR = ...
local _ = require("gettext")
local Kit = require("lib/bookshelf_module_kit")
if not Kit.plugin then return {} end
local M = require("hardcover/lib/bookshelf_modules")
local function app()
  local ok, instance = pcall(Kit.plugin, MODULE_DIR)
  return ok and instance or nil
end
return {
  key = "hardcover_five_star",
  title = _("Hardcover five-star books"),
  summary = _("Finished books you rated five stars. Works offline after loading Stats."),
  aspect = "square", min_w = 1,
  render = function(ctx) return M.totalWidget(app(), ctx, "five_star") end,
  on_tap = function(ctx) M.cardTap(app(), ctx, "showStats") end,
  show_settings = function(ctx) M.cardSettings(app(), ctx, "five_star") end,
}
