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

-- How much space covers that were only seen may take. At the size they are now fetched
-- (covers.lua: 20-40 KB each) that is well over a thousand covers; the full-size covers
-- earlier versions saved (up to 3 MB each) are the first to go when it is full.
-- `max_bytes = false` keeps everything (the covers downloaded for offline).
ImageCache.DEFAULT_MAX_BYTES = 30 * 1024 * 1024

function ImageCache:new(o)
  o = o or {}
  if o.max_bytes == nil and o.max_files == nil then o.max_bytes = ImageCache.DEFAULT_MAX_BYTES end
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

-- Is the cover saved? (No read, no touch: for counting what is missing.)
function ImageCache:has(url)
  local path = self:path(url)
  if not path then return false end
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

-- Touch a cached image and return its path without reading the image bytes.
-- Used by Bookshelf, which owns decoding and the rendered cover lifetime.
function ImageCache:touch(url)
  local path = self:path(url)
  if not path then return nil end
  local file = io.open(path, "rb")
  if not file then return nil end
  file:close()
  if self.lfs and self.lfs.touch then pcall(self.lfs.touch, path) end
  return path
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

-- Delete the least recently used files beyond max_files, or beyond max_bytes in all.
function ImageCache:prune()
  if not (self.max_files or self.max_bytes) then return end
  if not (self.lfs and self.lfs.dir and self.dir) then return end

  local entries, total = {}, 0
  local ok = pcall(function()
    for name in self.lfs.dir(self.dir) do
      if name:match("%.img$") then
        local path = self.dir .. "/" .. name
        local mtime = self.lfs.attributes(path, "modification")
        if mtime then
          local size = tonumber(self.lfs.attributes(path, "size")) or 0
          total = total + size
          table.insert(entries, { path = path, mtime = mtime, size = size })
        end
      end
    end
  end)
  if not ok then return end

  table.sort(entries, function(a, b) return a.mtime < b.mtime end)
  local count = #entries
  for _, entry in ipairs(entries) do
    local over_count = self.max_files and count > self.max_files
    local over_bytes = self.max_bytes and total > self.max_bytes
    if not (over_count or over_bytes) then break end
    os.remove(entry.path)
    count = count - 1
    total = total - entry.size
  end
end

return ImageCache
