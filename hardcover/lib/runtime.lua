-- KOReader's side of running an API request: forking it so the UI keeps drawing, and
-- handing its answer back on the UI's own tick.
--
-- hardcover_api.lua used to require ui/trapper and ui/uimanager itself, which tied the
-- layer that builds and reads requests to the UI. It now asks for this through
-- `HardcoverApi.runtime`, which defaults to this module and which a test can replace
-- with a plain-Lua fake.

local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local Runtime = {}

--
-- Run `fn` in a forked subprocess and return `completed, content` (what
-- Trapper:dismissableRunInSubprocess returns). Inside Trapper:wrap this yields to the
-- UI while the request is out; outside one it blocks (KOReader logs "unwrapped
-- dismissableRunInSubprocess()"). A tap cancels it, unless `background` is true: for what
-- the reader did not ask for and is not waiting on, the request must not be cancellable
-- by touching the screen.
--
function Runtime.subprocess(fn, background)
  return Trapper:dismissableRunInSubprocess(fn, background and {} or true, true)
end

-- Run `fn` as a coroutine the UI can interleave with (see Trapper:wrap).
function Runtime.wrap(fn)
  Trapper:wrap(fn)
end

-- Run `fn` on the next UI tick, so a callback may touch widgets directly.
function Runtime.next_tick(fn)
  UIManager:nextTick(fn)
end

return Runtime
