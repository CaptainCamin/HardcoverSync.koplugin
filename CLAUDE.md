# HardcoverSync.koplugin

## UI and design

- The source of truth for the plugin's look is `hardcover/lib/ui/theme.lua` (its header lists the rules). For any new or changed UI use `Theme.*`, and never hard-code a size, a grey, a font or a radius.
- It is an e-ink design: black text, `DARK_GREY` (0x55) as the lightest text, no gradients, shadows or tints, touch targets of at least `Theme.TOUCH_MIN`, and no animation.
- Every visual signal has one meaning:
  - **Border** = you can tap it. A control has a 2px black border and the one shared radius (`Theme.controlRadius`); a chip (`Theme.pill`, `Theme.tapPill`) is a full pill. Everything else (information, bars, rules) is square with no border; a cover's 1px frame is the edge of a picture, not a border. The exception is a list: its rows are not boxed, a hairline under each separates them, and the cue at the row's end (a switch, a radio mark, a chevron or an icon) says what tapping does; a row with no cue is an action and its label is bold.
  - **Fill** = state. Black fill with white text is active now: on, selected, or the one main action (at most one per group). Grey fill with a grey border and grey text is unavailable (`Theme.button` does it for a disabled button). Nothing else is grey-filled except the empty track of a progress bar (not a control) and the shades in a chart. Information has no fill: a note is its words between two hairlines (`Theme.note`).
  - **Chevron** (`Theme.chevron()`, never a typed "›") = this opens another screen, list or picker. It goes on rows, chips and headings, and is the only tap cue on borderless text. Buttons and tiles do not carry one, except a button that shows its current value and opens a picker (`Theme.button` with `chevron = true`). A settings menu item that opens something sets `opens = true`.
  - **Hatch** (`Theme.hatchRect`) = the page behind a popup is unavailable. Never a fill.
  - **Font**: serif (`Theme.serif`, or `Theme.text` with `serif = true`) is the name of a thing (a title, a heading, a big figure); bold sans is the label on a control and nothing else; regular sans is everything else, dark grey when quieter.
  - **Shadow**: none.
- Parts: `Theme.button`, `Theme.pill` / `Theme.tapPill`, `Theme.switch` (an on/off option), `Theme.radio` (the chosen one of several), `Theme.label` (a fact, plain text), `Theme.note`, `Theme.progress` (always flat), `Theme.sectionHeader`, `Theme.titleBar`, `Theme.icon` (icons bundled in the plugin's `icons/` folder).
- A readable mirror of these rules, with the tokens and a preview of each component, is the Hardcover Sync design system: https://claude.ai/artifact/7DTMpmUq7qrvMU2v3E92h7 (read `project/README.md` first). It can lag behind: if the two disagree, `theme.lua` wins. After changing `theme.lua`, tell the user the design system needs a re-sync.
- Check UI changes with the emulator (`spec/emu/run.sh <scenario>`, screenshots in `spec/emu/.out/`) as well as `./spec/run_all.sh`.
