-- Covers at the size they are drawn, not the size they were uploaded.
--
-- A book's cover on Hardcover is whatever was uploaded: often 1000-2000 pixels and up to
-- 3 MB (a 1.9 MB PNG for one cover on a real shelf), drawn in a box 135-400 pixels wide.
-- Hardcover's own website asks its image service for each cover at the size it shows,
-- and so does this: a 270x405 JPEG of that 1.9 MB cover is 38 KB, and twelve covers
-- from a real shelf came to 327 KB instead of 6.2 MB. Smaller downloads, faster drawing
-- on an e-reader, and twenty times as many covers in the same space on the device.
--
-- Two sizes, from the screen: "small" for rows, strips, Home's cards and the lists
-- screen, "large" for a book's details. They are rounded to steps so the same sizes
-- come back each time (the image service caches what it made, and so does the device).
-- A book's details go further: they ask for the exact box the cover is drawn in (see
-- Covers.url's `box`), so nothing is resized again on the device, and at JPEG quality
-- 90 instead of the service's 75 (Covers.QUALITY), which keeps the shading of a photo.
--
-- The service is undocumented (it is what hardcover.app uses), so nothing depends on it:
-- the image loader falls back to the cover as uploaded when it fails. Only covers on
-- Hardcover's own asset host go through it.
--
-- Pure logic: the screen size is handed in.

local Covers = {}

Covers.SERVICE = "https://production-img.hardcover.app/enlarge"

-- What part of the screen's shorter side each size is, rounded up to STEP pixels.
Covers.SIZES = { small = 0.20, large = 0.36 }
Covers.STEP = 40

-- The JPEG quality asked for, per size. Only "large" is asked for above the service's
-- default (75): it is the picture drawn big enough for the loss to show. "small" has no
-- entry, so its address is exactly what it was before this was added.
Covers.QUALITY = { large = 90 }

-- Only covers here are resized: the service is Hardcover's, for Hardcover's assets.
local ASSETS = "^https://assets%.hardcover%.app/"

local function encode(s)
  return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function decode(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- The width and height (2:3, a book's shape) to ask for, for a screen of w x h pixels.
function Covers.size(kind, screen_w, screen_h)
  local share = Covers.SIZES[kind] or Covers.SIZES.small
  local side = math.min(tonumber(screen_w) or 0, tonumber(screen_h) or 0)
  if side <= 0 then side = 1072 end -- a typical e-reader, when the screen is not known
  local w = math.ceil(side * share / Covers.STEP) * Covers.STEP
  return w, math.floor(w * 3 / 2)
end

--
-- The address to download cover `url` from, at `kind` ("small" or "large") for a screen
-- of w x h: the image service's for a cover on Hardcover's asset host, the cover as
-- uploaded otherwise. The parameters are in the order hardcover.app sends them.
--
-- `box` (optional, { w = ..., h = ... }): the exact pixel size to ask for, instead of the
-- size `kind` gives for the screen (no rounding to steps). A book's details pass the box
-- their cover is drawn in, so the picture arrives at that size.
--
function Covers.url(url, kind, screen_w, screen_h, box)
  if type(url) ~= "string" or not url:match(ASSETS) then return url end
  local w, h = Covers.size(kind, screen_w, screen_h)
  if type(box) == "table" and (tonumber(box.w) or 0) > 0 and (tonumber(box.h) or 0) > 0 then
    w, h = math.floor(box.w), math.floor(box.h)
  end
  local quality = Covers.QUALITY[kind]
  local with_quality = quality and string.format("&quality=%d", quality) or ""
  return string.format("%s?height=%d%s&type=jpeg&url=%s&width=%d",
    Covers.SERVICE, h, with_quality, encode(url), w)
end

-- The cover as uploaded, from an image-service address (nil when it is not one).
function Covers.original(url)
  if type(url) ~= "string" or url:sub(1, #Covers.SERVICE) ~= Covers.SERVICE then return nil end
  local encoded = url:match("[?&]url=([^&]+)")
  return encoded and decode(encoded) or nil
end

return Covers
