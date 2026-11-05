-- The Hardcover reading goal, as a Bookshelf start-menu module.
--
-- This is a module pack file (Bookshelf's micromodules/README.md): Bookshelf
-- scans every installed plugin for a bookshelf_modules/ folder and loads each
-- file in it. The card and its goal maths live in the plugin, so the card and
-- the Goals screen can never disagree; this file is only the spec.
local MODULE_DIR = ...

local _ = require("gettext")
local Kit = require("lib/bookshelf_module_kit")

-- Kit.plugin arrived in Bookshelf 6.1.0. Older Bookshelf cannot reach the
-- plugin, so offer nothing rather than a card whose tap does nothing.
if not Kit.plugin then return {} end

local M = require("hardcover/lib/bookshelf_modules")

local function app()
  local ok, instance = pcall(Kit.plugin, MODULE_DIR)
  return ok and instance or nil
end

return {
  key = "hardcover_goal",
  title = _("Hardcover goal"),
  summary = _("Your current reading goal. Works offline."),
  min_w = 2,
  render = function(ctx)
    return M.goalWidget(app(), ctx)
  end,
  on_tap = function(ctx)
    M.cardTap(app(), ctx, "showGoals")
  end,
  -- Long press -> Module settings: which running goal this card shows.
  show_settings = function(ctx)
    M.cardSettings(app(), ctx, "goal")
  end,
}
