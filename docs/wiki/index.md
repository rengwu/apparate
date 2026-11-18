---
title: Apparate
updated: 2026-11-18
---
# Apparate

A minimal, very fast launcher for macOS. Planning notes, research, decisions, and open questions.

## Planning

- [Requirements](requirements.md) — what the user asked for.
- [Decisions](decisions.md) — accepted choices from rounds 1–4, the performance budgets, and what is still open.
- [Implementation plan](plan.md) — approved milestones from foundation to release 0.1.0, how the build runs, and progress.

## Build

- [Build guides](build/index.md) — Claude's guide for each milestone, which Codex builds from.
- [M1 guide](build/m1-foundation.md) — foundation, config, matching and ranking.

## Features and verification

- [Feature map](features/index.md) — search and config behavior, entry points and recipes.
- [Verification setup](verification/setup.md) — isolated builds, tests and measurements.
- [M1 verification](verification/runs/2026-11-18T154000Z-m1.md) — outcomes and evidence for the foundation build.

## Research

Claude and Codex researched the whole topic independently, at the user's request, and then compared conclusions.

- [Claude research report](research/claude/report.md) — with its [matching benchmark](research/claude/benchmark.md).
- [Codex research report](research/codex/report.md) — with its [source review](research/codex/open-source-launchers.md), [fuzzy matching analysis](research/codex/fuzzy-matching.md) and [benchmark](research/codex/benchmark.md).
- [Research alignment](research/alignment.md) — what both reports agree on, how differences were resolved, and the decisions left for the user.

## Spikes

- [UI design spike](spikes/2026-11-18-ui-design.md) — interactive variations of the five interfaces, and verified settings names and icons.
- [Settings deep-link spike](spikes/2026-11-18-settings-deep-links.md) — do settings links open the exact item? Mostly yes; the pane always opens.
- [Panel latency spike](spikes/2026-11-18-panel-latency.md) — measured show, keystroke, memory and idle CPU against the budgets.
