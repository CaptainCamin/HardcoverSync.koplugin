-- Hardcover cards for Bookshelf's micro-modules (a reading goal and your stats).
--
-- Bookshelf has no module registration call; it loads every spec file in
-- <settings>/bookshelf/micromodules/ (see its micromodules/README.md). install()
-- drops a small stub there that returns the specs below, so they stay in this
-- plugin and update with it. The stub is a no-op when the plugin is off.
--
-- Cards draw only what is already saved on the device (no network on render),
-- so they read the same offline. Open the Goals or Stats screen to refresh them.

local _ = require("gettext")
local logger = require("logger")

local Modules = {}

local app

function Modules.setApp(a) app = a end

-- ------------------------------------------------------------------ data

local function userId()
  local User = require("hardcover/lib/user")
  local SETTING = require("hardcover/lib/constants/settings")
  local ok, id = pcall(function() return User.settings and User.settings:readSetting(SETTING.USER_ID) end)
  return ok and id or nil
end

local function count(n, unit)
  n = math.floor(n + 0.5)
  if unit == "pages" then return n == 1 and _("1 page") or string.format(_("%d pages"), n) end
  return n == 1 and _("1 book") or string.format(_("%d books"), n)
end

-- The goal that ends soonest of those running now, as a card: nil when there is
-- no sign-in, no saved goals or none running.
function Modules.goalCard(shelf_cache, queue, user_id, finished_offline, today)
  if not (shelf_cache and user_id) then return nil, "signed_out" end
  local Goals = require("hardcover/lib/goals")
  local goals = shelf_cache:goals(user_id)
  if not goals then return nil, "no_data" end
  if queue and not queue:isEmpty() then goals = queue:apply(goals) end
  today = today or Goals.today()
  local goal = Goals.split(goals, today).current[1]
  if not goal then return nil, "no_goal" end

  local p = Goals.pace(goal, today, Goals.extra(goal, today, finished_offline))
  return {
    heading = goal.name,
    value = string.format("%d", math.floor(p.progress + 0.5)),
    suffix = " / " .. count(p.target, p.unit),
    fraction = p.fraction,
    sub = p.status,
    context = p.per_week_text,
  }
end

-- This year's finished books, from the saved stats.
function Modules.statsCard(shelf_cache, user_id, year)
  if not (shelf_cache and user_id) then return nil, "signed_out" end
  local saved = shelf_cache:stats(user_id)
  if not saved then return nil, "no_data" end
  local Stats = require("hardcover/lib/stats")
  year = year or tonumber(os.date("%Y"))
  local s = Stats.compute(saved.rows, { year = year })
  local sub = {}
  if s.pages > 0 then sub[#sub + 1] = string.format(_("%d pages"), s.pages) end
  if s.ratings.average then sub[#sub + 1] = string.format(_("%.1f average rating"), s.ratings.average) end
  return {
    heading = string.format(_("Finished in %d"), year),
    value = string.format("%d", s.books),
    suffix = " " .. (s.books == 1 and _("book") or _("books")),
    sub = #sub > 0 and table.concat(sub, " \194\183 ") or nil,
    context = s.best_month and string.format(_("Best month: %s (%d)"),
      os.date("%B", os.time { year = year, month = s.best_month.month, day = 1 }), s.best_month.count) or nil,
  }
end

-- ------------------------------------------------------------------ specs

local function empty(ctx, text)
  local Kit = require("lib/bookshelf_module_kit")
  return Kit.valueCard {
    width = ctx.width, scale_pct = ctx.scale,
    heading = "Hardcover", sub = text,
  }
end

local function draw(ctx, card, reason)
  if not card then
    local text = reason == "signed_out" and _("Sign in to Hardcover Sync.")
      or reason == "no_goal" and _("No current goal. Tap to set one.")
      or _("Open Hardcover once to load this.")
    return empty(ctx, text)
  end
  local Kit = require("lib/bookshelf_module_kit")
  local bar = card.fraction and Kit.progressBar {
    width = math.max(50, ctx.width), height = Kit.sc(ctx.scale)(6), fraction = card.fraction,
  } or nil
  return Kit.valueCard {
    width = ctx.width, scale_pct = ctx.scale,
    heading = card.heading, value = card.value, suffix = card.suffix,
    bar = bar, sub = card.sub, context = card.context,
  }
end

local function openScreen(name)
  return function()
    if app and app.dialog_manager then app.dialog_manager[name](app.dialog_manager) end
  end
end

Modules.specs = {
  hardcover_goal = {
    key = "hardcover_goal",
    title = _("Hardcover goal"),
    summary = _("From Hardcover Sync. Works offline."),
    render = function(ctx)
      if not app then return empty(ctx, _("Sign in to Hardcover Sync.")) end
      local queue, offline = app.goal_queue, app.dialog_manager and app.dialog_manager:finishedOffline() or 0
      return draw(ctx, Modules.goalCard(app.shelf_cache, queue, userId(), offline))
    end,
    on_tap = openScreen("showGoals"),
  },
  hardcover_stats = {
    key = "hardcover_stats",
    title = _("Hardcover stats"),
    summary = _("From Hardcover Sync. Works offline."),
    render = function(ctx)
      if not app then return empty(ctx, _("Sign in to Hardcover Sync.")) end
      return draw(ctx, Modules.statsCard(app.shelf_cache, userId()))
    end,
    on_tap = openScreen("showStats"),
  },
}

-- ------------------------------------------------------------------ install

local function stub(key)
  return table.concat({
    "-- Written by Hardcover Sync; rewritten on start. Delete to remove the card.",
    "local ok, M = pcall(require, \"hardcover/lib/bookshelf_modules\")",
    "return ok and M.specs[\"" .. key .. "\"] or nil",
    "",
  }, "\n")
end

local function readAll(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- Writes the stubs when Bookshelf is installed. Returns true if it did.
function Modules.install(a, dir)
  app = a or app
  if not dir then
    if not (app and app.ui and app.ui.bookshelf) then return false end
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok then return false end
    dir = DataStorage:getSettingsDir() .. "/bookshelf/micromodules"
  end
  local lfs = require("libs/libkoreader-lfs")
  local parent = dir:match("^(.*)/[^/]+$")
  for _i, d in ipairs({ parent, dir }) do
    if lfs.attributes(d, "mode") ~= "directory" then lfs.mkdir(d) end
  end

  local wrote = true
  for key in pairs(Modules.specs) do
    local path = dir .. "/" .. key .. ".lua"
    local want = stub(key)
    if readAll(path) ~= want then
      local f, err = io.open(path, "wb")
      if f then
        f:write(want)
        f:close()
      else
        logger.warn("Hardcover Bookshelf module not written:", key, tostring(err))
        wrote = false
      end
    end
  end
  return wrote
end

return Modules
