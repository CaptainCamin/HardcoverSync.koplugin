# Components

The Mudita Mindful Design components, one module each in `hardcover/lib/ui/components/`. `theme.lua` keeps
only tokens and primitives (colours, `px`, spacing, type, line weights, `Theme.mmd` metrics, `mmdText`,
`dottedRule`); a component requires `Theme` and `components/draw.lua`, not other components, except where
composition is the point (`list_item` hosts a switch, radio or checkbox; the sheets and dialog build on
`overlay` and `button`).

Metrics come from the paper's appendix (see `e-ink-design.md`), scaled with `Theme.px`. Each component has a
scene in `spec/emu/scenarios/` that draws and taps it on a real KOReader; `spec/components_harness.lua`
checks the numbers.

| Module | What | Mockup screen |
|---|---|---|
| `draw.lua` | pixel primitives: drawn widget, strokes, tick, chevrons, line icons, dotted border, raster | n/a |
| `switch.lua` | track 48 x 30, knob 20; on = black, off = outlined, unavailable = hollow knob | 6 |
| `radio.lua` | circle 26, dot 14 | 3b |
| `checkbox.lua` | square 28, checked = filled with a tick | 6 |
| `list_item.lua` | label Black 21 / supporting Medium 18, whole-row tap, dotted divider; section heads | 6 |
| `button.lua` | rectangular (radius 8), 2px border; primary filled | 5 |
| `top_bar.lua` | 67 tall with a 3px rule, back, title, 1-3 icon actions | most |
| `tabs.lua` | 50 tall, thick underline on the active tab, tap only | 2 |
| `nav_bar.lua` | 57 tall, indicator under the active destination | 1 |
| `note.lua` | info box: icon, title, text and one small button, dotted or solid outline | 1, 1a |
| `overlay.lua` | base of every overlay: places one child, refreshes only its box; `top_rule` | n/a |
| `popover.lua` | anchored menu under its icon, dotted dividers, tick on the current choice | sort (shelf screen) |
| `choice_sheet.lua` | radio list with an X, no Cancel | sort |
| `action_sheet.lua` | outlined buttons plus one filled Cancel | 10 |
| `dialog.lua` | a floating box (60% of the screen wide, 364 to 520) with a rounded outline, heading + text, none to two stacked full-width buttons (an X when none); `warning` adds the triangle and centres the text | 5 |
| `input_dialog.lua` | a dialog with a field, sitting on top of KOReader's keyboard, the same box as Dialog with tighter spacing (the keyboard leaves little height); Enter runs the filled one, Back hides the keyboard then cancels | 5 |
| `progress_dialog.lua` | a locked dialog for a long job: heading, one line, a progress bar, a visible Stop that is answered with "Stopping…" | 5 |
| `stepper_dialog.lua` | a dialog with one or two number steppers: a big value (tap it to type the number) between a 72 square minus and plus (dotted and inert at the end of the range; hold to repeat and speed up), an optional second row that moves by a larger step, Cancel and Save; the two fields can follow each other (edition page and local page) | 5 |
| `date_picker.lua` | a dialog with a month stepper, a year stepper and a six-week grid of 48 square days (Sunday first, the chosen day filled black), after MMD's DatePicker | 5 |
| `snackbar.lua` | bottom message with at most one action, closes itself | 5 |
| `progress_bar.lua` | thin outlined track, thick black fill with round ends, an optional tick (where you should be) with a white edge; goals | 7 |
| `section.lua` | a dotted rule and a small Black label, optional count at the right; one block of a page | 4, 7, 8 |
| `scroll_control.lua` | bar over a double-line track, a triangle at each end; `wrap` for a scrolling container, `paged` for a list shown a page at a time | all |

Text uses `Theme.mmdText(str, "text" | "strong", size)`: Lato Medium and Black when installed, KOReader's
UI font (strong as bold) until then.

What is decided and what is still open is in `e-ink-design.md` (Decisions, Still open). The screens built from these
are described in `shell.md`.
