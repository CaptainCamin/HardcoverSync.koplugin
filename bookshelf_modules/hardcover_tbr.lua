-- Cover-led rediscovery from the saved Hardcover Want to Read shelf.
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
  key = "hardcover_tbr",
  title = _("Hardcover TBR rediscovery"),
  summary = _("Older books still on Want to Read. Works offline after loading the shelf."),
  min_w = 2, min_h = 2,
  render = function(ctx) return M.discoveryWidget(app(), ctx, "tbr") end,
  keep_open = function(ctx) return ctx.tapped_region == "another" end,
  on_tap = function(ctx) M.discoveryTap(app(), ctx, "tbr") end,
}
