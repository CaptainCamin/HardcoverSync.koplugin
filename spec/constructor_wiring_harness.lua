-- Every field a class reads from `self` must be supplied by whoever builds it.
--
-- hardcover_menu.lua calls self.on_flush_sync_queue() and self.wifi:wifiPrompt(),
-- but main.lua built the menu without either. Nothing failed until a user tapped
-- "Sync now" -- or any wifi-gated item with wifi off -- and KOReader crashed with
-- "attempt to call field 'on_flush_sync_queue' (a nil value)". The other
-- harnesses build the menu themselves and hand it whatever it needs, so none of
-- them could see the gap in main.lua.
--
-- This reads the source rather than running it: for each class built with a
-- `Class:new { ... }` table in main.lua, it collects every `self.field` the
-- class's file reads, drops the ones the file assigns itself (`self.x = ...`)
-- and the class's own methods, and requires the rest to appear in that table.
--
-- Run with:  lua spec/constructor_wiring_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local function read(path)
  local f = assert(io.open(PLUGIN .. "/" .. path, "r"), "cannot open " .. path)
  local s = f:read("*a")
  f:close()
  return s
end

-- strip comments and string literals so a word in a comment is not a read
local function strip(src)
  src = src:gsub("%-%-%[%[.-%]%]", "")
  src = src:gsub("%-%-[^\n]*", "")
  src = src:gsub('"[^"\n]*"', '""'):gsub("'[^'\n]*'", "''")
  return src
end

-- fields supplied in `Name:new { ... }` (top-level keys of that table)
local function supplied(main_src, ctor)
  local start = main_src:find(ctor .. ":new%s*{")
  if not start then return nil end
  local body_start = main_src:find("{", start, true)
  local depth, i = 0, body_start
  local fields = {}
  while i <= #main_src do
    local c = main_src:sub(i, i)
    if c == "{" or c == "(" then depth = depth + 1
    elseif c == "}" or c == ")" then
      depth = depth - 1
      if depth == 0 then break end
    elseif depth == 1 then
      -- a key sits at depth 1, at the start of a line
      local line_start = main_src:sub(1, i - 1):match("[^\n]*$")
      if line_start:match("^%s*$") then
        local name = main_src:match("^([%w_]+)%s*=[^=]", i)
        if name then fields[name] = true end
      end
    end
    i = i + 1
  end
  return fields
end

local main_src = strip(read("main.lua"))

local function check_class(label, path, ctor, opts)
  opts = opts or {}
  local src = strip(read(path))
  local methods, assigned, reads = {}, {}, {}
  for name in src:gmatch("function%s+[%w_]+[:%.]([%w_]+)%s*%(") do methods[name] = true end
  for name in src:gmatch("self%.([%w_]+)%s*=[^=]") do assigned[name] = true end
  for name in src:gmatch("self%.([%w_]+)") do reads[name] = true end

  local given = supplied(main_src, ctor)
  r.check(label .. ": constructor call found in main.lua", given ~= nil)
  if not given then return end

  local missing = {}
  for name in pairs(reads) do
    if not methods[name] and not assigned[name] and not given[name] and not (opts.ignore or {})[name] then
      missing[#missing + 1] = name
    end
  end
  table.sort(missing)
  r.check(label .. ": every field it reads is supplied", #missing == 0,
    "main.lua does not pass: " .. table.concat(missing, ", "))
end

print("\n== constructor wiring ==")
check_class("HardcoverMenu", "hardcover/lib/ui/hardcover_menu.lua", "HardcoverMenu")
check_class("DialogManager", "hardcover/lib/ui/dialog_manager.lua", "DialogManager")
check_class("Hardcover", "hardcover/lib/hardcover.lua", "Hardcover")
check_class("Cache", "hardcover/lib/cache.lua", "Cache")

r.finish()
