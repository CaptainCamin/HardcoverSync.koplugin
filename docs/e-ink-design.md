# E-ink design notes

What we have learned about designing this plugin for e-ink, where it comes from, how sure we are,
and what is still open. The rules themselves live in the header of
`hardcover/lib/ui/theme.lua` (the source of truth) and are summarised in `CLAUDE.md`.

## Where it comes from

- **Mudita Mindful Design (MMD)**, Mudita's open e-ink design system: docs at
  https://zeroheight.com/956ff055a/p/79359a-mudita-mindful-design, Android component library at
  https://github.com/mudita/MMD (Jetpack Compose, Apache-2.0, so its code cannot run in KOReader, but its
  specs and numbers can be reused).
- **The paper**: Skorupska et al., *A Dedicated E-Paper Design System for Mobile Phones*, CHI '26,
  https://doi.org/10.1145/3772318.3791459 (open access).
- **How far to trust it**: the guidelines are reasoned from the literature and Mudita's own design
  discussions. The one study behind them had 24 Mudita employees, one custom device, no control group, and
  the authors call it exploratory. Treat the rules as strong design hints, not proven results. Mudita's
  reason for black and white only is its phone panel's fast waveform; KOReader on Kobo and Kindle draws grey
  in its normal "ui" refresh mode, so that rule weighs less here.
- This plugin reached several of the same rules on its own (no animation, bordered tappables, partial-region
  refresh in `refresh.lua`), which is a good sign.

## Rules we follow

1. **Every control is visible.** If something can be tapped, scrolled or held, a control for it is on screen.
   A swipe or long press may be a shortcut, never the only way. Reviews paging and the series carousel
   already do this (visible Previous/Next or arrows, swipe on top).
2. **Fit in the lines.** Rows keep one fixed height and stay in place from page to page, so the rules between
   them are redrawn in the same spots (less ghosting, less battery). Screens change in place; a long page
   should scroll by whole pages that land on row edges.
3. **State never rests on grey alone.** A disabled or off control shows it with a check, a fill, a dotted
   border, or is left out. In Mudita's own log, users kept tapping buttons that were only greyed.
4. **Few big dark areas.** Try an outline or a pattern before a solid fill. A fill marks the one primary
   action or the active choice.
5. **Say what happened.** With no animation, a tap is acknowledged with visible text ("Saved"), not motion.
   A plain underline does not read as a link without colour: use a box or an icon.
6. **No animation; stable layouts.** (Already true.)
7. **Label high-stakes icons.** Pair an icon with text for rare or risky actions; icons alone are mistaken
   for each other without colour.

## Decisions (the owner's calls, and what each one changed)

Settled, with the date and where it is built. If something here disagrees with another note, this wins.

| Decision | Result | Built in |
|---|---|---|
| Home is one fixed screen that never scrolls; mock 1 / 1a is the layout (one bordered reading card with a filled Open book, a sync box, Shelves as two-line rows). Open book opens the book's details. | Cards beyond the first are one tap away under Shelves > Currently Reading. Small screens drop the shelf rows, then the sync box; never the card or the nav bar. | PR 6 (`ui/home_body.lua`) |
| Navigation: four tabs, Home, Library, Goals, Stats; Library is Shelves \| Lists \| Vibes (three tabs; the owner confirmed it on 10 Oct, an older two-tab mock is outdated). No chips, no "All books", no filters. | A bottom nav bar and one shell screen; a beta setting until verified on a device. | PR 6 (`ui/shell.lua`) |
| Sync box is dotted in both states. | "N changes waiting" with a sync icon, or "All synced" with a check; Sync now in both; same height. | `components/note.lua` |
| Dotted means evenly spaced round dots (outlines) and dots with a wide gap (dividers). | Dividers between rows are dotted; the earlier uneven dashes were wrong. | `Theme.dottedRule`, `Draw.dottedBorder` |
| An unavailable switch has a hollow knob (the dotted switch was rejected). | State never rests on grey alone. | `components/switch.lua` |
| Library rows are icon rows, not covers: the shelf icon for Shelves and Lists, a sparkle / ranked list / lock for Vibes. | No cover fetches on those tabs. | `ui/shelves_body.lua`, `ui/icon_list_body.lua` |
| Sort is an anchored popover; choice sheets have radios and an X, no Cancel; action sheets have outlined buttons plus one filled Cancel. | Components exist; not yet used by the shelf screen. | `components/popover.lua`, `choice_sheet.lua`, `action_sheet.lua` |
| Charts keep tonal greys. Secondary text is dark grey (0x55) by default, pure black as a beta setting. | `Theme.secondary()`; every grey text site goes through it. | PR 1 |
| Lato (Medium and Black) is the typeface, **titles included: no serif** (owner, 10 Oct). | Shipped and copied into KOReader's fonts folder; components fall back to KOReader's font until it is there. Whether Medium reads better than Regular is still judged on a device. | PR 4, `Theme.mmdText` |
| Long screens scroll with one control: a bar over a double-line track with a triangle at each end; a dotted triangle is that end reached. | On the eight scrolling screens, by whole rows. | PR 2 (`components/scroll_control.lua`) |
| Settings is a flat list with real switches, chevrons and dotted dividers; the Sync and Account tiles are the first two rows; the back arrow goes up a level. | | PR 5 |
| Book details uses fixed-size blocks (clamped About with Read more, 3 genres plus "+N more", 5 detail rows plus "All details", series and Similar-to carousels). Reviews is one scrolling list of fixed-height cards, summary first, a Load more button last. | In progress. | PR 7 |

## Still open

- **Compact button heights.** Used so far: 56 for a primary or full-width button, 40 for a small one (Sync now, Read more), 64 in sheets and dialogs; touch areas are never under 48. Not signed off.
- **Overlay rule order.** The 2 white band sits above the 3 black rule in every overlay; unchecked against the appendix.
- **Lato on a device.** Medium vs Regular, and whether the plugin can write to KOReader's fonts folder on a Kobo and a Kindle.
- **The Lists tab's rows** (the shelf icon, "7 books · ranked") have no mock of their own.

## Known deviations from the rules above

- Hold-only actions: unlink a book (`hardcover_menu.lua`, the "Linked book" row), discard all queued changes (hold on Sync now; per-change cancel is visible in `pending_changes_dialog.lua`), and the compatibility-mode help text.
- Grey fills and lines in the charts: levels down to 0xBB, a 0xD8 gridline, 0x88 dashes (`chart_widgets.lua`, `charts.lua`). Allowed (see the decisions), to be polished.
- `Theme.hatchRect` paints at 40% opacity, so its stripes anti-alias to grey; nothing calls it yet.
- `Theme.rule` hairlines and `Theme.button`'s disabled look use `DARK_GREY`.
- Screens not yet moved to the new components: book details (in progress), shelves and their sort menu, goals, stats, the dialogs and the reader panel.

## MMD component metrics

Source: the paper's appendix ("Design system component documentation", supplemental PDF, 107 pages), which
reproduces the Zeroheight metric diagrams. Units are the diagrams' own px, not yet mapped to our scaled units.
Where the Kotlin differs, the appendix wins (Kotlin: switch 52x32, checkbox 23, radio 20/12, snackbar 48).

| Component | Spec (appendix) |
|---|---|
| Button | rectangular (about 8 radius), bold label, 2 border; primary filled black, secondary outlined; one primary per screen; small / medium / large are about 1 : 1.35 : 1.6 tall; dialog and sheet action buttons have a 340 x 64 touch area |
| FAB | 72 / 64 / 48 square, radius 18 / 18 / 14, border 2, white halo 4 / 3 / 2, icon 28 / 28 / 24 |
| Switch | track 48 x 30 (fully round), knob 20, touch 56 x 56; ON = black track, white knob; OFF = outlined track, black knob |
| Checkbox | square 28 (ON = filled black with white check), touch 48 |
| Radio | circle 26, dot 14, touch 48 |
| Chip | radius 20, border 2, padding 14 (6 beside an icon), icon 22, bold label; selected = filled black (filter chip adds a check) |
| Tabs | container 50; label 15 (active Black, inactive Medium); active = thick black underline, others a thin rule; 2-3 tabs |
| Nav bar | container 57, icon 18, active indicator 4, 2 white gap under the top rule, label 15 |
| Top app bar | height 67, icons 28 (touch 48), 3 black rule below, 16 side margins, 14 top/bottom |
| Snackbar | container 64, top rule 3 black + 2 white gap, message Medium 21 / 25, icon 28, close touch 48, button touch 83 x 48 |
| Dialog | top rule 3 black + 2 white gap, action button 340 x 64, close icon 28 (touch 48) |
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
- **Dialogs**: at most two actions; the primary is filled, the secondary outlined. An acknowledgement gets one
  button, never "Okay" plus "Cancel". Titles are specific ("No internet connection", not "Connection Error").
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

## Prototypes

The approved whole-UI mockup is `docs/redesign/index.html`; the build is judged against it screen by screen. Where the build and the mockup differ on purpose, the decisions table above says so; where they differ by accident, the build is wrong.

Throwaway comparison scenes for the headless emulator (`spec/emu/scenarios/proto_*.lua`) live on branch
`claude/mmd-prototypes`. They are for deciding, not shipping. The emulator cannot show ghosting or refresh
latency; finalists need a look on a real Kobo or Kindle.
