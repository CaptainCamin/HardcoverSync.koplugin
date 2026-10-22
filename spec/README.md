# Tests

Four layers, from fast to realistic. `./spec/run_all.sh` runs the first three; CI runs all four.

| Layer | Where | What it checks | Run |
|---|---|---|---|
| Syntax | `run_all.sh` | every `.lua` file parses (under LuaJIT when it is installed: that is what a device runs) | `./spec/run_all.sh` |
| Harnesses | `spec/*_harness.lua` | the plugin's logic and the arguments it hands KOReader's widgets, with KOReader stubbed | `luajit spec/foo_harness.lua .` for one |
| Sync regressions | `spec/sync_regressions/NN_*.lua` | one past offline-sync bug each, written to fail while the bug exists | `luajit spec/sync_regressions/01_*.lua .` |
| Busted specs | `spec/lib/*_spec.lua` | pure helpers inherited from the original plugin | `busted` |
| Emulator | `spec/emu/` | real KOReader widgets rendered headless, with taps | `spec/emu/run.sh` (see `spec/emu/README.md`) |

`run_all.sh` ends with totals (files, assertions) and names every file that failed. It exits non-zero on
any failure. Set `LUA=lua5.1` to pick the interpreter.

## Writing a harness

Copy a small one (`spec/vibes_harness.lua`) and use `spec/support.lua`:

```lua
local support = dofile((arg[1] or ".") .. "/spec/support.lua")
local r = support.reporter()
local check = r.test           -- check(label, fn): passes unless fn raises

support.preload_koreader_stubs() -- inert stand-ins for the KOReader modules the plugin requires
local Thing = require("hardcover/lib/thing")

check("does the thing", function()
  assert(Thing.do_it() == 3, "got " .. tostring(Thing.do_it()))
end)

r.finish()                     -- prints "N passed, M failed" and exits non-zero on a failure
```

- Stub KOReader at its boundary and assert on what the plugin hands to the widget constructors
  (`support.capturing_menu`). Do not try to run vendored widgets here; that is the emulator's job.
- Pull a function out of a source file with `support.extract_block` rather than copying it, so the
  test cannot drift from the code.
- A bug fix starts with a failing test. For an offline-sync bug, add the next numbered file in
  `spec/sync_regressions/` (see `lib.lua`): it prints `FIXED` once the bug is gone.
- Harnesses that do not use `support.reporter` (older ones with their own `check`/`eq`) print their own
  `N passed, M failed` line; `run_all.sh` counts that too. Prefer the shared one in new files.
- Avoid wall-clock time in a test (`os.time()` plus or minus a few seconds); pin the clock the way
  `sync_regressions/06_*.lua` does.
- Reading the plugin's source text and matching on it (`constructor_wiring`, `no_blocking_menu`, `theme_discipline`) is a last
  resort: it breaks on harmless refactors. Prefer a behavioural test or an emulator scenario.

## Emulator in CI

The `emulator` job downloads a pinned KOReader release and runs `spec/emu/run.sh --ci`. Scenarios that
fail for a known reason are listed with the reason in `spec/emu/parked.txt` and skipped; any other
failure fails the job.
