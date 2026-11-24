---
title: Search
section: Features
updated: 2026-11-24
---
# Search

**FEAT-search.** Find the intended item with a short query and stable, explainable ordering. The expected behavior comes from the [M1 guide](../build/m1-foundation.md), [plan](../plan.md#m1-foundation-matching-and-ranking), and [decisions](../decisions.md). M2 supplies the panel and real app/settings sources; M3 adds the [file index](file-index.md) and apps discovered inside indexed folders.

## Entry points and prerequisites

The Core library accepts fixture-supplied `SearchItem` values in an immutable `SearchIndex`. IDs are opaque and unique; duplicate IDs are rejected. `ParsedQuery(raw, config:)` applies [config](config.md), `SearchIndex.search` returns the best 50 rows, and `SearchCoordinator.submit` computes on a serial worker and delivers on MainActor. Call `invalidate` when a query, config or index becomes obsolete, or submit its replacement. A submission captures the app/settings catalog, compact file snapshot, parsed query and showing’s usage snapshot. Both sources use the same ranking; their unique top 50 are published together. Web fallback is decided after merging. Discovered apps are deduplicated against the fixed app catalog.

`UsageStore` owns `index.sqlite` through an actor. Accepted primary opens and completed [panel drops](panel.md#drag-results-out) each call `recordSuccessfulOpen` once for the used item ID. Core tests invoke this boundary with synthetic IDs and an injected clock.

## Expected outcomes

- Whitespace at query boundaries is trimmed. Internal web-query spacing is preserved. Defaults are `'` for files and folders, `.` for settings, and `?` for web. Config can assign apps and commands prefixes too. There is no escape syntax.
- Explicit web queries return one row; empty queries return none. Only unprefixed queries with no local matches receive a web fallback. An indexed relative-path query follows that same fallback rule. A leading `/`, `~/` or exact `~` instead navigates a directory and never falls back to the web, even after an explicit scope prefix.
- Matching folds case, diacritics and width. Tiers are exact, prefix, word/acronym, fuzzy, then settings keyword. A result identifies its matching name, alternate or keyword(s); only the displayed name receives character-index highlights. M4 independently matches that name when an alternate/keyword wins, so its own matching letters still highlight without changing ranking. Unicode expansions map back to one displayed character, then whole grapheme ranges for rendering.
- Ranking is tier, kind (apps/commands, settings, folders, files), text score plus bounded usage, fewer filesystem-path components for file/folder ties, folded display name, then ID. Text scores stay finite. Input order does not affect ties; duplicate names with different IDs remain separate rows.
- A slash inside a relative query activates indexed path matching after prefix parsing (DEC-031). Only files and folders participate. The last segment matches the basename; earlier segments match distinct ancestors in order, allowing gaps. Repeated separators are ignored; a trailing `/` searches indexed descendants. Leading paths use direct directory navigation instead (DEC-054).
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

- [M4 panel verification](../verification/runs/2026-11-18T200340Z-m4.md) — alternate-winner title highlights and complete-result hashes across native renderer/background/wait controls.


- [M6 hidden performance](../verification/runs/2026-11-18T225138Z-m6.md) — shared production pipeline, matched file/pipeline/reference hashes and separate stage probes. The previous benchmark/live gap is not established as merge or catalog overhead; the remaining paced native scan difference is reported without a speculative optimization. Displayed-frame qualification remains pending.

## Direct directory navigation

After prefix parsing, leading `/`, `~/` and exact `~` read one directory off the main thread. The part after the last slash uses the usual matcher; an empty filter lists names alphabetically, capped at 50. Dot names require a leading dot in that filter; `node_modules` is visible. Packages/apps are file leaves unless a path inside one is typed. Folder links can be followed; lexical `..` and canonical aliases are checked against the protected-folder policy.

The worker reuses one listing while the final name changes. Newer generations cancel stale work/publication; changing directory, leaving this mode, hiding/showing or changing access discards the cache. An already running filesystem call cannot be interrupted. There are no index writes, watches or timers for this mode. Ordinary searches do not queue a path-cache clear or start the path worker before it is used. It works before either catalog is ready. Missing, unreadable, non-folder and access-needed states are distinct; unmatched names show No results. Tab completion and native undo/redo are described under [panel](panel.md).

[Section 5 verification](../verification/runs/2026-11-19T095817Z-path-folders.md) covers parsing, cache/cancellation, actual fixture links and canonical access aliases, plus ranking agreement across flat, compact and merged results.


## Indexed dot names

After scope parsing, a leading dot in the final typed name admits indexed dot entries: `'.config`, `'.env` and `'Repo/.git`. Ordinary `config` excludes those entries before matching, while still finding names such as vite.config.js. With the default prefixes, unprefixed `.config` continues to search Settings. A trailing slash has an empty name and excludes dot entries. Ordinary children of an explicitly configured dot root remain searchable by ordinary queries.

Dot apps are gated by their original basename, even when bundle metadata supplies a different display name. Their basename is an alternate name; app kind, target and source deduplication stay unchanged. Ranking still follows the existing tier/kind/score-plus-usage/shorter-path rules. See [section 6 verification](../verification/runs/2026-11-19T115135Z-dot-names.md).


Open With uses literal app-name matching within its last-used/default/claimed/catalog groups, with no launcher syntax or web fallback. This separate mode does not change ordinary search ranking or dot-name eligibility. See [panel](panel.md#open-with).


[Open With verification](../verification/runs/2026-11-19T123000Z-open-with.md) — DEC-057 shortcut, app groups, Back, success-only history and hidden native checks.


## Tight relative paths

DEC-060 makes indexed relative-path queries prefer tighter ancestor alignments. Each folder skipped after the first matched parent segment costs 0.1, including gaps between matched segments and between the last match and the item's parent; the total is capped at 0.4. Ancestors above the first match are free. The existing 0.2 consecutive-parent-segment bonus remains. Alignment maximizes the adjusted score before top-50 selection; the displayed name's match tier and highlights are unchanged.

For `apparate/build`, `apparate/build` beats `apparate/docs/wiki/build` even when the deeper folder has one or two opens. Five opens provide enough usage boost to overcome its 0.2 path penalty. The bounded usage boost, tier/kind ordering and final depth tie-break stay intact.

A completed alignment skips `chain.count - firstMatchIndex - parentQueryCount` folders after its first match, regardless of where later matches fall. Both engines share the capped calculation and charge it in the first alignment row. This lets the existing dynamic program choose the correct alignment without another state dimension. Queries without an indexed path do not enter this calculation; leading `/`, `~/` and `~` directory browsing is unchanged.

[Section 13 verification](../verification/runs/2026-11-20T115638Z-tight-paths.md) covers the usage crossover, interior/trailing/leading gaps, shared cap, competing alignments, an independent exhaustive oracle, top-50 cutoff, compact/regular equality, non-path digest comparison and individual 200k path-query timings.
