---
title: Search
section: Features
updated: 2026-11-18
---
# Search

**FEAT-search.** Find the intended item with a short query and stable, explainable ordering. The expected behavior comes from the [M1 guide](../build/m1-foundation.md), [plan](../plan.md#m1-foundation-matching-and-ranking), and [decisions](../decisions.md). M2 supplies the panel and real app/settings sources; M3 adds the [file index](file-index.md) and apps discovered inside indexed folders.

## Entry points and prerequisites

The Core library accepts fixture-supplied `SearchItem` values in an immutable `SearchIndex`. IDs are opaque and unique; duplicate IDs are rejected. `ParsedQuery(raw, config:)` applies [config](config.md), `SearchIndex.search` returns the best 50 rows, and `SearchCoordinator.submit` computes on a serial worker and delivers on MainActor. Call `invalidate` when a query, config or index becomes obsolete, or submit its replacement. A submission captures the app/settings catalog, compact file snapshot, parsed query and showing’s usage snapshot. Both sources use the same ranking; their unique top 50 are published together. Web fallback is decided after merging. Discovered apps are deduplicated against the fixed app catalog.

`UsageStore` owns `index.sqlite` through an actor. Only an accepted primary open calls `recordSuccessfulOpen`; selecting or viewing a result is not an open. Core tests invoke this boundary with synthetic IDs and an injected clock.

## Expected outcomes

- Whitespace at query boundaries is trimmed. Internal web-query spacing is preserved. Defaults are `'` for files and folders, `.` for settings, and `?` for web. Config can assign apps and commands prefixes too. There is no escape syntax.
- Explicit web queries return one row; empty queries return none. Only unprefixed queries with no local matches receive a web fallback. A path query with no local matches follows that same fallback rule.
- Matching folds case, diacritics and width. Tiers are exact, prefix, word/acronym, fuzzy, then settings keyword. A result identifies its matching name, alternate or keyword(s); only the displayed name receives character-index highlights. Unicode expansions map back to one displayed character.
- Ranking is tier, kind (apps/commands, settings, folders, files), text score plus bounded usage, folded display name, then ID. Text scores stay finite. Input order does not affect ties; duplicate names with different IDs remain separate rows.
- A slash activates path mode after explicit prefix parsing. Only files and folders participate. The last segment matches the basename; earlier segments match distinct ancestors in order, allowing gaps. Leading `/` or `~/` does not anchor the search. Repeated separators are ignored; trailing `/` searches descendants; separator-only input returns no rows.
- Usage counts have a 30-day half-life. Boost is `0.5 * min(1, log1p(count) / log1p(20))`, bounded at 0.5, and cannot cross a tier or kind boundary. At most 2,000 records survive, dropping the lowest decayed counts with ID as a deterministic tie-breaker. A snapshot stays unchanged after subsequent opens.
- File path ancestors start with the outermost indexed root’s own name. Absolute account/volume ancestors are excluded from file path matching. Files retain compact parent links, rather than one stored full path and ID per entry. Usage IDs resolve on the worker when the file/usage snapshot pair changes; typing performs no database read.
- New work invalidates old work. The worker checks cancellation in 256-item chunks; the owner checks the generation again immediately before synchronous delivery. No partial or obsolete result set is published.

ASCII uses byte buffers with implicit character offsets; Unicode uses scalar buffers and explicit maps. Prepared ancestor chains are shared. Bounded selection and tier/kind pruning preserve the complete-sort ordering. Query-local parent-score caching was added after the baseline showed repeated path scoring dominated cost.

## Verification recipe

Follow [setup](../verification/setup.md). Run `swift run ApparateCoreTests` for the golden queries, prefix and fallback variants, path edges, Unicode highlights, long inputs, 1,200 generated mask cases, exhaustive short-alignment scoring, bounded-selection equivalence, usage decay/persistence/bounds and controlled generation races. Each stateful scenario creates and removes its own temporary directory.

For release measurements, build `ApparateCoreTests` with `-c release` and run its `--benchmark 20000 --rounds 3` and `--benchmark 200000 --rounds 3` modes in separate processes. Exact commands are in setup. Output includes the seed, corpus hash, query list, per-keystroke samples, top-50/highlight checksum, preparation time and physical footprint. Do not run other build/test jobs concurrently with measurements.

## Coverage and limits

These checks exercise real Core entry points and SQLite persistence, using synthetic data only. M3 additionally checks crawling, persistence, real fixture notifications and isolated app integration in its own run. These Core checks do not prove end-to-end launcher latency, native action success or permission behavior. Report core timings separately from [DEC-008](../decisions.md)'s provisional app budgets.

## Verification history

- [M1 build verification](../verification/runs/2026-11-18T154000Z-m1.md) — build-specific outcomes, measurements and source fingerprints; Claude's review passed and the packaging fix is verified in the post-review note.

- [M3 verification](../verification/runs/2026-11-18T181500Z-m3.md) — compact files, merged ranking/fallback, app discovery, root-scoped paths, persistence and measured rebuild overlap.

- [M3 search-speed review fix](../verification/runs/2026-11-18T181500Z-m3.md#post-review-search-fix) — primitive file scan buffers, shared-ancestor tie ordering and matched-corpus performance; recheck pending.
