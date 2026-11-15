-- This year's finished books, as a Bookshelf start-menu module.
--
-- A module pack file (Bookshelf's micromodules/README.md); the card and its
-- stats maths live in the plugin, shared with the Stats screen.
local MODULE_DIR = ...

local _ = require("gettext")
local Kit = require("lib/bookshelf_module_kit")

-- Kit.plugin arrived in Bookshelf 6.1.0. Older Bookshelf cannot reach the
-- plugin, so offer nothing rather than a card whose tap does nothing.
if not Kit.plugin then return {} end

local M = require("hardcover/lib/bookshelf_modules")

return {
  key = "hardcover_stats",
  title = _("Hardcover stats"),
  summary = _("Books finished this year. Works offline."),
  min_w = 2,
  render = function(ctx)
    return M.statsWidget(M.app(MODULE_DIR), ctx)
  end,
  on_tap = function(ctx)
    M.cardTap(M.app(MODULE_DIR), ctx, "showStats")
  end,
  show_settings = function(ctx) M.cardSettings(M.app(MODULE_DIR), ctx, "stats") end,
}
