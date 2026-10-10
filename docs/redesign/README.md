# Redesign references

Design material for the MMD-based overhaul. Not shipped code.

- `index.html`: 20-screen mockup of the whole redesigned UI (open in a browser). Lato weights in the page
  are approximate; the emulator renders in `proto_b2/` use the real Lato Medium and Black.
- `proto_b2/`: emulator renders of the component prototypes (settings, scroll control, sheets, tabs, chips)
  at appendix metrics, plus `contact_sheet.html`. The scenes and widget library live on branch
  `claude/mmd-prototypes` (`spec/emu/scenarios/proto_*.lua`, `spec/emu/proto/widgets.lua`).
- Implementation order and the open gates: see the plan, `docs/e-ink-design.md` and `docs/components.md`.
