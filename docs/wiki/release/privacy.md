---
title: Pre-publication privacy review
section: Release
updated: 2026-11-21
status: Done; history rewritten before publication
---
# Pre-publication privacy review

A privacy review was completed before publication. Real System Settings and preference screenshots have been removed from the working tree and are kept locally, along with the detailed review. Their historical copies were removed from every commit before the repository was published, on 2026-11-21.

The remaining paths and names were reviewed and judged already public.

## Commit IDs after the history rewrite

Removing the screenshots from history changed every commit ID. Current pages and `Tests/upgrade-check.py` use the new IDs. Dated verification runs and their evidence keep the IDs that were tested, which no longer exist in the public history; the commits' contents are otherwise unchanged.

| Commit | Tested as | Published as |
| --- | --- | --- |
| M1: Foundation, matching and ranking | `0a6a63e` | `bf15efe` |
| M2: Apps, settings, actions, first panel | `b3e68c4` | `87a6c41` |
| Icon: glowing ball of poof, and its menu bar outline | `f0147c7` | `88ebdd8` |
| M3: File index | `ef9f683` | `c07f516` |
| Catalog: reuse unchanged metadata | `09cd03a` | `215d602` |
| M4: Launcher panel | `e1543de` | `9847930` |
| M5: Settings, menu bar and first run | `a784dad` | `9658758` |
| M6 (part 1): hidden measurements and rebuild memory fix | `87d171c` | `13038cb` |
| UI: Settings, panel, rows, folders and Open With | `b14f02c` | `9194cfd` |
| M7: Release 0.1.0 | `96abdea` | the `v0.1.0` tag |
