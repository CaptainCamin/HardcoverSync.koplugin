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
| `switch.lua` | track 48 x 30, knob 20; on = black, off = outlined, dotted = unavailable | 6 |
| `radio.lua` | circle 26, dot 14 | 3b |
| `checkbox.lua` | square 28, checked = filled with a tick | 6 |
| `list_item.lua` | label Black 21 / supporting Medium 18, whole-row tap, dotted divider; section heads | 6 |
| `button.lua` | rectangular (radius 8), 2px border; primary filled | 5 |
| `top_bar.lua` | 67 tall with a 3px rule, back, title, 1-3 icon actions | most |
| `tabs.lua` | 50 tall, thick underline on the active tab, tap only | 2 |
| `nav_bar.lua` | 57 tall, indicator above the active destination | 1 |
| `overlay.lua` | base of every overlay: places one child, refreshes only its box; `top_rule` | n/a |
| `popover.lua` | anchored menu under its icon, dotted dividers, tick on the current choice | sort |
| `choice_sheet.lua` | radio list with an X, no Cancel | sort |
| `action_sheet.lua` | outlined buttons plus one filled Cancel | 10 |
| `dialog.lua` | centred, title + text, one or two buttons | 5 |
| `snackbar.lua` | bottom message with at most one action, closes itself | 5 |
| `scroll_control.lua` | bar over a double-line track, a triangle at each end (own PR) | all |

Text uses `Theme.mmdText(str, "text" | "strong", size)`: Lato Medium and Black when installed, KOReader's
UI font (strong as bold) until then.

Open gates (owner's): divider weight (these use dotted), compact button heights, whether the overlay's white
band goes above or below the 3px rule (above, here).
