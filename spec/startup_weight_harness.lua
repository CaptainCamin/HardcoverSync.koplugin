-- Keeps heavy screens out of plugin startup.
--
-- KOReader loads this plugin on every start, so everything main.lua requires at
-- the top level is parsed whether or not the user ever opens the screen. The
-- search, shelf, book detail, journal and sign-in dialogs pull in the vendored
-- ListMenu and CoverMenu (about 1,500 lines) and are only needed on demand.
--
-- This walks the top-level `local X = require("hardcover/...")` graph from
-- main.lua, the same way Lua would load it, and fails if a heavy module is
-- reachable. A require inside a function body is indented, so it is ignored.
--
-- Run with:  lua spec/startup_weight_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local HEAVY = {
  "hardcover/vendor/listmenu",
  "hardcover/vendor/covermenu",
  "hardcover/lib/ui/search_menu",
  "hardcover/lib/ui/search_dialog",
  "hardcover/lib/ui/shelf_dialog",
  "hardcover/lib/ui/book_detail_dialog",
  "hardcover/lib/ui/journal_dialog",
  "hardcover/lib/ui/signin_dialog",
  "hardcover/lib/ui/update_double_spin_widget",
  "hardcover/lib/ui/image_loader",
  -- the screens built later: each pulls in the theme and a pile of widgets
  "hardcover/lib/ui/home_dialog",
  "hardcover/lib/ui/lists_dialog",
  "hardcover/lib/ui/reviews_dialog",
  "hardcover/lib/ui/settings_dialog",
  "hardcover/lib/ui/reader_panel",
  "hardcover/lib/ui/series_carousel",
  "hardcover/lib/ui/cover_cells",
  "hardcover/lib/ui/refresh",
  "hardcover/lib/ui/theme",
}

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- module -> the module that first pulled it in
local loaded, order = { ["main"] = "(root)" }, {}

local function walk(name, path)
  local src = read(path)
  if not src then return end
  -- top-level only: the line starts at column 0
  for line in src:gmatch("[^\n]+") do
    local mod = line:match('^local%s+[%w_]+%s*=%s*require%("(hardcover/[^"]+)"%)')
    if mod and not loaded[mod] then
      loaded[mod] = name
      order[#order + 1] = mod
      walk(mod, PLUGIN .. "/" .. mod .. ".lua")
    end
  end
end

walk("main", PLUGIN .. "/main.lua")

print("\n== modules loaded at startup ==")
print("  " .. #order .. " plugin modules reachable from main.lua")

for _, heavy in ipairs(HEAVY) do
  local via = loaded[heavy]
  r.check(heavy .. " is not loaded at startup", via == nil,
    via and ("required by " .. via .. " at top level; require it where it is used") or nil)
end

r.finish()
