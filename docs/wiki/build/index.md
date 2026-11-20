---
title: Build
section: Build
updated: 2026-11-20
---
# Build

Build guides, one per milestone of the [implementation plan](../plan.md). Claude writes each guide before the milestone starts. Codex builds from it, and can push back on any part ([DEC-036](../decisions.md#round-4-2026-11-18)).

| Milestone | Guide | Status |
| --- | --- | --- |
| M1 Foundation, matching and ranking | [M1 guide](m1-foundation.md) | Reviewed and passed; committed `0a6a63e` |
| M2 Apps, settings, actions, first panel | [M2 guide](m2-sources-actions-panel.md) | [Built; automated checks passed](../verification/runs/2026-11-18T164000Z-m2.md); [reviewed: passed after five fixes](m2-sources-actions-panel.md#review); committed `b3e68c4`; supervised checks pending |
| M3 File index | [M3 guide](m3-file-index.md) | Reviewed: passed after a speed fix; committed `ef9f683` |
| M4 Launcher panel | [M4 guide](m4-launcher-panel.md) | Reviewed: passed, latency carried to M6; committed `e1543de`; supervised checks pending |
| M5 Settings, menu bar, first run | [M5 guide](m5-settings-menu-first-run.md) | Reviewed: passed after one fix; committed `a784dad`; supervised checks pending |
| M6 Performance qualification | [M6 guide](m6-performance.md) | Hidden stage reviewed and committed `87d171c`; on-screen stage waits for the user (DEC-049) |
| UI follow-up (from the supervised session) | [UI follow-up guide](ui-follow-up.md) | Sections 1–14 reviewed and passed 2026-11-20; commit requested |

## How a guide is used

1. Codex reads the guide and the pages it links, then replies with any pushback before writing code. Pushback names the guide section, says what should change, and why.
2. Claude answers. If either still disagrees after that exchange, Claude asks the user in a grill-form with both positions attributed. Parts of the milestone that do not depend on the answer go ahead.
3. Codex builds, runs the checks in the guide, and records a verification run in `verification/runs/`.
4. Claude reviews the diff and the run. Codex fixes what the review finds.
5. After the review passes, Codex makes the milestone's single commit ([DEC-037](../decisions.md#round-4-2026-11-18)).

## Rules for every milestone

- **Lean.** Follow jstack's `rule-lean` (`~/Projects/jstack/skills/rule-lean/SKILL.md`), which the user cited in [DEC-029](../decisions.md#round-4-2026-11-18). Build what the milestone needs, and nothing for later milestones.
- **Plain UI.** Follow jstack's `rule-plain-ui` (`~/Projects/jstack/skills/rule-plain-ui/SKILL.md`): every label and element needs a reason to exist.
- **No third-party packages.** System frameworks and `libsqlite3` only.
- **Core stays headless.** `ApparateCore` never imports AppKit. Its tests never open URLs, run system commands, or touch the user's real data.
- **Private data stays out of records.** Verification runs and evidence must not contain the user's account name, file names from their folders, or other personal details. Timings and counts are fine.
- **Records.** Feature and verification records follow the jstack contract (`~/Projects/jstack/references/stack-contract.md`). Rebuild the wiki with `node docs/wiki/_build.mjs`, then check it with `node docs/wiki/_build.mjs --check`.
- **Commits.** One per milestone, made after the review passes. Subject `M<n>: <milestone name>`, then a short body listing what was built and how it was verified. Never push.
