---
title: Apparate
updated: 2026-11-19
---
# Apparate

A minimal, very fast launcher for macOS. Planning notes, research, decisions, and open questions.

## Planning

- [Requirements](requirements.md) — what the user asked for.
- [Decisions](decisions.md) — accepted choices through round 11, the performance budgets, and what is still open.
- [Implementation plan](plan.md) — approved milestones from foundation to release 0.1.0, how the build runs, and progress.

## Build

- [Build guides](build/index.md) — Claude's guide for each milestone, which Codex builds from.
- [M1 guide](build/m1-foundation.md) — foundation, config, matching and ranking.
- [M2 guide](build/m2-sources-actions-panel.md) — apps, settings items, actions, panel and access checks.
- [M3 guide](build/m3-file-index.md) — the file index.
- [M4 guide](build/m4-launcher-panel.md) — the finished launcher panel.

## Design

- [App icon](design/icon.md) — the glowing ball of poof, its menu bar outline, the files, and how it was chosen.

## Features and verification

- [Feature map](features/index.md) — implemented behavior, entry points and repeatable recipes.
- [Verification setup](verification/setup.md) — isolated builds, tests and measurements.
- [M1 verification](verification/runs/2026-11-18T154000Z-m1.md) — outcomes and evidence for the foundation build.
- [M2 automated verification](verification/runs/2026-11-18T164000Z-m2.md) — 43 passing groups after five review fixes; [review passed](build/m2-sources-actions-panel.md#review), committed separately.
- [M2 supervised checks](verification/runs/2026-11-18T164001Z-m2-supervised.md) — native effects, permissions, global keys and IME; Untested, required before M5.
- [M3 automated verification](verification/runs/2026-11-18T181500Z-m3.md) — 63 passing groups and the verified search-speed fix; memory/end-to-end limits recorded; independent recheck passed.

## Research

Claude and Codex researched the whole topic independently, at the user's request, and then compared conclusions.

- [Claude research report](research/claude/report.md) — with its [matching benchmark](research/claude/benchmark.md).
- [Codex research report](research/codex/report.md) — with its [source review](research/codex/open-source-launchers.md), [fuzzy matching analysis](research/codex/fuzzy-matching.md) and [benchmark](research/codex/benchmark.md).
- [Research alignment](research/alignment.md) — what both reports agree on, how differences were resolved, and the decisions left for the user.

## Spikes

- [UI design spike](spikes/2026-11-18-ui-design.md) — interactive variations of the five interfaces, and verified settings names and icons.
- [Settings deep-link spike](spikes/2026-11-18-settings-deep-links.md) — do settings links open the exact item? Mostly yes; the pane always opens.
- [Panel latency spike](spikes/2026-11-18-panel-latency.md) — measured show, keystroke, memory and idle CPU against the budgets.
