-- The Hardcover reading goal as a completion ring, for Bookshelf's start menu.
--
-- The same goal and the same goal maths as hardcover_goal.lua, drawn as a ring
-- with the percentage inside it. A module pack file (Bookshelf's
-- micromodules/README.md); both cards can sit on the shelf at once, each pinned
-- to its own goal from its own settings.
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
  key = "hardcover_goal_ring",
  title = _("Hardcover goal ring"),
  summary = _("Your reading goal as a completion ring. Works offline."),
  -- One cell is enough: the card drops to the ring and its percentage when the
  -- cell is too short for a name, so the reader can shrink it to a tile.
  min_w = 1,
  render = function(ctx)
    return M.goalRingWidget(app(), ctx)
  end,
  on_tap = function()
    M.openScreen(app(), "showGoals")
  end,
  -- Long press -> Module settings: which running goal this ring shows.
  show_settings = function(ctx)
    M.goalSettings(app(), ctx)
  end,
}