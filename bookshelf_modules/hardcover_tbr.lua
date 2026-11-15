-- Cover-led rediscovery from the saved Hardcover Want to Read shelf.
local MODULE_DIR = ...
local _ = require("gettext")
local Kit = require("lib/bookshelf_module_kit")
if not Kit.plugin then return {} end
local M = require("hardcover/lib/bookshelf_modules")
return {
  key = "hardcover_tbr",
  title = _("Hardcover TBR rediscovery"),
  summary = _("Older books still on Want to Read. Works offline after loading the shelf."),
  min_w = 2, min_h = 2,
  render = function(ctx) return M.discoveryWidget(M.app(MODULE_DIR), ctx, "tbr") end,
  keep_open = M.discoveryKeepOpen,
  on_tap = function(ctx) M.discoveryTap(M.app(MODULE_DIR), ctx, "tbr") end,
  show_settings = function(ctx) M.cardSettings(M.app(MODULE_DIR), ctx, "tbr") end,
}
