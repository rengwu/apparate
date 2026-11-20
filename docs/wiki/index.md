---
title: Apparate
updated: 2026-11-21
---
# Apparate

A minimal, very fast launcher for macOS. Planning notes, research, decisions, and open questions.

## Planning

- [Requirements](requirements.md) — what the user asked for.
- [Decisions](decisions.md) — accepted choices, the performance budgets, and what is still open.
- [Implementation plan](plan.md) — approved milestones from foundation to release 0.1.0, how the build runs, and progress.

## Build

- [Build guides](build/index.md) — Claude's guide for each milestone, which Codex builds from.
- [M1 guide](build/m1-foundation.md) — foundation, config, matching and ranking.
- [M2 guide](build/m2-sources-actions-panel.md) — apps, settings items, actions, panel and access checks.
- [M3 guide](build/m3-file-index.md) — the file index.
- [M4 guide](build/m4-launcher-panel.md) — the finished launcher panel.
- [M5 guide](build/m5-settings-menu-first-run.md) — settings, menu bar and first run.
- [M6 guide](build/m6-performance.md) — measuring the finished app against the budgets.
- [M7 guide](build/m7-release.md) — release build, archive, documentation and privacy review.

## Design

- [App icon](design/icon.md) — the glowing ball of poof, its menu bar outline, the files, and how it was chosen.

## Features and verification

- [Feature map](features/index.md) — implemented behavior, entry points and repeatable recipes.
- [Verification setup](verification/setup.md) — isolated builds, tests and measurements.
- [Supervised session](verification/supervised-session.md) — the on-screen and real-action recipes; waived for 0.1.0, still open.
- [M1 verification](verification/runs/2026-11-18T154000Z-m1.md) — outcomes and evidence for the foundation build.
- [M2 automated verification](verification/runs/2026-11-18T164000Z-m2.md) — 43 passing groups after five review fixes; [review passed](build/m2-sources-actions-panel.md#review), committed separately.
- [M2 supervised checks](verification/runs/2026-11-18T164001Z-m2-supervised.md) — native effects, permissions, global keys and IME; Untested, waived for 0.1.0 by DEC-061.
- [M3 automated verification](verification/runs/2026-11-18T181500Z-m3.md) — 63 passing groups and the verified search-speed fix; memory/end-to-end limits recorded; independent recheck passed.

- [Catalog follow-up](verification/runs/2026-11-18T191222Z-catalog.md) — unchanged metadata reuse, event traces and publication checks.

- [M4 verification](verification/runs/2026-11-18T200340Z-m4.md) — approved and committed; hidden proxy latency remains failed and carried to M6.
- [M5 verification](verification/runs/2026-11-18T212428Z-m5.md) — Settings, menu and setup; automated checks and review fix passed; included in the M5 milestone commit; native checks remain Untested.

- [UI follow-up verification](verification/runs/2026-11-19T064952Z-ui.md) — Settings cards, setup text and dynamic panel sizing; hidden checks passed, review and on-screen resize proof pending.

- [UI six-fix recheck](verification/runs/2026-11-19T070456Z-ui-review.md) — revised controls and panel alignment; new hidden renders ready for review.

- [Panel centering follow-up](verification/runs/2026-11-19T083754Z-panel-centering.md) — search, magnifier and footer alignment, with hidden renders and measured centers.

- [Result-location setting](verification/runs/2026-11-19T085025Z-row-location.md) — Inline, Right and Below, live reflow, render matrix and 20k preferences footprint.

- [Inline-default follow-up](verification/runs/2026-11-19T090422Z-inline-default.md) — round 15 default and retained saved choices.

- [Direct paths and shallow folders](verification/runs/2026-11-19T095817Z-path-folders.md) — DEC-054 navigation, shallow watches, access gates, defaults and ranking.

## Research

Claude and Codex researched the whole topic independently, at the user's request, and then compared conclusions.

- [Claude research report](research/claude/report.md) — with its [matching benchmark](research/claude/benchmark.md).
- [Codex research report](research/codex/report.md) — with its [source review](research/codex/open-source-launchers.md), [fuzzy matching analysis](research/codex/fuzzy-matching.md) and [benchmark](research/codex/benchmark.md).
- [Research alignment](research/alignment.md) — what both reports agree on, how differences were resolved, and the decisions left for the user.

## Spikes

- [UI design spike](spikes/2026-11-18-ui-design.md) — interactive variations of the five interfaces, and verified settings names and icons.
- [Settings deep-link spike](spikes/2026-11-18-settings-deep-links.md) — do settings links open the exact item? Mostly yes; the pane always opens.
- [Panel latency spike](spikes/2026-11-18-panel-latency.md) — measured show, keystroke, memory and idle CPU against the budgets.

**2026-11-19 gate update:** Claude moved the pending native checks to the M7 release gate in the [M5 guide](build/m5-settings-menu-first-run.md). Their recorded outcomes remain unchanged.

**2026-11-20 waiver:** [DEC-061](decisions.md#round-13-2026-11-19) waives supervised native checks and M6 on-screen measurements for 0.1.0. They remain Untested, and historical Failed memory budgets remain Failed.

- [M7 verification](verification/runs/2026-11-20T141252Z-m7.md) — production archive, headless upgrade and hidden checks complete; reviewed and approved.
- [Release notes draft](release/0.1.0.md) — install steps, known limits and verified archive checksum.
- [Pre-publication privacy review](release/privacy.md) — public note on the completed review and publication choices.

- [M6 hidden-stage results](verification/runs/2026-11-18T225138Z-m6.md): functional checks passed; 20k target and 200k rebuild limit missed; on-screen qualification pending.

- [Indexed dot names](verification/runs/2026-11-19T115135Z-dot-names.md) — section 6 behavior and hidden renders pass; 20k target and 200k steady/rebuild memory limits remain missed.

- [Tab completes the selection](verification/runs/2026-11-19T121020Z-tab-completion.md) — section 7 completes all accepted local kinds, with scoped names, home-abbreviated paths and native undo/redo.

- [Open With](verification/runs/2026-11-19T123000Z-open-with.md) — configurable local shortcut, remembered/default/claimed apps, Back and bounded success-only history; hidden checks pass, native behavior remains untested.

- [Right Arrow completes folders](verification/runs/2026-11-20T010038Z-right-folder.md) — section 9 shares Tab completion at the caret end, preserves native editing elsewhere, and passes hidden completion/history/caret checks.

- [Login availability and app icon](verification/runs/2026-11-20T084750Z-login-icon.md) — section 10 enables registration from not found, verifies fixture success/refusal, and bundles the final app icon.

- [Larger Below-layout icons](verification/runs/2026-11-20T111919Z-below-icons.md) — 32-point icons, matching 64-pixel rasters, safe size switching and unchanged Inline/Right hashes; completed memory comparison misses the 40/47 MiB targets but stays under 60 MiB.

- [Skip hidden files](verification/runs/2026-11-20T113654Z-skip-hidden.md) — default-on Folders switch, explicit-root/path exemptions, one rebuild per toggle and off-state equality.

- [Tight relative-path ranking](verification/runs/2026-11-20T115638Z-tight-paths.md) — capped ancestor-gap penalty, usage crossover, unchanged non-path digests and 200k path timings.

- [Single indexing indicator](verification/runs/2026-11-20T121149Z-indexing-indicator.md) — one Folders progress indicator, retained error statuses and exact idle/indexing frame equality.
