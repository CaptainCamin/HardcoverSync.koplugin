-- Run a block of work so that its network requests do not freeze the UI.
--
-- Inside Trapper:wrap, HardcoverApi:query forks a subprocess and yields back to
-- KOReader's event loop. Outside one it logs "unwrapped
-- dismissableRunInSubprocess(), falling back to blocking in-process run" and
-- nothing is drawn or handled until the reply arrives. Menu callbacks run
-- outside a wrap, so anything that talks to Hardcover from one must come
-- through here.
--
-- Already inside a coroutine (a caller that is itself wrapped), run inline:
-- starting a second wrap would return early to a caller that expects the work
-- to be done, and the inner request yields to the UI on its own anyway.
--
-- The block runs to its first request and then continues later, so nothing
-- after the call may depend on it having finished. Put everything that does
-- inside the block.
--
-- A tap while a request is in flight cancels it (KOReader's standard behaviour
-- for a dismissable subprocess); the call inside the block then reports
-- failure, which each caller already handles.
local Trapper = require("ui/trapper")

local Background = {}

function Background.run(fn)
  if coroutine.running() then
    return fn()
  end
  Trapper:wrap(fn)
end

return Background
