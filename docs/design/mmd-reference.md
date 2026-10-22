# MMD reference

Mudita Mindful Design as drawn, for a small phone-shaped panel. This is MMD's own spec: where our e-reader layout differs, [principles.md](principles.md) says what is adapted. Units are the appendix's own px, scaled with `Theme.px`; `hardcover/lib/ui/theme.lua` wins on any number.

## Which catalog components the plugin uses

Written so a missing component is a decision, not an oversight. "Built" means a module in
`hardcover/lib/ui/components/` with a use on a screen.

| Component | Status |
|---|---|
| Button, Switch, Radio, Checkbox, Cards, Menus (popover), Dialog, Top app bar, Progress bar, Tabs, Separators, List, Bottom sheets, Loading, Scrollbar | Built and used |
| Navigation bar | Built; it is how the plugin opens |
| Snackbar | Built; answers what the reader did (link, tracking, progress, goal saves, status messages). It is a KOReader toast: only a tap on the bar is taken, the rest of the screen stays live. System events keep KOReader's plain toast |
| Search | Built (`search_field.lua`): the query on the results screen. Typing is KOReader's box |
| Chips | Built for state only (`chip.lua`: goal standing, shelf status). No filter, input or suggestion chips: the Library has no filters (decision) |
| Slider | Not built. The only candidate is the progress and rating entry, which uses KOReader's spin widgets; a slider needs drag handling and would replace a working widget, so it waits for a decision and a device |
| Badge | Not built. The one count (changes waiting to sync) is already in the sync box, and the nav bar has no tab where a badge would sit |
| Tooltip | Not used. It is a long-press pattern; the plugin has no hold-only actions by rule |
| FAB | Built (`components/fab.lua`), not yet used on any screen. No screen has a floating primary action; the primary action is a filled button in the flow, or a + in the top bar |

## MMD component metrics

Source: the paper's appendix ("Design system component documentation", supplemental PDF, 107 pages), which
reproduces the Zeroheight metric diagrams. Units are the diagrams' own px, not yet mapped to our scaled units.
Where the Kotlin differs, the appendix wins (Kotlin: switch 52x32, checkbox 23, radio 20/12, snackbar 48).

| Component | Spec (appendix) |
|---|---|
| Button | rectangular (about 8 radius), bold label, 2 border; primary filled black, secondary outlined; one primary per screen; small / medium / large are about 1 : 1.35 : 1.6 tall (in code: `scale` on `Button.new`, heights 40 / 56 / 64 in `Theme.mmd.button.height`); dialog and sheet action buttons have a 340 x 64 touch area |
| Round button | not in the appendix; ours (`Button.round`): outlined circle 48 / 56 / 64 with an icon at half its width, optional bold label under it, dotted circle when unavailable, tap area = circle plus label |
| FAB | 72 / 64 / 48 square, radius 18 / 18 / 14, border 2, white halo 4 / 3 / 2, icon 28 / 28 / 24 |
| Switch | track 48 x 30 (fully round), knob 20, touch 56 x 56; ON = black track, white knob; OFF = outlined track, black knob |
| Checkbox | square 28 (ON = filled black with white check), touch 48 |
| Radio | circle 26, dot 14, touch 48 |
| Chip | radius 20, border 2, padding 14 (6 beside an icon), icon 22, bold label; selected = filled black (filter chip adds a check) |
| Tabs | container 50; label 15 (active Black, inactive Medium); active = thick black underline, others a thin rule; 2-3 tabs |
| Nav bar | container 57, icon 18, active indicator 4, 2 white gap under the top rule, label 15 |
| Top app bar | height 67, icons 28 (touch 48), 3 black rule below, 16 side margins, 14 top/bottom |
| Snackbar | container 64, top rule 3 black + 2 white gap, message Medium 21 / 25, icon 28, close touch 48, button touch 83 x 48 |
| Dialog | (MMD's; our adaptation is in principles.md) a floating box about 60% of the screen wide (364 to 520), outlined all round (2, radius 12) in place of MMD's 3 black + 2 white top rule, which would double up with it; MMD itself hangs the dialog off the bottom edge at full width, drawn for a phone-sized screen; heading Black 25 / 28, text Medium 21 / 25, black; 12 side and bottom padding, 12 above the heading or icon, 10 heading to text, 24 text to buttons, 12 between buttons; buttons stacked, filled first, 340 x 64; icon 28; close icon 28 (touch 48) only on the no-button configuration; the input dialog is the same box with 8 spacing in place of 12 to 24, sitting right above the keyboard so it stays clear of the top bar |
| Menu | 2 border, rounded, dotted dividers, leading icon 28 |
| Bottom sheet | top rule 3 + 2 white gap; title Black 25 / 28, text Medium 18 / 22; side padding 12, top 24; buttons 16 apart; **action sheet** = outlined buttons + one filled Cancel; **choice sheet** = radio list + an X, no Cancel; never both |
| List item | label Black 21 / 23, supporting Medium 18 / 18, padding 16 side and 15.5 top/bottom, 4 between the lines, tile icon 48, icon 28, toggle touch 56, checkbox / radio touch 48; divider 1px **dotted**, starting after the leading icon |
| Progress / slider | filled part a thick black bar over a thin outlined track; thumb 20 with a 2 white outline, touch 26 |
| Search | pill, height 48, leading icon 20 (touch 28), clear icon 28 (touch 48) |
| Separators | dotted 1px, solid 1 / 2 / 3 / 4px, all black |
| Loading | icon 24, bold label, either inline or snackbar-style (with the 3 + 2 top rule) |
| Scroll | a slim black bar over a hollow double-line track at the list's right edge, with a bare small triangle at each end (the inactive one is drawn raster / dotted, the active one solid); shown only when the content overflows; never over text or icons; no boxed arrow buttons |
| Card | rounded rectangle, main border 3 (outline 2), optional 50 x 50 icon or a photo across the top, bold title, short subhead, at most one filled action button; the whole card is the touch area when it has no button |
| Badge | small dot 8; count circle 28 (Black 18); "99+" pill 48 x 28 |
| Tooltip | rounded box, border 3, caret, label Black 21 / 23, icon 18; 2-3 actions at most, 1-2 words each |
| Note (info box) | rounded box with a dotted border and a leading info icon, used above lists (seen in the List do/don't) |

Recurring motif worth noting: a **3px black rule with a 2px white gap** marks the top of anything that
overlays the page (snackbar, dialog, sheet, loading bar). It separates the overlay from the page without grey.

Rules the appendix states that are easy to get wrong (each has a do / don't picture):

- **Chips**: use filled chips for the active choice. An outlined chip with a check is the picture under "don't
  rely on subtle styles to indicate state". Short labels (1-2 words), no wrapping.
- **Sheets**: a choice sheet (radios) has an X and no Cancel; an action sheet has outlined buttons plus one
  filled Cancel; never both in one sheet. Current choice preselected. At most 5-6 options.
- **Dialogs**: at most two actions, stacked; the primary is filled, the secondary outlined. An acknowledgement gets one
  button, never "Okay" plus "Cancel". Six configurations: standard, warning (a triangle, centred), close icon only,
  warning + close, single action, warning single action; the X is only on the ones without buttons. Only for a
  decision or something that must be read, after a deliberate user action. Titles are specific ("No internet connection", not "Connection Error").
- **Snackbars**: only after a user action, never from the system alone; one short line, at most one action.
- **Separators**: one weight per screen; don't mix thicknesses; dotted is for soft grouping and must not be
  the main structural divider; solid for sections, dotted between rows is how the List and Menu use it.
- **Tabs**: 2-3 only, short labels, tap only (no swipe), solid black underline, change content with a full
  redraw. **Nav bar**: 2-4 destinations, keep each tab's scroll position.
- **Lists**: the whole row is the touch target; don't put several icons or buttons in one row; same padding in
  every row; prefer layout stability (no reordering).
- **Top bar**: a back arrow whenever you can go back; short title; 1-3 actions; the destructive icon alone
  with no context is a "don't".
- **Loading**: static symbol plus a bold label ("Loading data"), placed next to the content it relates to;
  never an icon alone, never several spinners; offer a "Try again" if it takes too long.
- **FAB**: no more than 3, anchored to edges, must not overlap scrollable content; one size within a context.

Still a conflict between sources: the docs say avoid greyed-out states on Switch, Checkbox, Radio and FAB, yet
the Kotlin greys disabled states. Prefer the docs.

