-- On-disk cache of downloaded cover images, keyed by URL.
--
-- Covers are fetched one at a time in a subprocess, which is the slow part of
-- every shelf and search screen. Anything already on disk skips both the
-- subprocess and the network.
--
-- Dependencies (lfs, a hash function, the directory) are injected so this runs
-- under stock Lua in the harness. Every operation is best-effort: a cache that
-- cannot read or write must never break the screen that asked for it.

local ImageCache = {}
ImageCache.__index = ImageCache

local DEFAULT_MAX_FILES = 300

function ImageCache:new(o)
  o = o or {}
  o.max_files = o.max_files or DEFAULT_MAX_FILES
  o.writes_since_prune = 0
  return setmetatable(o, self)
end

-- nil when the cache is unusable (no hash function, no directory)
function ImageCache:path(url)
  if not (self.dir and self.hash and url and url ~= "") then
    return nil
  end
  return self.dir .. "/" .. self.hash(url) .. ".img"
end

function ImageCache:get(url)
  local path = self:path(url)
  if not path then return nil end

  local file = io.open(path, "rb")
  if not file then return nil end
  local content = file:read("*a")
  file:close()

  if not content or content == "" then return nil end

  -- refresh the mtime so pruning drops what was used least recently
  if self.lfs and self.lfs.touch then
    pcall(self.lfs.touch, path)
  end
  return content
end

function ImageCache:put(url, content)
  local path = self:path(url)
  if not path or type(content) ~= "string" or content == "" then
    return false
  end

  if self.lfs and self.lfs.attributes and not self.lfs.attributes(self.dir, "mode") then
    if not (self.make_dir and self.make_dir(self.dir)) then
      return false
    end
  end

  -- write then rename, so a crash mid-write never leaves a truncated image
  -- that a later get() would hand to the renderer
  local tmp = path .. ".tmp"
  local file = io.open(tmp, "wb")
  if not file then return false end
  local ok = file:write(content)
  file:close()
  if not ok or not os.rename(tmp, path) then
    os.remove(tmp)
    return false
  end

  self.writes_since_prune = self.writes_since_prune + 1
  if self.writes_since_prune >= 20 then
    self.writes_since_prune = 0
    self:prune()
  end
  return true
end

-- Delete the least recently used files beyond max_files.
function ImageCache:prune()
  if not (self.lfs and self.lfs.dir and self.dir) then return end

  local entries = {}
  local ok = pcall(function()
    for name in self.lfs.dir(self.dir) do
      if name:match("%.img$") then
        local path = self.dir .. "/" .. name
        local mtime = self.lfs.attributes(path, "modification")
        if mtime then
          table.insert(entries, { path = path, mtime = mtime })
        end
      end
    end
  end)
  if not ok or #entries <= self.max_files then return end

  table.sort(entries, function(a, b) return a.mtime < b.mtime end)
  for i = 1, #entries - self.max_files do
    os.remove(entries[i].path)
  end
end

return ImageCache
