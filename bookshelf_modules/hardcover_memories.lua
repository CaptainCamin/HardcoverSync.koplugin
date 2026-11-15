-- Date-led reading memories from this month in earlier years.
local MODULE_DIR = ...
local _ = require("gettext")
local Kit = require("lib/bookshelf_module_kit")
if not Kit.plugin then return {} end
local M = require("hardcover/lib/bookshelf_modules")
return {
  key = "hardcover_memories",
  title = _("Hardcover reading memories"),
  summary = _("This month in your reading past. Works offline after loading Stats."),
  min_w = 2, min_h = 2,
  render = function(ctx) return M.discoveryWidget(M.app(MODULE_DIR), ctx, "memories") end,
  keep_open = M.discoveryKeepOpen,
  on_tap = function(ctx) M.discoveryTap(M.app(MODULE_DIR), ctx, "memories") end,
  show_settings = function(ctx) M.cardSettings(M.app(MODULE_DIR), ctx, "memories") end,
}
