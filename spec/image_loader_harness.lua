-- Proves the cover cache and loader: what is cached is served without a
-- download, duplicates are fetched once, an empty batch does not crash, and a
-- halted batch stops delivering.
--
-- Run with:  lua spec/image_loader_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local support = dofile(PLUGIN .. "/spec/support.lua")
local r = support.reporter()
local check = function(label, fn)
  local ok, err = pcall(fn)
  r.check(label, ok, err)
end
local function expect(cond, msg) if not cond then error(msg or "expectation failed", 2) end end

-- a throwaway directory and an in-memory clock standing in for lfs
local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p '" .. dir .. "'")

local clock = 0
local mtimes = {}
local fake_lfs = {
  attributes = function(path, what)
    if what == "mode" then
      local f = io.open(path .. "/.", "r")
      if f then f:close() return "directory" end
      return nil
    end
    return mtimes[path]
  end,
  touch = function(path) clock = clock + 1; mtimes[path] = clock end,
  dir = function(d)
    local names = {}
    local p = io.popen("ls '" .. d .. "'")
    for line in p:lines() do names[#names + 1] = line end
    p:close()
    local i = 0
    return function() i = i + 1; return names[i] end
  end,
}
local function hash(s) return (s:gsub("[^%w]", "_")) end

local ImageCache = dofile(PLUGIN .. "/hardcover/lib/image_cache.lua")
local function new_cache(max)
  return ImageCache:new { dir = dir, lfs = fake_lfs, hash = hash, max_files = max,
    make_dir = function() return true end }
end

print("\n== image cache ==")

check("a stored image comes back byte for byte", function()
  local c = new_cache()
  expect(c:put("http://x/a.jpg", "\0\1binary\255"), "put failed")
  expect(c:get("http://x/a.jpg") == "\0\1binary\255", "round trip changed the data")
end)

check("a miss returns nil", function()
  expect(new_cache():get("http://x/never.jpg") == nil)
end)

check("empty content is not cached", function()
  local c = new_cache()
  expect(c:put("http://x/empty.jpg", "") == false)
  expect(c:get("http://x/empty.jpg") == nil)
end)

check("an unusable cache (no hash) fails soft", function()
  local c = ImageCache:new { dir = dir }
  expect(c:put("u", "data") == false)
  expect(c:get("u") == nil)
end)

check("no temp file is left behind", function()
  local p = io.popen("ls '" .. dir .. "' | grep -c tmp")
  local n = tonumber(p:read("*a")); p:close()
  expect(n == 0, n .. " .tmp files")
end)

check("prune drops the least recently used beyond the cap", function()
  os.execute("rm -f '" .. dir .. "'/*")
  mtimes = {}
  local c = new_cache(2)
  for _, name in ipairs({ "a", "b", "c" }) do
    c:put("http://x/" .. name, name)
    clock = clock + 1
    mtimes[c:path("http://x/" .. name)] = clock
  end
  c:get("http://x/a") -- a is now the most recent
  c:prune()
  expect(c:get("http://x/b") == nil, "oldest (b) should be gone")
  expect(c:get("http://x/a") == "a" and c:get("http://x/c") == "c", "newer files must survive")
end)

print("\n== image loader ==")

local ticks, scheduled = {}, {}
package.preload["logger"] = function() return { dbg = function() end, warn = function() end } end
package.preload["ui/uimanager"] = function()
  return {
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
    scheduleIn = function(_, _, fn) scheduled[#scheduled + 1] = fn end,
    unschedule = function() ticks = {}; scheduled = {} end,
  }
end
local fetched = {}
local fail_urls = {}
package.preload["ui/trapper"] = function()
  return {
    wrap = function(_, fn) fn() end,
    dismissableRunInSubprocess = function(_, fn) return true, fn() end,
  }
end
package.preload["hardcover/vendor/url_content"] = function()
  return function(url)
    fetched[#fetched + 1] = url
    if fail_urls[url] then return false, "boom" end
    return true, "IMG:" .. url
  end
end

local ImageLoader = dofile(PLUGIN .. "/hardcover/lib/ui/image_loader.lua")

local function drain()
  local guard = 0
  while (#ticks > 0 or #scheduled > 0) and guard < 1000 do
    guard = guard + 1
    local fn = table.remove(#ticks > 0 and ticks or scheduled, 1)
    fn()
  end
end

local function reset()
  os.execute("rm -f '" .. dir .. "'/*")
  mtimes = {}; ticks = {}; scheduled = {}; fetched = {}; fail_urls = {}
  ImageLoader.cache = new_cache()
end

check("every url is delivered once, in order", function()
  reset()
  local got = {}
  ImageLoader:loadImages({ "u1", "u2", "u3" }, function(url, content) got[#got + 1] = url .. "=" .. content end)
  drain()
  expect(table.concat(got, ",") == "u1=IMG:u1,u2=IMG:u2,u3=IMG:u3", table.concat(got, ","))
end)

check("duplicate urls are downloaded and delivered once", function()
  reset()
  local n = 0
  ImageLoader:loadImages({ "u1", "u1", "u1" }, function() n = n + 1 end)
  drain()
  expect(#fetched == 1 and n == 1, "fetched " .. #fetched .. ", delivered " .. n)
end)

check("an empty batch does not crash or fetch", function()
  reset()
  local _, halt = ImageLoader:loadImages({}, function() error("no delivery expected") end)
  drain()
  expect(#fetched == 0 and type(halt) == "function")
end)

check("a second batch for the same urls uses the cache, not the network", function()
  reset()
  ImageLoader:loadImages({ "u1", "u2" }, function() end)
  drain()
  fetched = {}
  local got = {}
  ImageLoader:loadImages({ "u1", "u2" }, function(url, content) got[#got + 1] = content end)
  drain()
  expect(#fetched == 0, "downloaded again: " .. table.concat(fetched, ","))
  expect(#got == 2 and got[1] == "IMG:u1", "cached content not delivered")
end)

check("a failed download does not stop the rest or get cached", function()
  reset()
  fail_urls["u1"] = true
  local got = {}
  ImageLoader:loadImages({ "u1", "u2" }, function(url) got[#got + 1] = url end)
  drain()
  expect(#got == 1 and got[1] == "u2", table.concat(got, ","))
  expect(ImageLoader.cache:get("u1") == nil, "failure was cached")
end)

check("halting stops further delivery", function()
  reset()
  local got = {}
  local _, halt = ImageLoader:loadImages({ "u1", "u2", "u3" }, function(url) got[#got + 1] = url end)
  local first = table.remove(ticks, 1)
  first()
  halt()
  drain()
  expect(#got == 1, "delivered " .. #got .. " after halt")
end)

check("offline: cached covers are served, the rest are skipped without a download", function()
  reset()
  ImageLoader.cache:put("u1", "CACHED1")
  local original = ImageLoader.isOnline
  ImageLoader.isOnline = function() return false end
  local got = {}
  ImageLoader:loadImages({ "u1", "u2", "u3" }, function(url, content) got[#got + 1] = url .. "=" .. content end)
  drain()
  ImageLoader.isOnline = original
  assert(#fetched == 0, "tried to download while offline: " .. table.concat(fetched, ","))
  assert(table.concat(got, ",") == "u1=CACHED1", table.concat(got, ","))
  assert(not ImageLoader:isLoading(), "the batch never finished")
end)

check("works with no cache at all", function()
  reset()
  ImageLoader.cache = false
  local n = 0
  ImageLoader:loadImages({ "u1", "u2" }, function() n = n + 1 end)
  drain()
  expect(n == 2)
end)

os.execute("rm -rf '" .. dir .. "'")
r.finish()
