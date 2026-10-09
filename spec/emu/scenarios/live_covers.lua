--[[--
Covers through Hardcover's image service, in the real KOReader: the loader downloads a
real cover at the small and large sizes (in a subprocess, as on a device), they decode,
they are a fraction of the cover as uploaded, a cover kept for offline is served from its
own folder, and an address the service cannot make falls back to the cover as uploaded.

Public covers, no sign-in; still opt-in (it uses the network):
  KO_LIVE_COVERS=1 spec/emu/run.sh live_covers

On macOS the first run after a pause can fail with "no small cover arrived": every
download's subprocess (KOReader forks one per download) comes back empty within a fraction
of a second, the forked child dying before it answers. A download in the emulator's own
process works at the same moment, and the next runs pass, so it is the Mac's fork, not
the plugin; devices run Linux. Run it again.
]]

local COVER = "https://assets.hardcover.app/edition/32409522/5562a0b7-5a80-4b2e-b8a2-cc8f4780b904.png"
local ORIGINAL_BYTES = 1933823

return {
  name = "live_covers",

  run = function(emu)
    if os.getenv("KO_LIVE_COVERS") ~= "1" then
      print("  live_covers: KO_LIVE_COVERS not set; skipping")
      return
    end
    local UIManager = require("ui/uimanager")
    local RenderImage = require("ui/renderimage")
    local loader = require("hardcover/lib/ui/image_loader")
    local Covers = require("hardcover/lib/covers")
    for _, dir in ipairs({ "/cache/hardcover_covers", "/cache/hardcover_covers_offline" }) do
      os.execute("rm -rf '" .. emu.DataStorage:getDataDir() .. dir .. "'")
    end
    loader.cache, loader.pinned = nil, nil

    -- wait in real time, by counting: up to `seconds`, until `done()`
    local function wait(seconds, done)
      for _ = 1, seconds * 5 do
        emu:pump(200)
        if done() then return end
        os.execute("sleep 0.2")
      end
    end

    local function load(size)
      local got
      loader:loadImages({ COVER }, function(_, content) got = content end, { size = size })
      wait(60, function() return got ~= nil end)
      return got
    end

    for _, size in ipairs({ "small", "large" }) do
      local content = assert(load(size), "no " .. size .. " cover arrived")
      local w, h = loader:screenSize()
      local cw, ch = Covers.size(size, w, h)
      local bb = assert(RenderImage:renderImageData(content, #content, false), "the " .. size .. " cover does not decode")
      assert(bb:getWidth() == cw and bb:getHeight() == ch, string.format("%s is %dx%d, not %dx%d", size,
        bb:getWidth(), bb:getHeight(), cw, ch))
      assert(#content < ORIGINAL_BYTES / 10, size .. " is " .. #content .. " bytes")
      print(string.format("  live_covers: %s %dx%d, %d KB (as uploaded: %d KB)", size, cw, ch,
        math.floor(#content / 1024), math.floor(ORIGINAL_BYTES / 1024)))
      bb:free()
    end

    -- kept for offline, then served from its folder with no download
    local kept
    require("ui/trapper"):wrap(function() kept = loader:keepForOffline(COVER) end)
    wait(60, function() return kept ~= nil end)
    assert(kept, "the cover was not kept for offline")
    assert(loader:getPinned():has(loader:fetchUrl(COVER, "small")), "not in the offline folder")

    -- a cover the service cannot make: the loader falls back to the cover as uploaded
    local bogus = "https://assets.hardcover.app/edition/0/does-not-exist.jpg"
    local fell_back
    loader:loadImages({ bogus }, function(_, content) fell_back = content end)
    wait(90, function() return fell_back ~= nil or not loader:isLoading() end)
    print("  live_covers: a cover that exists nowhere: " .. (fell_back and "delivered?!" or "nothing, no error"))
    assert(fell_back == nil)
  end,
}
