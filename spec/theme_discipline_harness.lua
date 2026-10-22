-- "Use Theme.*" ratchet. CLAUDE.md says new or changed UI takes its sizes, colours and fonts from
-- hardcover/lib/ui/theme.lua; this makes the rule checkable.
--
-- It reads source text, which spec/README.md calls a last resort. That is deliberate here and limited
-- to this one rule: the thing being checked is "which tokens the code names", and no stubbed widget
-- run can see that. Do not copy the approach for behaviour.
--
-- Every hardcover/lib/ui/**/*.lua file except theme.lua is scanned for the patterns below. The counts
-- found today are committed in spec/theme_discipline_allow.lua. A count that goes up fails (a new
-- offender, or a new use in an old file) and so does one that goes down without the allowlist being
-- lowered, so the list can only shrink. Chart files are allowlisted: the grey policy for charts is an
-- open decision (docs/e-ink-design.md).
--
-- To refresh the allowlist after fixing offenders:
--   THEME_ALLOW_PRINT=1 lua spec/theme_discipline_harness.lua   (paste the output over the table)
--
-- Run with:  lua spec/theme_discipline_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
local support = dofile(PLUGIN .. "/spec/support.lua")
local allow = dofile(PLUGIN .. "/spec/theme_discipline_allow.lua")
local r = support.reporter()

-- name -> { Lua pattern, what to use instead }
local PATTERNS = {
  scaleBySize = { "scaleBySize", "Theme.px(n), or a Theme.space / Theme.TOUCH_MIN / Theme.BUTTON_H token" },
  Size = { "Size%.[%a_]+%.?[%a_]*", "Theme.space.*, Theme.line.* or Theme.margin (KOReader's Size is not scaled the same)" },
  getFace = { "getFace", "Theme.type.* (or Theme.text / Theme.title)" },
  hex = { "%f[%w_]0x%x%x%f[^%x]", "Theme.BLACK, Theme.DARK_GREY, Theme.secondary() or Theme.hatch" },
  color = { "Blitbuffer%.COLOR_[%u_%d]+", "Theme.BLACK, Theme.WHITE or Theme.DARK_GREY" },
}
local NAMES = { "scaleBySize", "Size", "getFace", "hex", "color" }

local function list_files()
  local files = {}
  local p = io.popen('find "' .. PLUGIN .. '/hardcover/lib/ui" -name "*.lua" -type f 2>/dev/null | sort')
  for line in p:lines() do
    local rel = line:sub(#PLUGIN + 2)
    if rel ~= "hardcover/lib/ui/theme.lua" then files[#files + 1] = rel end
  end
  p:close()
  return files
end

-- Counts per pattern, and the line of the first few hits for the failure message.
local function scan(rel)
  local counts, hits = {}, {}
  local f = assert(io.open(PLUGIN .. "/" .. rel, "rb"))
  local n = 0
  for line in f:lines() do
    n = n + 1
    local code = line:gsub("%-%-.*$", "")        -- crude: comments are not code
    for _, name in ipairs(NAMES) do
      for _ in code:gmatch(PATTERNS[name][1]) do
        counts[name] = (counts[name] or 0) + 1
        hits[name] = hits[name] or {}
        hits[name][#hits[name] + 1] = n
      end
    end
  end
  f:close()
  return counts, hits
end

local files = list_files()
local found = {}
r.check("the UI folder is found", #files > 10, "found " .. #files .. " files")

for _, rel in ipairs(files) do
  local counts, hits = scan(rel)
  found[rel] = counts
  local allowed = allow[rel] or {}
  for _, name in ipairs(NAMES) do
    local have, want = counts[name] or 0, allowed[name] or 0
    if have > want then
      r.check(rel .. " " .. name, false, string.format(
        "%d use(s) at line %s, %d allowed. Use %s", have, table.concat(hits[name], ", "), want, PATTERNS[name][2]))
    elseif have < want then
      r.check(rel .. " " .. name, false, string.format(
        "only %d left, allowlist says %d: lower spec/theme_discipline_allow.lua (it can only shrink)", have, want))
    end
  end
end
for rel in pairs(allow) do
  local seen = false
  for _, f in ipairs(files) do if f == rel then seen = true end end
  if not seen then r.check(rel .. " is allowlisted", false, "file no longer exists: remove it from the allowlist") end
end
r.check("UI files follow the Theme.* ratchet", r.fail == 0)

if os.getenv("THEME_ALLOW_PRINT") then
  print("\nreturn {")
  for _, rel in ipairs(files) do
    local parts = {}
    for _, name in ipairs(NAMES) do
      if found[rel][name] then parts[#parts + 1] = name .. " = " .. found[rel][name] end
    end
    if #parts > 0 then print(string.format("  [%q] = { %s },", rel, table.concat(parts, ", "))) end
  end
  print("}")
end

r.finish()
