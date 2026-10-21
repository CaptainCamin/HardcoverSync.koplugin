-- Feedback after something the reader did is a snackbar (via StatusDialogs.info); only a system
-- event keeps KOReader's plain toast. MMD: a snackbar follows a user action, never the system alone.
--
-- A source check, because main.lua and dialog_manager.lua cannot be loaded without a device.
--
-- Run with:  luajit spec/snackbar_feedback_harness.lua [plugin-root]

local ROOT = arg[1] or "."
package.path = ROOT .. "/spec/?.lua;" .. package.path
local r = require("support").reporter()

local function read(path)
  local f = assert(io.open(ROOT .. "/" .. path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local main = read("main.lua")
local dm = read("hardcover/lib/ui/dialog_manager.lua")

local function has(src, text) return src:find(text, 1, true) ~= nil end

r.check("link book (user action) is a snackbar", has(main, 'StatusDialogs.info(_("Linked to: " .. book.title))'))
r.check("tracking on is a snackbar", has(main, 'StatusDialogs.info(_("Progress tracking enabled"))'))
r.check("tracking off is a snackbar", has(main, 'StatusDialogs.info(_("Progress tracking disabled"))'))
r.check("manual progress update is a snackbar", has(main, "StatusDialogs.info(text)"))
r.check("queued goal change is a snackbar", has(dm, 'StatusDialogs.info(notice or _("Saved on this device'))
r.check("goal archived is a snackbar", has(dm, "StatusDialogs.info(GoalActions.archivedNotice(goal.id, false))"))
r.check("dialog_manager shows no KOReader toast", not has(dm, "ui/widget/notification"))

-- the one toast left in main.lua is the background book-fetch failure
local _, n = main:gsub("Notification:new", "")
r.check("main.lua keeps exactly one toast, for the background fetch failure",
  n == 1 and has(main, "Failed to fetch book information from Hardcover"))

-- notices and questions are the plugin's own Snackbar and Dialog, not KOReader's InfoMessage and ConfirmBox
-- (the scan progress message in hardcover_menu.lua is the one InfoMessage left)
local menu = read("hardcover/lib/ui/hardcover_menu.lua")
local sources = read("hardcover/lib/bookshelf_sources.lua")
r.check("no ConfirmBox in the menu", not has(menu, "ui/widget/confirmbox"))
r.check("no InfoMessage in bookshelf_sources or dialog_manager",
  not has(sources, "ui/widget/infomessage") and not has(dm, "ui/widget/infomessage"))
local _, menu_infos = menu:gsub("ui/widget/infomessage", "")
r.check("hardcover_menu.lua keeps one InfoMessage, for the scan progress", menu_infos == 1)

r.finish()
