-- Lifetime totals from Hardcover, not the device's reading history.
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
  key = "hardcover_authors",
  title = _("Hardcover authors read"),
  summary = _("Distinct authors of books you finished. Works offline after loading Stats."),
  aspect = "square", min_w = 1,
  render = function(ctx) return M.totalWidget(app(), ctx, "authors") end,
  on_tap = function() M.openScreen(app(), "showStats") end,
}
