-- Proves no menu item blocks on the network before showing its screen.
--
-- The bug this pins: the About box and the sign-in flow both made a blocking
-- HTTPS request *before* calling UIManager:show. On a device with no route to
-- api.github.com -- or a slow api.hardcover.app -- that request stalled, so
-- nothing was ever shown. On e-ink a screen that never changes is
-- indistinguishable from one that failed to refresh, which sent the debugging
-- in the wrong direction twice.
--
-- The rule: whatever the user tapped must put something on screen first, and
-- any network result may only update that screen afterwards.
--
-- Run with:  lua spec/no_blocking_menu_harness.lua [plugin-root]

local PLUGIN = arg[1] or "."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local results = { passed = 0, failed = 0 }

local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    results.passed = results.passed + 1
    print("  [ok  ] " .. name)
  else
    results.failed = results.failed + 1
    print("  [FAIL] " .. name .. "\n         " .. tostring(err))
  end
end

local function read(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local s = f:read("*a")
  f:close()
  return s
end

-- Blank out comments while preserving line structure, so the guards below match
-- real call sites only. A comment explaining the old blocking call is
-- documentation, not code, and matching it reported a false failure.
local function stripComments(src)
  local out = {}
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    local body = line
    -- long comment or a string first: --[[ ... ]] and --[==[ ... ]==]
    if body:match("^%s*%-%-%[%[") then
      body = ""
    else
      local qpos = body:find('"')
      local apos = body:find("'")
      local dpos = body:find("%[%[")
      local cut
      for _, p in ipairs({ qpos, apos, dpos }) do
        if p then cut = cut and math.min(cut, p) or p end
      end
      local cpos = body:find("%-%-")
      if cpos and (not cut or cpos < cut) then
        body = body:sub(1, cpos - 1)
      end
    end
    out[#out + 1] = body
  end
  return table.concat(out)
end

-- Slice from a signature to the next top-level "end" at column 1. Both files
-- are formatted that way, so this is reliable and far less fragile than trying
-- to balance braces across nested function literals.
local function bodyFrom(src, signature)
  local at = src:find(signature, 1, true)
  if not at then return nil end
  -- A generous fixed window rather than a terminator match: these bodies
  -- contain nested `end`s (inside table constructors passed to constructors),
  -- so stopping at the first one truncates the function. The guards below look
  -- for a specific call, and a slightly-too-long window cannot make one appear
  -- earlier than it really is in a way that would hide a real bug -- they only
  -- ever compare offsets within this slice.
  return src:sub(at, at + 3000)
end

local menu = read(PLUGIN .. "/hardcover/lib/ui/hardcover_menu.lua")
local main = read(PLUGIN .. "/main.lua")

-- ---------------------------------------------------------------- About

print("\n== the About box appears before it asks GitHub ==")

check("the About callback does not block on the release check", function()
  local at = menu:find('text = _("About")', 1, true)
  if not at then error("the About menu entry is missing") end
  local cb = menu:find("callback = function()", at, true)
  if not cb then error("the About entry has no callback") end
  local chunk = stripComments(bodyFrom(stripComments(menu:sub(cb)), "callback = function()")) or ""

  local show_at = chunk:find("show(nil, true)", 1, true) -- the box, before the question
  local block_at = chunk:find("[%.:]newestRelease%(%)", 1)

  if not show_at then
    error("the About entry never shows its box")
  end
  if block_at and block_at < show_at then
    error("Github:newestRelease() runs before UIManager:show -- the screen waits on the network")
  end
end)

check("the release check is asynchronous", function()
  local gh = read(PLUGIN .. "/hardcover/lib/github.lua")
  if not gh:find("function Github:newestReleaseAsync", 1, true) then
    error("github.lua has no async entry point, so callers can only block")
  end
end)

print("\n== the GitHub request has a timeout ==")

check("newestRelease sets a socket timeout", function()
  local gh = read(PLUGIN .. "/hardcover/lib/github.lua")
  -- Without this the call blocks until TCP gives up, which is the whole bug.
  if not gh:find("socketutil:set_timeout", 1, true) then
    error("github.lua sets no timeout; a blocked request stalls the menu indefinitely")
  end
end)

check("a failed release request is survivable", function()
  local gh = read(PLUGIN .. "/hardcover/lib/github.lua")
  -- http.request can raise, and json.decode on an error page certainly can.
  if not gh:find("pcall", 1, true) then
    error("github.lua does not guard its request or its decode")
  end
end)

-- ---------------------------------------------------------------- sign-in

print("\n== the sign-in flow shows something before the network call ==")

check("signIn displays an indicator before beginDeviceFlow", function()
  local body = bodyFrom(stripComments(main), "function HardcoverApp:signIn()")
  if not body then error("could not find HardcoverApp:signIn") end

  local show_at = body:find("StatusDialogs.loading", 1, true)
  local block_at = body:find("[%.:]beginDeviceFlow%(%s*%)", 1)

  if not show_at then
    error("signIn never shows its indicator")
  end
  if not block_at then
    error("beginDeviceFlow is gone -- update this guard")
  end
  if block_at < show_at then
    error("beginDeviceFlow() runs before anything is shown")
  end

  -- show() only queues the widget; a blocking call right after it means the
  -- indicator is never painted unless the screen is flushed first.
  local paint_at = body:find("UIManager:forceRePaint", 1, true)
  if not paint_at or paint_at < show_at or paint_at > block_at then
    error("signIn must call UIManager:forceRePaint() between show and beginDeviceFlow")
  end
end)

check("the sign-in dialog is not shown twice", function()
  -- main.lua showed it, then onShowSignIn showed it again. UIManager has no
  -- duplicate guard, so one screen ends up with two entries in the window
  -- stack, and the refresh bookkeeping that follows is applied to the wrong
  -- copy.
  local body = bodyFrom(stripComments(main), "function HardcoverApp:signIn()")
  if not body then error("could not find HardcoverApp:signIn") end
  local shows = select(2, body:gsub("UIManager:show%(dialog%)", ""))
  if shows > 0 then
    error("signIn shows the dialog directly as well as via onShowSignIn (" .. shows .. " time(s))")
  end
end)

check("onShowSignIn is what shows the dialog", function()
  local sd = read(PLUGIN .. "/hardcover/lib/ui/signin_dialog.lua")
  if not sd:find("function SignInDialog:onShowSignIn", 1, true) then
    error("SignInDialog:onShowSignIn is missing")
  end
  local at = sd:find("function SignInDialog:onShowSignIn", 1, true)
  local chunk = sd:sub(at, at + 200)
  if not chunk:find("UIManager:show", 1, true) then
    error("onShowSignIn no longer shows the dialog; something else must do it")
  end
end)

print("")
print(string.format("  %d passed, %d failed", results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)