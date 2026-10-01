--[[--
Headless KOReader emulator for plugin development.

Boots the *real* KOReader frontend (fonts, widgets, UIManager, SDL framebuffer)
from an installed KOReader, with no window and no device, then paints whatever
the plugin builds into a PNG. This is the thing that lets a change be verified
without porting it to a device: the widget code under test is the same code the
device runs, not a stub of it.

Usage (from the plugin root):

    spec/emu/run.sh                      # render every scenario
    spec/emu/run.sh shelf                 # render one scenario
    spec/emu/run.sh shelf --keep-open     # leave the PNGs in ./emu-out

Knobs (environment):

    KO_EMU_APP     path to KOReader.app or a KOReader install dir
                   (default: /Applications/KOReader.app)
    KO_EMU_HOME    scratch data dir (default: spec/emu/.home)
    KO_EMU_OUT     where PNGs go (default: spec/emu/.out)
    KO_EMU_W/H     emulated screen size (default: 1200x1600, a Kobo Clara-ish
                   panel -- set it to your device's real resolution to catch
                   layout bugs that only appear at one size)

Design notes:

* SDL_VIDEODRIVER=dummy gives us a framebuffer with no window. Everything
  downstream -- fonts, text shaping, layout, paint -- is the real thing.
* KO_HOME redirects KOReader's data dir, so a run never touches the settings,
  library or plugins of a real installation. Nothing here can damage the
  user's KOReader.
* The boot sequence mirrors reader.lua, in the same order. Order matters:
  CanvasContext:init(Device) must happen before anything requires ui/font,
  and Bidi.setup() must happen before UIManager or widgets load, because they
  cache mirroring settings at load time.
]]

local M = {}

local function script_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)/[^/]*$") or "."
end

local HERE = script_dir()

--[[--
Where KOReader is installed, or nil.

Probed with plain filesystem calls rather than lfs, because this runs before
setupkoenv.lua has loaded the FFI libraries -- requiring lfs here would need the
very paths we are in the middle of discovering.
]]
local function probe_install(app)
  local candidates = {
    app .. "/Contents/koreader",
    app .. "/koreader",
    app,
  }
  for _, dir in ipairs(candidates) do
    local probe = io.open(dir .. "/setupkoenv.lua", "r")
    if probe then
      probe:close()
      local frontend = io.open(dir .. "/frontend/device.lua", "r")
      if frontend then
        frontend:close()
        return dir
      end
    end
  end
  return nil
end

function M.app_dir()
  local app = os.getenv("KO_EMU_APP") or "/Applications/KOReader.app"
  -- Accept either an .app bundle or a bare KOReader install directory.
  local dir = probe_install(app)
  if dir then return dir end
  error("no KOReader install found at " .. app .. "; set KO_EMU_APP")
end

--[[--
The plugin root -- spec/emu/../.. .

Walked up with plain string handling rather than lfs, for the same reason as
probe_install: this has to work before the FFI libraries are loaded.
]]
function M.plugin_root()
  -- HERE is <plugin>/spec/emu
  local root = HERE:gsub("/spec/emu$", "")
  if root == HERE then
    error("cannot derive the plugin root from " .. HERE)
  end
  return root
end

function M.is_dir(path)
  local lfs = require("libs/libkoreader-lfs")
  return lfs.attributes(path, "mode") == "directory"
end

function M.is_file(path)
  local lfs = require("libs/libkoreader-lfs")
  return lfs.attributes(path, "mode") == "file"
end

function M.mkdir_p(path)
  if M.is_dir(path) then return end
  M.mkdir_p(path:match("^(.*)/[^/]+$") or ".")
  require("libs/libkoreader-lfs").mkdir(path)
end

-- Where PNGs land. Kept out of the plugin tree by default so a stray run never
-- ends up inside a release zip.
function M.out_dir()
  local out = os.getenv("KO_EMU_OUT") or (HERE .. "/.out")
  M.mkdir_p(out)
  return out
end

--[[--
Boot the emulator. Returns a handle with the modules a scenario needs.

`keep_open` leaves the process alive after the scenario returns, for use with
the interactive driver (emu_drive.lua) which needs a live UIManager.
]]
function M.boot(opts)
  opts = opts or {}

  local app = M.app_dir()

  -- setupkoenv's ffi.loadlib resolves libs/ relative to the working directory,
  -- so the runner must already be inside the KOReader install (run.sh does
  -- that). Verify rather than assume, because everything after this point
  -- fails in a very confusing way if it is wrong.
  local lfs = require("libs/libkoreader-lfs")
  if lfs.currentdir() ~= app then
    error("must run with cwd = the KOReader install (" .. app ..
      "), got " .. tostring(lfs.currentdir()))
  end

  package.path = app .. "/?.lua;" .. app .. "/frontend/?.lua;" .. app .. "/common/?.lua;" .. package.path
  package.cpath = app .. "/common/?.so;" .. package.cpath

  -- Same environment reader.lua sets up before anything else.
  os.setlocale("C", "numeric")
  dofile(app .. "/setupkoenv.lua")

  --[[--
  Put the plugin under test on the path, the way KOReader's plugin loader does
  when it requires a plugin's main.lua. KOReader scans KO_HOME/plugins and adds
  each *.koplugin directory; doing it here means a scenario can require
  hardcover/lib/... directly and get the working tree, not a copy.
  ]]
  local plugin_root = M.plugin_root()
  package.path = plugin_root .. "/?.lua;" .. plugin_root .. "/?/init.lua;" .. package.path

  local DataStorage = require("datastorage")

  -- Loaded after setupkoenv: tree.lua is pure Lua and has no KOReader requires,
  -- but keeping the require order explicit avoids it ever being pulled in
  -- before the environment exists.
  local Tree = require("tree")

  G_defaults = require("luadefaults"):open()
  G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")

  local device_id = G_reader_settings:readSetting("device_id")
  if not device_id or device_id == "" then
    G_reader_settings:saveSetting("device_id", "koreader-emu-harness")
  end

  -- The C blitter allocates native buffers per repaint; in a short-lived
  -- render-many-screens run it churns for no benefit, and the Lua path is the
  -- one whose output we can reason about.
  G_reader_settings:saveSetting("dev_no_c_blitter", true)

  local bb = require("ffi/blitbuffer")
  bb:setUseCBB(false)

  local _ = require("gettext")

  local dbg = require("dbg")
  if opts.debug then dbg:turnOn() end

  local Device = require("device")
  require("document/canvascontext"):init(Device)
  require("ui/bidi").setup(nil)

  local UIManager = require("ui/uimanager")
  local Screen = Device.screen
  local BB = require("ffi/blitbuffer")

  local emu = {
    app = app,
    Device = Device,
    UIManager = UIManager,
    Screen = Screen,
    BB = BB,
    Font = require("ui/font"),
    DataStorage = DataStorage,
    Event = require("ui/event"),
    Tree = Tree,
    out = M.out_dir(),
    shots = {},
  }

  -- Seed a folder of fake books so filemanager-backed scenarios have a library.
  emu.books_dir = DataStorage:getDataDir() .. "/books"
  M.mkdir_p(emu.books_dir)

  --[[--
  Paint the current widget stack to a PNG and return its path.

  Goes through UIManager's own repaint rather than calling paintTo by hand, so
  layout is computed exactly as it is on device -- same focus handling, same
  scrolling, same cropping. A screenshot that skips this can differ from what
  the device shows.

  Returns the path plus the collected text nodes, so a scenario can assert on
  what was drawn without needing to read the image.
  ]]
  function emu:shot(name)
    UIManager:setDirty(nil, "full")
    UIManager:_repaint()

    local path = self.out .. "/" .. name .. ".png"
    Screen:shot(path)
    self.shots[#self.shots + 1] = path

    local nodes = Tree.collect(UIManager:getTopmostVisibleWidget() or {})
    print(string.format("  shot  %s  (%d text nodes)", path, #nodes))

    -- Dump the visible text alongside the image. Reading a PNG needs a vision
    -- model, which may be rate-limited or unavailable; the text file is always
    -- there, so a rendered screen can still be checked. It is also the diffable
    -- artefact -- two runs that render differently show up as a text diff long
    -- before anyone compares images.
    self:writeText(name, nodes)

    return path, nodes
  end

  -- Write the collected nodes to <out>/<name>.txt, one per line.
  function emu:writeText(name, nodes)
    nodes = nodes or self:screenNodes()
    local path = self.out .. "/" .. name .. ".txt"
    local f = assert(io.open(path, "w"))
    for _, node in ipairs(nodes) do
      if node.relative then
        f:write(string.format("%s\n", node.text))
      else
        f:write(string.format("[%4d,%4d %4dx%-4d] %s\n",
          node.x, node.y, node.w, node.h, node.text))
      end
    end
    f:close()
    return path
  end

  -- Everything currently drawn, as one newline-joined string.
  function emu:screenText()
    return Tree.text(UIManager:getTopmostVisibleWidget() or {})
  end

  -- Text nodes with their painted rectangles, sorted top-to-bottom.
  function emu:screenNodes()
    return Tree.collect(UIManager:getTopmostVisibleWidget() or {})
  end

  --[[--
  Assert that some text is on screen. Returns the matched node so a scenario
  can go on to check its geometry.
  ]]
  function emu:expectText(needle)
    for _, node in ipairs(self:screenNodes()) do
      if node.text:find(needle, 1, true) then
        return node
      end
    end
    error(string.format("expected %q on screen; saw:\n%s", needle, self:screenText()), 2)
  end

  --[[--
  Assert no two buttons overlap.

  Catches grid sizing that only breaks at one resolution -- the failure mode a
  device-only workflow finds weeks later.
  ]]
  function emu:expectNoButtonOverlap()
    local clashes = Tree.overlapping_pairs(UIManager:getTopmostVisibleWidget() or {})
    if #clashes > 0 then
      local lines = {}
      for _, c in ipairs(clashes) do
        lines[#lines + 1] = string.format("%s <-> %s (%dx%d px)",
          tostring(c.a), tostring(c.b), c.overlap_x, c.overlap_y)
      end
      error("overlapping buttons:\n  " .. table.concat(lines, "\n  "), 2)
    end
  end

  --[[--
  Send a key as if pressed, and let the resulting scheduled work run.

  Pumping tasks matters: a great deal of plugin code defers its next step with
  UIManager:nextTick, so a screenshot taken straight after a key press shows the
  screen *before* the plugin reacted.
  ]]
  --[[--
  Press a key, by the name a human would use.

  KOReader's own key bindings are device keycodes: Menu's NextPage is bound to
  { "RPgFwd", "LPgFwd" }, not to the string "NextPage". Sending "NextPage"
  therefore matches nothing and the key press is silently dropped -- which
  looks exactly like a broken widget. This translates the friendly names a
  scenario thinks in, and asserts on anything unmapped rather than dropping it
  too.
  ]]
  emu.keymap = {
    NextPage = "RPgFwd",
    PrevPage = "RPgBack",
    Down = "Down",
    Up = "Up",
    Right = "Right",
    Left = "Left",
    Confirm = "Enter",
    Enter = "Enter",
    Back = "Back",
    Menu = "Menu",
    Escape = "Escape",
  }

  function emu:key(name)
    local keycode = self.keymap[name] or name
    local Key = require("device/key")
    local handled, err = pcall(function()
      UIManager:sendEvent(self.Event:new("KeyPress", Key:new(keycode, {})))
    end)
    self:pump()
    if not handled then error(err, 0) end
  end

  --[[--
  Press a key and assert that a widget actually consumed it.

  Dispatches through the topmost widget's handleEvent rather than
  UIManager:sendEvent, because sendEvent does not return whether the event was
  handled -- it returns nil unconditionally, so asserting on its result fails
  even when the press worked perfectly. (It had already advanced the menu's
  page; only the return value was empty.)

  For a single-widget stack -- which is what a scenario normally has, since it
  builds one screen -- this is the same dispatch sendEvent performs first.

  Asserting consumption matters because a key that matches no binding is
  dropped silently, and "nothing happened" is exactly how a broken widget looks
  too.
  ]]
  function emu:press(name)
    local keycode = self.keymap[name] or name
    local Key = require("device/key")

    local target = UIManager:getTopmostVisibleWidget()
    assert(target, "no widget on the stack to press a key against")

    local consumed = target:handleEvent(
      self.Event:new("KeyPress", Key:new(keycode, {})))
    self:pump()

    assert(consumed, string.format(
      "key %q (%s) was not consumed by %s -- no widget is bound to it",
      name, keycode, tostring(target.name)))
    return consumed
  end

  --[[--
  Press a key without asserting.

  For input a widget is *expected* to ignore -- typing into a search box, for
  instance, where most keys are consumed by the keyboard widget rather than
  moving a selection.
  ]]
  function emu:key(name)
    local keycode = self.keymap[name] or name
    local Key = require("device/key")
    local target = UIManager:getTopmostVisibleWidget()
    if target then
      pcall(function()
        target:handleEvent(self.Event:new("KeyPress", Key:new(keycode, {})))
      end)
    end
    self:pump()
  end

  --[[--
  Synthesise a tap. KOReader delivers taps as a Gesture object through
  onTapHold, not as key presses, so a scenario that only ever presses keys is
  not exercising the path a finger takes.
  ]]
  function emu:tap(x, y)
    local ges_events = require("ui/gesturedetector")
    local Screen = self.Screen
    local ok, err = pcall(function()
      UIManager:sendEvent(Event:new("Gesture", ges_events.Tap:new{
        pos = { x = x, y = y },
        ges = ges_events.Tap,
        screen_width = Screen:getWidth(),
        screen_height = Screen:getHeight(),
      }))
    end)
    self:pump()
    if not ok then error(err, 0) end
  end

  --[[--
  Run pending scheduled work until the queue stops producing new tasks.

  Bounded, because a plugin that reschedules itself forever (a poll loop, say)
  would otherwise hang the harness rather than fail a test.
  ]]
  function emu:pump(max_rounds)
    local rounds = max_rounds or 40
    for _ = 1, rounds do
      local before = UIManager:getNextTaskTime()
      if not before then break end
      UIManager:_checkTasks()
      if UIManager:getNextTaskTime() == before then break end
    end
    UIManager:_checkTasks()
  end

  function emu:quit(code)
    local ok, err = pcall(function() require("device"):exit() end)
    if not ok then print("device:exit() failed: " .. tostring(err)) end
    os.exit(code or 0, true)
  end

  --[[--
  A stand-in for ReaderUI, for the paths that reach through self.ui.

  Real enough to be useful, obviously not a reader: only the handful of fields
  the plugin touches while building menus and dialogs. Anything a scenario
  needs beyond this should be added here rather than faked inside the scenario,
  so every scenario sees the same shape.
  ]]
  function emu:stub_ui(opts)
    opts = opts or {}
    return {
      document = opts.document or {
        file = opts.file or "/books/fixture-book.epub",
        getPageCount = function() return opts.pages or 412 end,
      },
      filesearcher = {
        doSearch = function() end,
      },
      getCurrentPage = function() return opts.page or 37 end,
      menu = {
        registerToMainMenu = function() end,
        booklist = function() return {} end,
      },
      getOpds = function() return {} end,
      instance = nil,
    }
  end

  -- Top of the stack, i.e. what the user is actually looking at.
  function emu:top()
    return UIManager:getTopmostVisibleWidget()
  end

  --[[--
  Close everything currently on the stack, so one scenario cannot leak a dialog
  into the next.
  ]]
  function emu:closeAll()
    local n = 0
    while UIManager:getNthTopWidget(1) do
      local w = UIManager:getNthTopWidget(1)
      if not w then break end
      UIManager:close(w)
      n = n + 1
      if n > 50 then break end
    end
    return n
  end

  return emu
end

return M
