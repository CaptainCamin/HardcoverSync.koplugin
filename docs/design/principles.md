# Design principles

How this plugin is designed for e-ink, and why. The tokens and numbers live in `hardcover/lib/ui/theme.lua`
(the source of truth); the owner's dated calls are in [decisions.md](decisions.md); Mudita's numbers as drawn
are in [mmd-reference.md](mmd-reference.md).

## The design target

This plugin runs on 6 to 7 inch e-readers (Kindle, Kobo, Boox), about 3.3 to 4.1 in wide in a 3:4 shape. Mudita
Mindful Design (MMD) was drawn for the Mudita Kompakt, about 2.3 in wide and 9:15. So **the e-reader is the
design target** and MMD is a source: we keep what it got right (the e-ink principles, line weights, touch
sizes, black and white) and adapt its layout numbers, which assume a much narrower screen. Phone-sized
screens are not a target; there is one layout, for e-readers.

Every rule below and in the component specs carries a provenance, so a departure is never a surprise:

- **MMD**: taken as drawn.
- **Adapted**: MMD's idea, changed for the e-reader, with the reason.
- **Ours**: not in MMD (the plugin's own screens and components).

## Layout on a wider screen (Adapted)

1. **Use the width for content, not for slabs.** Text keeps a readable line length; a control does not stretch
   across the screen just because the screen is wide.
2. **Overlays are sized for the screen they are on.**
   - *Dialog*: a floating box, outlined all round (MMD hangs it off the bottom at full width). About 80% of
     the screen width, and its two actions sit side by side in one 64 px row, the filled one on the right.
     (MMD stacks them.)
   - *Sheet*: still anchored to the bottom edge across the full width, but its content is held to a centred
     column, and a sheet's actions are rows of at most two. A choice sheet's list keeps one row per option.
   - *Snackbar*: full width at the bottom, one line, as MMD.
3. **Pages** (lists, forms, settings) already use the full width. A second column or a wider measure on Goals
   and Stats is a separate decision per screen, not a default.
4. **Unchanged**: touch targets (never under `Theme.TOUCH_MIN`), outline weights, the black and grey policy,
   no animation, fixed row heights.

Status: the dialog rule is built (`components/dialog.lua`, also the input dialog). The sheet rule is the spec; sheets still run full width with stacked buttons.

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
   border, or is left out. (Buttons: an unavailable one keeps its Black label in a dotted box.) In Mudita's own log, users kept tapping buttons that were only greyed.
4. **Few big dark areas.** Try an outline or a pattern before a solid fill. A fill marks the one primary
   action or the active choice.
5. **Say what happened.** With no animation, a tap is acknowledged with visible text ("Saved"), not motion.
   A plain underline does not read as a link without colour: use a box or an icon.
6. **No animation; stable layouts.** (Already true.)
7. **Label high-stakes icons.** Pair an icon with text for rare or risky actions; icons alone are mistaken
   for each other without colour.

