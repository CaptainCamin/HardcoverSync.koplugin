-- Every plugin widget that is closed must leave an e-ink refresh queued.
--
-- KOReader's UIManager:close() repaints the widgets underneath into the
-- framebuffer, but it only tells the panel to refresh if a refresh mode was
-- queued: UIManager:_refresh() returns immediately when it has no mode ("most
-- likely from a show or close that wasn't passed specific refresh details"),
-- and close() passes none. Stock widgets queue their own refresh from
-- onCloseWidget(), which close() fires. A widget without one closes silently:
-- the screen keeps showing the dialog until something else happens to refresh
-- that region -- the "menu closed but the screen did not update" symptom.
--
-- This models that rule. UIManager.close() here runs the widget's
-- onCloseWidget (as the real one does through handleEvent) and records only
-- refreshes that carry a mode. Each close path of each widget is then driven.
--
-- Widgets that contain a stock Menu (the search and shelf dialogs) are left
-- out: Menu:onCloseWidget queues the refresh for them, and this harness does
-- not model event propagation to children.
--
-- Run with:  lua spec/close_refresh_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

-- A permissive stand-in for any KOReader module: every index, call and
-- arithmetic operation yields another stand-in, so a module can be loaded to
-- get at its class table without building real widgets. Fresh table each time,
-- so two widget classes never share (and overwrite) each other's methods.
local function make()
  local t = {}
  return setmetatable(t, {
    __index = function() return make() end,
    __call = function() return make() end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
  })
end

local refreshes = {}
local function record(rt)
  local mode = rt
  if type(rt) == "function" then
    local ok, m = pcall(rt)
    mode = ok and m or nil
  end
  if mode then refreshes[#refreshes + 1] = mode end
end

local stack = {}
package.preload["ui/uimanager"] = function()
  return {
    show = function(_, widget) stack[#stack + 1] = widget end,
    scheduleIn = function() end,
    unschedule = function() end,
    nextTick = function() end,
    setDirty = function(_, _, refresh_type) record(refresh_type) end,
    isWidgetShown = function(_, widget)
      for _, w in ipairs(stack) do if w == widget then return true end end
      return false
    end,
    close = function(_, widget, refresh_type)
      for i = #stack, 1, -1 do
        if stack[i] == widget then table.remove(stack, i) end
      end
      if widget and widget.onCloseWidget then widget:onCloseWidget() end
      record(refresh_type) -- nil here, as in the plugin: the real one drops it
    end,
  }
end
package.preload["hardcover_version"] = function() return { "0", "0", "0", "spec" } end
-- A real identity gettext, not the permissive stand-in: string.format("%s", x)
-- accepts a table under LuaJIT but errors under plain Lua 5.1 (which CI uses).
package.preload["gettext"] = function()
  return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["logger"] = function()
  return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end

local real_require = require
_G.require = function(name)
  if name:match("^hardcover/") or package.preload[name] or package.loaded[name] then
    return real_require(name)
  end
  return make()
end

local function check(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end

-- An instance whose methods come from the class table only, so a missing
-- onCloseWidget is nil rather than the permissive stand-in's fake.
local function instance(class, fields)
  local o = fields or {}
  return setmetatable(o, { __index = function(_, k) return rawget(class, k) end })
end

local function drive(class_path, label, fields_fn, method, ...)
  local class = real_require(class_path)
  local args = { ... }
  check(label, function()
    refreshes = {}
    local inst = instance(class, fields_fn())
    local fn = rawget(class, method)
    if not fn then error(method .. " is not defined") end
    fn(inst, unpack(args))
    if #refreshes == 0 then
      error("closed without queueing a refresh; the panel keeps showing it")
    end
  end)
end

print("\n== closing a widget queues a refresh ==")

local function detail() return { frame = { dimen = {} } } end
drive("hardcover/lib/ui/book_detail_dialog", "book detail: onClose", detail, "onClose")
drive("hardcover/lib/ui/book_detail_dialog", "book detail: onCloseDetail", detail, "onCloseDetail")

local function home() return { cover_halt = function() end } end
drive("hardcover/lib/ui/home_dialog", "home: onClose", home, "onClose")
drive("hardcover/lib/ui/home_dialog", "home: onCloseWidget", home, "onCloseWidget")

local function signin() return { auth = make(), device = {}, frame = { dimen = {} } } end
drive("hardcover/lib/ui/signin_dialog", "sign in: cancel", signin, "onCancel")
drive("hardcover/lib/ui/signin_dialog", "sign in: success", signin, "onSuccess")
drive("hardcover/lib/ui/signin_dialog", "sign in: declined or expired", signin, "onFinish", "declined")

-- UpdateDoubleSpinWidget is not listed: it extends KOReader's DoubleSpinWidget,
-- which defines onClose and onCloseWidget, and this harness does not model
-- inheritance from KOReader classes.

print("\n== replacing a dialog does not leave the old one on the stack ==")

local DialogManager = real_require("hardcover/lib/ui/dialog_manager")
real_require("hardcover/lib/user").getId = function() return 1 end
real_require("hardcover/lib/hardcover_api").getShelfAsync = function() end

local function manager()
  stack = {}
  return setmetatable({ settings = { compatibilityMode = function() return false end } },
    { __index = DialogManager })
end

local function twice(label, build)
  check(label, function()
    local dm = manager()
    build(dm)
    build(dm)
    local mine = 0
    for _, w in ipairs(stack) do
      if w == dm.search_dialog or w == dm.shelf_dialog then mine = mine + 1 end
    end
    -- anything else on the stack is a loading message, which is not under test
    local dead = 0
    for _, w in ipairs(stack) do
      if w ~= dm.search_dialog and w ~= dm.shelf_dialog and rawget(w, "__dialog") then dead = dead + 1 end
    end
    if mine ~= 1 then error(mine .. " live dialogs on the stack, expected 1") end
    if dead ~= 0 then error(dead .. " replaced dialog(s) left on the stack") end
  end)
end

-- Tag what the dialog classes produce so a leftover is recognisable.
for _, path in ipairs({ "hardcover/lib/ui/search_dialog", "hardcover/lib/ui/shelf_dialog" }) do
  local class = real_require(path)
  class.new = function(_, o) o = o or {}; o.__dialog = true; o.free = function() end; return o end
end

twice("retrying a loading search dialog", function(dm)
  dm:buildLoadingSearchDialog("t", function() end, nil, function() end)
end)
twice("rebuilding a search dialog", function(dm)
  dm:buildSearchDialog("t", {}, nil, function() end, nil, "")
end)
twice("retrying the shelf", function(dm)
  dm:showShelf(1, "t")
end)

r.finish()
