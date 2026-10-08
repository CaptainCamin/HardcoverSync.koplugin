# HardcoverSync.koplugin

## UI and design

- The source of truth for the plugin's look is `hardcover/lib/ui/theme.lua`. For any new or changed UI, use `Theme.*` (colours, `Theme.space`, `Theme.type`, `Theme.line`, `Theme.button`, `Theme.pill`, `Theme.sectionHeader`, `Theme.titleBar`) and never hard-code sizes or greys.
- It is an e-ink design: black text, `DARK_GREY` (0x55) for secondary text and nothing lighter, no gradients, shadows or tints, touch targets of at least `Theme.TOUCH_MIN`, and no animation.
- A readable mirror of these rules, with the tokens and a preview of each component, is the Hardcover Sync design system: https://claude.ai/artifact/7DTMpmUq7qrvMU2v3E92h7 (read `project/README.md` first). It was built from `theme.lua` at main@8afe633, so if the two disagree, `theme.lua` wins. After changing `theme.lua`, tell the user the design system needs a re-sync.
