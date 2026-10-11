# HardcoverSync.koplugin

## UI and design

- The source of truth for the plugin's look is `hardcover/lib/ui/theme.lua`. For any new or changed UI, use `Theme.*` (colours, `Theme.space`, `Theme.type`, `Theme.line`, `Theme.button`, `Theme.pill`, `Theme.sectionHeader`, `Theme.titleBar`) and never hard-code sizes or greys.
- It is an e-ink design: black text, `DARK_GREY` (0x55) for secondary text and nothing lighter, no gradients, shadows or tints, touch targets of at least `Theme.TOUCH_MIN`, and no animation.
- A readable mirror of these rules, with the tokens and a preview of each component, is the Hardcover Sync design system: https://claude.ai/artifact/7DTMpmUq7qrvMU2v3E92h7 (read `project/README.md` first). It was built from `theme.lua` at main@8afe633, so if the two disagree, `theme.lua` wins. After changing `theme.lua`, tell the user the design system needs a re-sync.
- Use `Theme.progress` for bars (solid black fill), `Theme.title` (Lato Black, no serif) for titles, pill buttons via `Theme.button`, `Theme.hatch`/`Theme.hatchRect` where a grey is wanted (note: it paints at 40% opacity, so it is grey, not a pure-black raster; the grey policy is under review), and `Theme.icon` for icons bundled in the plugin's `icons/` folder.
- Rules learned from Mudita Mindful Design, for any new or changed UI: every tappable, scrollable or holdable thing has a visible control (a swipe or long press is only a shortcut); rows keep one fixed height and stay in place from page to page; state never rests on grey alone (check, fill, dotted border, or leave the control out); try an outline or pattern before a big solid fill; acknowledge actions with visible text. Do not add hold-only actions.
- `docs/e-ink-design.md` holds the sources, how much to trust them (the underlying study is small and exploratory), the known deviations in the code, and the **open decisions** (divider weight, compact button heights, bottom nav, plus the direction below). Do not treat open decisions as rules. The owner's direction (2026-10-10, not yet implemented): charts may keep greys, Lato is liked, pure-black secondary text is wanted as a beta setting with `DARK_GREY` the default. Do not change the grey policy or fonts in code without the user's say-so.
- The design-system artifact above has drifted from `theme.lua` (it describes an aspirational v2 with `wash`/`mid` greys and hard shadows that `theme.lua` does not use). `theme.lua` wins.

## Git workflow (trunk-based)

- `main` is the only long-lived branch and the base for everything. There is no `beta` branch; where a skill or habit says "beta", use `main`.
- Start every change from fresh `origin/main` on a short-lived branch (`git fetch && git switch -c <name> origin/main`). Open the PR with base `main`, merge it when the `test` check is green, delete the branch. Never stack PRs on each other; split a big feature into slices that each work on their own, and hide unfinished UI behind a setting or an unlinked entry point.
- Betas are cut from `main`: Actions > Releases > Run workflow with a tag like `v2.0.0-beta` (always the `v` prefix; never push a bare tag, it publishes a stable release). The number is added automatically (`v2.0.0-beta.N`, one after the last beta on origin); type a full `v2.0.0-beta.4` to choose it yourself. A tag containing `beta` is published as a pre-release automatically; any other tag is stable. A stable release bumps `_meta.lua` and the changelog, then runs the same workflow with `v2.0.0`.
- A hotfix for stable while `main` holds unfinished work branches from the release tag (e.g. `v1.7.0`), is released from there, then is cherry-picked onto `main`.
- `gh` needs `--repo CaptainCamin/HardcoverSync.koplugin`. No AI attribution trailers in commits or PRs.

## Agent skills

### Issue tracker

GitHub Issues in `CaptainCamin/HardcoverSync.koplugin`, via the `gh` CLI. Always pass `--repo CaptainCamin/HardcoverSync.koplugin`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
