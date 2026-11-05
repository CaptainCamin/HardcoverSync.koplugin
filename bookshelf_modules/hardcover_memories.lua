-- Date-led reading memories from this month in earlier years.
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
  key = "hardcover_memories",
  title = _("Hardcover reading memories"),
  summary = _("This month in your reading past. Works offline after loading Stats."),
  min_w = 2, min_h = 2,
  render = function(ctx) return M.discoveryWidget(app(), ctx, "memories") end,
  keep_open = M.discoveryKeepOpen,
  on_tap = function(ctx) M.discoveryTap(app(), ctx, "memories") end,
  show_settings = function(ctx) M.cardSettings(app(), ctx, "memories") end,
}
