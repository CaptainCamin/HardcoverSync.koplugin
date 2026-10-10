-- font_install: copies the shipped Lato files into the fonts folder once, leaves what is already
-- there alone, repairs a partial copy, and never throws when the folder cannot be written.
--
-- Run with:  lua spec/font_install_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()

local FontInstall = dofile(PLUGIN .. "/hardcover/lib/font_install.lua")

local base = os.tmpname()
os.remove(base)
local source, target = base .. "_src", base .. "_dst"
os.execute(("mkdir -p '%s' '%s'"):format(source, target))

local function write(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end
local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

write(source .. "/Lato-Medium.ttf", string.rep("M", 1000))
write(source .. "/Lato-Black.ttf", string.rep("B", 2000))
write(source .. "/OFL.txt", "licence")

r.check("the first run copies both fonts and the licence",
  FontInstall.run { source = source, target = target } == 3)
r.check("the files are byte for byte the shipped ones",
  read(target .. "/Lato-Medium.ttf") == string.rep("M", 1000) and read(target .. "/Lato-Black.ttf") == string.rep("B", 2000))
r.check("the licence travels with them, under a name the font scan ignores",
  read(target .. "/Lato-OFL.txt") == "licence")
r.check("a second run copies nothing", FontInstall.run { source = source, target = target } == 0)

write(target .. "/Lato-Black.ttf", "half")
r.check("a file of the wrong size is replaced", FontInstall.run { source = source, target = target } == 1
  and read(target .. "/Lato-Black.ttf") == string.rep("B", 2000))
r.check("no temporary file is left behind", read(target .. "/Lato-Black.ttf.part") == nil)

r.check("an unwritable fonts folder copies nothing and does not throw",
  select(2, pcall(FontInstall.run, { source = source, target = base .. "_missing" })) == 0)
r.check("a missing source copies nothing and does not throw",
  select(2, pcall(FontInstall.run, { source = base .. "_nowhere", target = target })) == 0)

os.execute(("rm -rf '%s' '%s'"):format(source, target))
r.finish()
