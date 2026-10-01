# Headless KOReader emulator

Renders the plugin's screens using the **real KOReader frontend** — real fonts,
real widgets, real layout, real paint — with no window, no device, and no
porting step. A change can be checked before it goes anywhere near hardware.

```bash
spec/emu/run.sh              # every scenario
spec/emu/run.sh shelf        # one scenario
spec/emu/run.sh --list       # what is available
```

Output lands in `spec/emu/.out/`: a `.png` per screen plus a `.txt` of
everything drawn, with coordinates.

## Why this and not more stubbing

The existing `spec/*_harness.lua` suite stubs KOReader and captures what the
plugin hands the widget constructors. That is the right tool for logic, and it
is why the `file` marker bug was caught before it shipped.

It cannot see the bugs that live in the widget layer itself, because the widget
never runs. Those are exactly the bugs that reach a device:

- `HorizontalGroup` sizes itself behind `getSize()` and has **no `.height`
  field**. `self.height - button_row.height - 20` is nil arithmetic.
- `ScrollableContainer` takes its size from an explicit **`dimen`**, not from
  `width`/`height`. Passing the latter leaves `dimen` nil and the first paint
  dies.
- The same widget in two parents renders twice.
- A description printed as both a metadata row and a wrapped box.

All four were live in `book_detail_dialog.lua` when this harness was first run.
The dialog did not open at all.

## How it works

`boot.lua` boots KOReader headlessly and hands a scenario a live `UIManager`:

- `SDL_VIDEODRIVER=dummy` gives a framebuffer with no window.
- `KO_HOME` redirects KOReader's data dir, so runs touch nothing real — not
  settings, not the library, not installed plugins.
- The boot sequence mirrors `reader.lua` **in the same order**. Order matters:
  `CanvasContext:init(Device)` must precede anything requiring `ui/font`, and
  `Bidi.setup()` must precede `UIManager`, because widgets cache mirroring
  settings at load time.
- The working directory must be the KOReader install: `setupkoenv`'s
  `ffi.loadlib` resolves `libs/` relative to it.
- The plugin is put on `package.path` directly, so scenarios exercise the
  files as they are — including uncommitted ones.

## What a scenario gets

```lua
local fixtures = require("fixtures")

return {
  name = "thing",
  run = function(emu)
    local settings = fixtures.real_settings(emu)   -- the plugin's own settings
    fixtures.install({ settings = settings })      -- canned API responses

    emu:shot("name")            -- render + write PNG and .txt
    emu:press("NextPage")       -- key press, asserts a widget consumed it
    emu:key("a")                -- key press, no assertion
    emu:keyLenient("a")         -- key press at the top widget only, no assertion
    emu:expectText("Want to Read")
    emu:screenText()            -- everything drawn, newline-joined
    emu:screenNodes()           -- ...with geometry
    emu:expectNoButtonOverlap()
    emu:pump()                  -- run pending scheduled work
    emu:closeAll()
  end,
}
```

Prefer real settings and real dialogs over stubs. `fixtures.install` replaces
the *network*, not the plugin.

## Traps worth knowing

These all cost time to find, and each one looks like a plugin bug.

- **`UIManager:sendEvent` returns nothing.** It is not a "was this handled?"
  signal — it returns `nil` even when the press worked. `emu:press` dispatches
  through the topmost widget's `handleEvent` and asserts on *that*.
- **Key names are device keycodes.** `Menu`'s NextPage is bound to
  `{"RPgFwd", "LPgFwd"}`, not to `"NextPage"`. An unmapped name matches nothing
  and is dropped silently. `emu:press` maps friendly names and asserts
  consumption.
- **A menu with fewer rows than fit on screen has `page_num == 1`,** and
  NextPage cycles straight back to page 1. A paging assertion against it passes
  for the wrong reason. Assert `page_num > 1` first.
- **Most text widgets never set `.dimen`.** Only some widgets assign it during
  paint. Requiring it hides most of a screen. `tree.lua` falls back to
  `getSize()` and flags those nodes `relative`.
- **Do not sort collected text by `y`.** Only some nodes have coordinates, so
  sorting interleaves them and scrambles the reading order. Paint order is
  depth-first order — walk and record, do not sort.
- **`Screen:shot()` writes the current framebuffer.** Take the screenshot after
  `UIManager:_repaint()`, or you capture the previous screen.
- **`emu:pump()` after every input.** Much of this plugin defers its next step
  with `UIManager:nextTick`; a screenshot taken straight after a key press shows
  the screen *before* the plugin reacted.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `KO_EMU_APP` | `/Applications/KOReader.app` | KOReader install, or a bare install dir |
| `KO_EMU_HOME` | `spec/emu/.home` | scratch data dir |
| `KO_EMU_OUT` | `spec/emu/.out` | where PNGs and text dumps go |
| `KO_EMU_W` / `KO_EMU_H` | `1200` / `1600` | emulated panel size |

Set the size to your device's real resolution. Layout bugs are frequently
resolution-specific, and a screen that fits at 1200x1600 may not at 758x1024.

## Adding a scenario

Drop a file in `spec/emu/scenarios/`. It returns `{ name, run }` and is picked
up automatically.

Assert on structure and content, not just "it rendered" — a PNG looks the same
whether a `file` marker is present or not. Screenshots are for what only pixels
show: truncation, spacing, cover placement.
