-- Puts the plugin's Lato fonts where KOReader finds them.
--
-- KOReader looks for a font by file name first in its own fonts folder (`./fonts` from the KOReader
-- directory, FontList.fontdir) and so finds a file copied there at once, with no restart; it only
-- shows up in the reader's font menu after the next start, since that list is scanned once per
-- process. Two weights ship: Lato Medium (body) and Lato Black (emphasis), unmodified, with the SIL
-- Open Font License alongside (the licence asks that it travels with the fonts).
--
-- Nothing here may throw: a read-only fonts folder or a missing source file leaves the plugin on
-- KOReader's own font (Theme.mmdText falls back when the face is missing).

local FontInstall = {}

FontInstall.FILES = { "Lato-Medium.ttf", "Lato-Black.ttf" }
FontInstall.LICENCE = "OFL.txt"
FontInstall.LICENCE_AS = "Lato-OFL.txt" -- not a font, so KOReader's font scan ignores it

-- the plugin folder this file was loaded from, up to and including its trailing slash
local plugin_root = (debug.getinfo(1, "S").source or ""):match("^@(.-)hardcover/lib/font_install%.lua$") or ""

local function size_of(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:close()
  return size
end

-- Copies `from` to `to` through a temporary name, so a copy cut short (a power loss, a full disk)
-- never leaves a half file that looks installed. True on success.
local function copy(from, to)
  local src = io.open(from, "rb")
  if not src then return false end
  local data = src:read("*a")
  src:close()
  local tmp = to .. ".part"
  local dst = io.open(tmp, "wb")
  if not dst then return false end
  local ok = dst:write(data)
  dst:close()
  if not ok or size_of(tmp) ~= #data then
    os.remove(tmp)
    return false
  end
  os.remove(to)
  if not os.rename(tmp, to) then
    os.remove(tmp)
    return false
  end
  return true
end

-- opts { source (folder holding the shipped files; default <plugin>/fonts), target (folder to put
-- them in; default KOReader's own fonts folder) }. Returns the number of files copied this time.
function FontInstall.run(opts)
  opts = opts or {}
  local source = opts.source or (plugin_root .. "fonts")
  local target = opts.target
  if not target then
    local ok, FontList = pcall(require, "fontlist")
    target = ok and FontList and FontList.fontdir or "./fonts"
  end
  local copied = 0
  local function put(name, as)
    local from, to = source .. "/" .. name, target .. "/" .. (as or name)
    local want = size_of(from)
    if not want or size_of(to) == want then return end
    if copy(from, to) then copied = copied + 1 end
  end
  for _, name in ipairs(FontInstall.FILES) do put(name) end
  put(FontInstall.LICENCE, FontInstall.LICENCE_AS)
  return copied
end

return FontInstall
