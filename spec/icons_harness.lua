-- The bundled icons are loaded by file path, so a typo or a bad file shows up on the
-- device as KOReader's "icon not found" glyph, with no error. Check the files here.
--
-- Run with:  lua spec/icons_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local failed, passed = 0, 0

local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print("  ok   " .. name)
  else failed = failed + 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end

local listing = io.popen('ls "' .. PLUGIN .. '/icons" 2>/dev/null')
local names = {}
for line in listing:lines() do
  if line:match("%.svg$") then names[#names + 1] = line end
end
listing:close()

check("there are bundled icons", function()
  assert(#names > 0, "icons/ is empty or missing")
end)

for _, file in ipairs(names) do
  check(file .. " is a 24x24 stroked black SVG", function()
    local f = assert(io.open(PLUGIN .. "/icons/" .. file, "rb"))
    local body = f:read("*a")
    f:close()
    assert(body:match("^<svg[^>]*viewBox=\"0 0 24 24\""), "needs viewBox 0 0 24 24")
    assert(body:find("</svg>", 1, true), "not closed")
    assert(not body:find("currentColor", 1, true), "currentColor does not render in KOReader; use #000000")
    assert(body:find("#000000", 1, true), "should draw in black")
    assert(not body:find("<script", 1, true), "no scripts")
  end)
end

check("every icon the plugin names exists", function()
  local present = {}
  for _, n in ipairs(names) do present[n:gsub("%.svg$", "")] = true end
  -- the set the design system documents
  for _, want in ipairs({ "home", "shelves", "goals", "search", "settings", "close", "back",
    "chevron-right", "check", "plus", "star", "star-filled", "star-half", "book",
    "book-open", "bookmark", "sync", "offline", "sort", "link", "trash" }) do
    assert(present[want], "missing icon: " .. want)
  end
end)

print("")
print(string.format("  %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
