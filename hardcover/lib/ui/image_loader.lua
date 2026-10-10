local logger = require("logger")
local getUrlContent = require("hardcover/vendor/url_content")
local Covers = require("hardcover/lib/covers")
local ImageCache = require("hardcover/lib/image_cache")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")

local ImageLoader = {}

function ImageLoader:isLoading()
  return self.loading == true
end

-- Built on first use so requiring this module needs no KOReader runtime.
-- Tests assign ImageLoader.cache directly.
function ImageLoader:getCache()
  if self.cache == nil then
    local ok, cache = pcall(function()
      local DataStorage = require("datastorage")
      local lfs = require("libs/libkoreader-lfs")
      local sha2 = require("ffi/sha2")
      local util = require("util")
      return ImageCache:new {
        dir = DataStorage:getDataDir() .. "/cache/hardcover_covers",
        lfs = lfs,
        hash = sha2.md5,
        make_dir = function(dir) return util.makePath(dir) end,
      }
    end)
    -- false, not nil, so a failed setup is not retried on every batch
    self.cache = ok and cache or false
  end
  return self.cache or nil
end

-- The covers downloaded for offline (Settings > Download for offline): kept whatever
-- the space, apart from the covers only seen, which the cache's limit trims.
function ImageLoader:getPinned()
  if self.pinned == nil then
    local ok, cache = pcall(function()
      local DataStorage = require("datastorage")
      local lfs = require("libs/libkoreader-lfs")
      local sha2 = require("ffi/sha2")
      local util = require("util")
      return ImageCache:new {
        dir = DataStorage:getDataDir() .. "/cache/hardcover_covers_offline",
        lfs = lfs,
        hash = sha2.md5,
        max_bytes = false,
        make_dir = function(dir) return util.makePath(dir) end,
      }
    end)
    self.pinned = ok and cache or false
  end
  return self.pinned or nil
end

-- The screen's size, for the cover sizes (tests set ImageLoader.screen).
function ImageLoader:screenSize()
  if not self.screen then
    local ok, Device = pcall(require, "device")
    local screen = ok and type(Device) == "table" and Device.screen
    local w = screen and screen.getWidth and screen:getWidth()
    local h = screen and screen.getHeight and screen:getHeight()
    self.screen = { w = tonumber(w) or 0, h = tonumber(h) or 0 }
  end
  return self.screen.w, self.screen.h
end

-- Where cover `url` is downloaded from at `size` ("small", "large"): see covers.lua.
-- `box` (optional, { w, h }): the exact size to ask for, for a cover drawn in a box that
-- size. The saved copy is kept under this address, so it is found under it again.
function ImageLoader:fetchUrl(url, size, box)
  local w, h = self:screenSize()
  return Covers.url(url, size or "small", w, h, box)
end

-- A saved cover for `key`: downloaded for offline first, then seen.
function ImageLoader:lookup(key)
  if not key then return nil end
  local pinned = self:getPinned()
  local content = pinned and pinned:get(key)
  if content then return content end
  local cache = self:getCache()
  return cache and cache:get(key) or nil
end

-- Return the on-disk path for a cached cover without reading or decoding its
-- bytes. Bookshelf can load this path through its own cover cache, which gives
-- each painter an independently owned image instead of sharing a disposable
-- BlitBuffer between the shelf tile and the hero.
function ImageLoader:cachedPath(url, size)
  if type(url) ~= "string" or url == "" then return nil end
  local resized = self:fetchUrl(url, size or "small")
  local keys = { url }
  if resized and resized ~= url then keys = { resized, url } end
  for _, key in ipairs(keys) do
    local pinned = self:getPinned()
    local path = pinned and pinned:touch(key)
    if path then return path end
    local cache = self:getCache()
    path = cache and cache:touch(key)
    if path then return path end
  end
  return nil
end

--
-- Download cover `url` at `size` (and `box`, as fetchUrl takes it). Call from inside
-- Trapper:wrap. The resized cover; once more if it failed (the image service sometimes
-- answers a 502 the first time it makes a size); then the cover as uploaded. A download
-- cancelled by a tap (not completed) is respected: nothing more is tried. `background`:
-- not cancellable by a tap. `stopped()`: whether to give up between tries.
-- Returns completed, success, content, and the key it was downloaded as.
--
function ImageLoader:download(url, size, background, stopped, box)
  stopped = stopped or function() return false end
  local fetch = self:fetchUrl(url, size, box)
  local function get(from)
    return Trapper:dismissableRunInSubprocess(function()
      return getUrlContent(from, 10, 30)
    end, background and {} or nil)
  end
  local saved_as = fetch
  local completed, success, content = get(fetch)
  if completed and not success and not stopped() then
    completed, success, content = get(fetch)
  end
  if completed and not success and fetch ~= url and not stopped() then
    saved_as = url
    completed, success, content = get(url)
  end
  return completed, success, content, saved_as
end

-- Download cover `url` (small) for offline and keep it where the cover space's limit
-- does not reach. Never cancelled by a tap. Call from inside Trapper:wrap. True when kept.
function ImageLoader:keepForOffline(url, stopped)
  local pinned = self:getPinned()
  if not pinned then return false end
  local completed, success, content, saved_as = self:download(url, "small", true, stopped)
  return completed and success and pinned:put(saved_as, content) or false
end

-- A cover on the device from being seen, kept for offline as well. True when kept.
function ImageLoader:copyForOffline(key)
  local pinned, cache = self:getPinned(), self:getCache()
  local content = cache and cache:get(key)
  return content ~= nil and pinned ~= nil and pinned:put(key, content) or false
end

-- Overridable so tests need no network manager.
function ImageLoader:isOnline()
  local ok, NetworkManager = pcall(require, "ui/network/manager")
  if not ok then return true end
  return NetworkManager:isConnected()
end

local Batch = {}
Batch.__index = Batch

function Batch:new(o)
  return setmetatable(o or {}, self)
end

-- Cached images cost no network and no subprocess, so they are delivered on
-- the next tick; only a real download waits between requests.
local CACHED_DELAY = nil
local FETCH_DELAY = 0.05

function Batch:loadImages(urls, size, box)
  if self.loading then
    error("batch already in progress")
  end

  local url_queue = {}
  local seen = {}
  for _, url in ipairs(urls) do
    if url and url ~= "" and not seen[url] then
      seen[url] = true
      table.insert(url_queue, url)
    end
  end

  if #url_queue == 0 then
    return function() end
  end

  self.loading = true

  local cache = ImageLoader:getCache()
  local run_image
  local stop_loading = false

  local schedule_next = function(delay)
    if #url_queue > 0 then
      if delay then
        UIManager:scheduleIn(delay, run_image)
      else
        UIManager:nextTick(run_image)
      end
    else
      self.loading = false
    end
  end

  run_image = function()
    if stop_loading then return end

    -- `url` is the cover as the book has it, and the key the caller knows it by; `fetch`
    -- is where it is downloaded from at this size and box (covers.lua)
    local url = table.remove(url_queue, 1)
    local fetch = ImageLoader:fetchUrl(url, size, box)

    local cached = ImageLoader:lookup(fetch)
    if cached then
      self.callback(url, cached)
      schedule_next(CACHED_DELAY)
      return
    end

    -- Offline, a download can only fail, and each one waits out a timeout. Show what is
    -- saved at another size, or the full-size cover an earlier version kept; else skip.
    if not ImageLoader:isOnline() then
      local other = size == "large" and ImageLoader:lookup(ImageLoader:fetchUrl(url, "small")) or nil
      local saved = other or (fetch ~= url and ImageLoader:lookup(url)) or nil
      if saved then self.callback(url, saved) end
      schedule_next(CACHED_DELAY)
      return
    end

    -- downloaded for offline before the image service was used for it: as uploaded
    local pinned = ImageLoader:getPinned()
    local kept = fetch ~= url and pinned and pinned:get(url)
    if kept then
      self.callback(url, kept)
      schedule_next(CACHED_DELAY)
      return
    end

    Trapper:wrap(function()
      if stop_loading then return end

      local completed, success, content, saved_as = ImageLoader:download(url, size, false,
        function() return stop_loading end, box)

      if completed and success then
        if cache then cache:put(saved_as, content) end
        if not stop_loading then
          self.callback(url, content)
        end
      elseif completed then
        logger.dbg("HARDCOVER cover fetch failed", url, content)
      end

      if not stop_loading then
        schedule_next(FETCH_DELAY)
      end
    end)
  end

  UIManager:nextTick(run_image)

  return function()
    stop_loading = true
    self.loading = false
    UIManager:unschedule(run_image)
  end
end

-- `opts.size`: "small" (the default: rows, strips, cards) or "large" (a book's details).
-- `opts.box`: { w, h } for a cover drawn in a box of exactly that size (see fetchUrl);
-- nil for the size `opts.size` gives.
function ImageLoader:loadImages(urls, callback, opts)
  local batch = Batch:new()
  batch.callback = callback
  local halt = batch:loadImages(urls, opts and opts.size or "small", opts and opts.box)
  return batch, halt
end

return ImageLoader
