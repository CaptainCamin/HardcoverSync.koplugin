-- Lints for bugs a test might not reach: a global that is read but never defined (a typo, or a missing
-- require) and a global written by accident. Style findings are off on purpose: unused variables and
-- arguments, shadowing and line length are 250 findings across the plugin today, and a gate that fails
-- on them would be fought, not read. To see everything: luacheck . --no-config --std luajit
std = "luajit+koreader"

-- What KOReader provides: G_reader_settings is its global settings object, and its LuaJIT is built with
-- Lua 5.2 compatibility (table.pack, table.unpack), which a stock LuaJIT lacks. The harnesses run on a
-- stock one, which is why the two helpers that use them (debounce, throttle) are barely covered.
stds.koreader = {
  read_globals = {
    "G_reader_settings",
    table = { fields = { "pack", "unpack" } },
  },
}

exclude_files = { ".lua/**", ".luarocks/**", ".claude/**", "spec/emu/.home/**", "spec/emu/.out/**" }

ignore = {
  "21[123]", -- unused variable, argument, loop variable
  "2[234].", -- variable never set, never accessed, mutated but never accessed
  "311",     -- value assigned to a variable is unused
  "321",     -- reading a local that was declared without a value (`failure = failure or err`)
  "41[1-3]", -- redefining a local, argument, or loop variable
  "42[1-3]", -- shadowing a definition
  "43[1-3]", -- shadowing an upvalue
  "512",     -- loop executed at most once
  "542",     -- empty if branch
  "6.*",     -- whitespace and line length
}

-- The harnesses stub KOReader: they shim table.unpack/pack for a stock LuaJIT, replace library functions
-- and set globals on purpose. The Busted specs get Busted's own globals.
files["spec/**"] = { globals = { "table", "G_defaults", "G_reader_settings", "_", "clock", "utf8", "os" } }
files["spec/lib/*_spec.lua"] = { std = "luajit+koreader+busted" }
