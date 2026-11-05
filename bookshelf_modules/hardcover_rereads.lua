-- Additional completed reads, not the number of books reread.
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
  key = "hardcover_rereads",
  title = _("Hardcover rereads"),
  summary = _("Completed reads after the first, all time. Works offline after loading Stats."),
  aspect = "square", min_w = 1,
  render = function(ctx) return M.totalWidget(app(), ctx, "rereads") end,
  on_tap = function(ctx) M.cardTap(app(), ctx, "showStats") end,
  show_settings = function(ctx) M.cardSettings(app(), ctx, "rereads") end,
}
