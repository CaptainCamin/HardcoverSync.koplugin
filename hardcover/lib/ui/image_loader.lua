local logger = require("logger")
local getUrlContent = require("hardcover/vendor/url_content")
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

local Batch = {}
Batch.__index = Batch

function Batch:new(o)
  return setmetatable(o or {}, self)
end

-- Cached images cost no network and no subprocess, so they are delivered on
-- the next tick; only a real download waits between requests.
local CACHED_DELAY = nil
local FETCH_DELAY = 0.05

function Batch:loadImages(urls)
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

    local url = table.remove(url_queue, 1)

    local cached = cache and cache:get(url)
    if cached then
      self.callback(url, cached)
      schedule_next(CACHED_DELAY)
      return
    end

    Trapper:wrap(function()
      if stop_loading then return end

      local completed, success, content = Trapper:dismissableRunInSubprocess(function()
        return getUrlContent(url, 10, 30)
      end)

      if completed and success then
        if cache then cache:put(url, content) end
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

function ImageLoader:loadImages(urls, callback)
  local batch = Batch:new()
  batch.callback = callback
  local halt = batch:loadImages(urls)
  return batch, halt
end

return ImageLoader
