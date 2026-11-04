-- Books finished at least once, including books now being reread.
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
  key = "hardcover_books_read",
  title = _("Hardcover books read"),
  summary = _("Distinct books finished, all time. Works offline after loading Stats."),
  aspect = "square", min_w = 1,
  render = function(ctx) return M.totalWidget(app(), ctx, "books") end,
  on_tap = function() M.openScreen(app(), "showStats") end,
}
