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

local pinned_dir = dir .. "_pinned"
os.execute("mkdir -p '" .. pinned_dir .. "'")
local function reset()
  os.execute("rm -f '" .. dir .. "'/* '" .. pinned_dir .. "'/*")
  mtimes = {}; ticks = {}; scheduled = {}; fetched = {}; fail_urls = {}
  ImageLoader.cache = new_cache()
  ImageLoader.pinned = ImageCache:new { dir = pinned_dir, lfs = fake_lfs, hash = hash, max_bytes = false,
    make_dir = function() return true end }
  ImageLoader.screen = { w = 1200, h = 1600 }
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

print("\n== covers at the size they are drawn ==")

local Covers = dofile(PLUGIN .. "/hardcover/lib/covers.lua")
local COVER = "https://assets.hardcover.app/edition/32409522/5562a0b7-5a80-4b2e-b8a2-cc8f4780b904.png"

check("a cover on Hardcover's assets is asked for from the image service, as hardcover.app asks", function()
  local url = Covers.url(COVER, "small", 1200, 1600)
  expect(url == "https://production-img.hardcover.app/enlarge?height=360&type=jpeg&url="
    .. "https%3A%2F%2Fassets.hardcover.app%2Fedition%2F32409522%2F5562a0b7-5a80-4b2e-b8a2-cc8f4780b904.png&width=240", url)
  expect(Covers.original(url) == COVER, "the original does not come back out")
end)

check("sizes follow the screen, in steps, large for the details", function()
  local w, h = Covers.size("small", 1072, 1448)
  expect(w == 240 and h == 360, w .. "x" .. h)
  local lw = Covers.size("large", 1264, 1680)
  expect(lw == 480, "large " .. lw)
  expect(Covers.size("small", 1448, 1072) == w, "turning the device changed the size")
  expect(Covers.size("small", 0, 0) > 0, "an unknown screen gave no size")
end)

check("a cover elsewhere, or not a URL, is left as it is", function()
  expect(Covers.url("https://example.com/c.jpg", "small", 1200, 1600) == "https://example.com/c.jpg")
  expect(Covers.url(nil, "small", 1, 1) == nil)
  expect(Covers.original("https://example.com/c.jpg") == nil)
end)

check("the loader downloads the small cover and hands it over under the cover's own address", function()
  reset()
  local got = {}
  ImageLoader:loadImages({ COVER }, function(url, content) got[#got + 1] = { url, content } end)
  drain()
  local small = Covers.url(COVER, "small", 1200, 1600)
  expect(#fetched == 1 and fetched[1] == small, "fetched " .. tostring(fetched[1]))
  expect(#got == 1 and got[1][1] == COVER and got[1][2] == "IMG:" .. small)
  expect(ImageLoader.cache:get(small), "the small cover was not kept")
end)

check("the details screen gets the large cover", function()
  reset()
  ImageLoader:loadImages({ COVER }, function() end, { size = "large" })
  drain()
  expect(fetched[1] == Covers.url(COVER, "large", 1200, 1600))
end)

check("the image service failing once is tried again; failing twice, the cover as uploaded", function()
  reset()
  local small = Covers.url(COVER, "small", 1200, 1600)
  fail_urls[small] = true
  local got
  ImageLoader:loadImages({ COVER }, function(_, content) got = content end)
  drain()
  expect(#fetched == 3 and fetched[1] == small and fetched[2] == small and fetched[3] == COVER,
    table.concat(fetched, " | "))
  expect(got == "IMG:" .. COVER and ImageLoader.cache:get(COVER), "the original was not used and kept")
end)

check("a download cancelled by a tap is not tried again", function()
  reset()
  local trapper = package.loaded["ui/trapper"]
  local real = trapper.dismissableRunInSubprocess
  trapper.dismissableRunInSubprocess = function(_, fn) fetched[#fetched + 1] = "cancelled"; return false end
  local got = false
  ImageLoader:loadImages({ COVER }, function() got = true end)
  drain()
  trapper.dismissableRunInSubprocess = real
  expect(#fetched == 1 and not got, "tried " .. #fetched .. " times")
end)

check("a cover downloaded for offline is used first, and never downloaded again", function()
  reset()
  ImageLoader.pinned:put(Covers.url(COVER, "small", 1200, 1600), "PINNED")
  local got
  ImageLoader:loadImages({ COVER }, function(_, content) got = content end)
  drain()
  expect(#fetched == 0 and got == "PINNED")
end)

check("offline, the large cover falls back to the small one, then to a full-size one saved before", function()
  reset()
  local original = ImageLoader.isOnline
  ImageLoader.isOnline = function() return false end
  ImageLoader.cache:put(Covers.url(COVER, "small", 1200, 1600), "SMALL")
  local got
  ImageLoader:loadImages({ COVER }, function(_, content) got = content end, { size = "large" })
  drain()
  expect(got == "SMALL", tostring(got))
  reset()
  ImageLoader.isOnline = function() return false end
  ImageLoader.cache:put(COVER, "FULL SIZE FROM BEFORE")
  ImageLoader:loadImages({ COVER }, function(_, content) got = content end)
  drain()
  ImageLoader.isOnline = original
  expect(got == "FULL SIZE FROM BEFORE" and #fetched == 0)
end)

check("a details cover is asked for at exactly its box, at quality 90, in alphabetical order", function()
  local box = { w = 300, h = 450 }
  local url = Covers.url(COVER, "large", 1200, 1600, box)
  expect(url:find("^https://production%-img%.hardcover%.app/enlarge%?height=450&quality=90&type=jpeg&url=") ~= nil, url)
  expect(url:match("&width=300$") ~= nil, url)
  expect(Covers.original(url) == COVER, "the original does not come back out of a quality address")
  -- the same cover without a box keeps the screen's size, at the same quality
  local plain = Covers.url(COVER, "large", 1200, 1600)
  expect(plain ~= url and plain:find("&quality=90&type=jpeg&", 1, true) ~= nil, plain)
  expect(Covers.original(plain) == COVER)
end)

check("small covers keep their address: no quality, and the screen's size without a box", function()
  local small = Covers.url(COVER, "small", 1200, 1600)
  expect(not small:find("quality", 1, true), small)
  expect(small:find("?height=360&type=jpeg&url=", 1, true) ~= nil, small)
end)

check("a box is for covers on Hardcover's assets only", function()
  expect(Covers.url("https://example.com/c.jpg", "large", 1200, 1600, { w = 300, h = 450 }) == "https://example.com/c.jpg")
  expect(Covers.url(nil, "large", 1, 1, { w = 1, h = 1 }) == nil)
end)

check("a details cover is saved and found under its box address, not downloaded again", function()
  reset()
  local box = { w = 300, h = 450 }
  local key = Covers.url(COVER, "large", 1200, 1600, box)
  local got = {}
  ImageLoader:loadImages({ COVER }, function(_, content) got[#got + 1] = content end, { size = "large", box = box })
  drain()
  expect(#fetched == 1 and fetched[1] == key, "fetched " .. table.concat(fetched, " | "))
  expect(got[1] == "IMG:" .. key, tostring(got[1]))
  expect(ImageLoader.cache:get(key), "the cover was not saved under its box address")

  ImageLoader:loadImages({ COVER }, function(_, content) got[#got + 1] = content end, { size = "large", box = box })
  drain()
  expect(#fetched == 1 and got[2] == "IMG:" .. key, "a second look downloaded it again: " .. table.concat(fetched, " | "))

  -- another box is another picture: downloaded at its own size
  ImageLoader:loadImages({ COVER }, function() end, { size = "large", box = { w = 240, h = 360 } })
  drain()
  expect(#fetched == 2 and fetched[2] == Covers.url(COVER, "large", 1200, 1600, { w = 240, h = 360 }),
    "a different box was not fetched at its own size: " .. table.concat(fetched, " | "))
end)

check("offline, a details cover at its box falls back to the small cover saved before", function()
  reset()
  local original = ImageLoader.isOnline
  ImageLoader.isOnline = function() return false end
  ImageLoader.cache:put(Covers.url(COVER, "small", 1200, 1600), "SMALL")
  local got
  ImageLoader:loadImages({ COVER }, function(_, content) got = content end,
    { size = "large", box = { w = 300, h = 450 } })
  drain()
  ImageLoader.isOnline = original
  expect(got == "SMALL" and #fetched == 0, tostring(got))
end)

check("the cache keeps to its space, dropping what was used longest ago", function()
  os.execute("rm -f '" .. dir .. "'/*")
  mtimes = {}
  local sizes = {}
  local lfs = setmetatable({ attributes = function(path, what)
    if what == "size" then return sizes[path] end
    return fake_lfs.attributes(path, what)
  end }, { __index = fake_lfs })
  local c = ImageCache:new { dir = dir, lfs = lfs, hash = hash, max_bytes = 250, make_dir = function() return true end }
  for i, name in ipairs({ "a", "b", "c" }) do
    c:put("http://x/" .. name, string.rep(name, 100))
    sizes[c:path("http://x/" .. name)] = 100
    mtimes[c:path("http://x/" .. name)] = i
  end
  c:prune()
  expect(c:get("http://x/a") == nil, "over the space, the oldest stayed")
  expect(c:has("http://x/b") and c:has("http://x/c"), "a newer cover went")
end)

check("a cache with no limit keeps everything", function()
  local c = ImageCache:new { dir = dir, lfs = fake_lfs, hash = hash, max_bytes = false }
  c:prune() -- does nothing, raises nothing
  expect(c.max_bytes == false)
end)

os.execute("rm -rf '" .. dir .. "' '" .. pinned_dir .. "'")
r.finish()
