---
title: File index
section: Features
updated: 2026-11-19
---
# File index

**FEAT-file-index.** Search files, folders and apps inside configured folders, retain a usable index across launches, and update it without filesystem work while typing. Basis: [M3 guide and accepted answers](../build/m3-file-index.md#pushback-and-answers), [M3 plan](../plan.md#m3-file-index), and [DEC-041](../decisions.md#round-6-2026-11-19).

## Entry points and prerequisites

Production startup creates `FileIndexController` from the current config, `FileIndexStore` and saved access observations. Config changes update its folders/depth/rules. A successful explicit access step updates its access policy. `rebuild()` is the Core boundary for M5's future Rebuild control; `rootStatuses` and `isIndexing` expose progress, and the snapshot holds counts and last-update time. The settings interface is not part of M3.

`FileCrawler.crawl` and `update` accept an injected reader for controlled errors and synthetic corpora. `FileIndexSnapshot.search` is the standalone Core entry point. The panel captures the file snapshot together with the app/settings catalog and usage snapshot through `LauncherSession` and `SearchCoordinator`.

## Expected outcomes

- The root is depth 0; its children are depth 1. Entries at the configured maximum depth are listed but not descended into. Hidden names, hidden flags and `node_modules` are excluded. Links retain their own path and are not followed; packages are terminal entries.
- Each explicitly added root has an independent `.gitignore` scope. Rules above that root do not apply. Overlap combines eligible entries once; an inner root can supply entries excluded by an outer root's rules. Path-search ancestors start with the outermost configured root's name. Removing a root hides entries supplied only by that root immediately.
- Nested `.gitignore` files use Git-style order, negation, anchors, directory-only rules, escapes, classes and globstars. Excluded parents are pruned. The switch disables ignore rules, but not hidden/`node_modules` exclusions. Rule-file links are never read. Case handling follows the volume's case-sensitivity; search folding is separate.
- An `.app` package ranks as an app and has a typed application-open target. Names and alternates come from the same metadata reader used by the fixed app sources. An incomplete bundle temporarily uses its filename. Its contents are not indexed. Other packages remain files. Matching app IDs from both sources produce one row.
- Public file/folder IDs use their absolute paths. Same-named entries in different locations stay distinct. A rename changes the public ID; no usage-transfer heuristic is added.
- Missing or unreadable roots retain earlier entries as unavailable. Failed subtrees are persisted for retry on relaunch, a later event or rebuild. A failed read never proves a directory empty.
- Protected folders require a saved **Allowed** observation before automatic reads. Denied, not found and error observations do not enable reads. The gate also applies to protected children of an ancestor root. Saved observations are hints, not a promise about future macOS prompts.

## Updates and persistence

Names, parent links and metadata live in immutable 256-node chunks. Small updates copy and prepare affected chunks; searches holding an earlier snapshot continue against it. Vacated slots are reused. Full paths, IDs, targets and icons are materialized for results; the small discovered-app catalog retains app metadata separately.

The scan reads flat kind/visibility and parent buffers alongside prepared text, leaving reference-bearing file nodes for updates, occasional tie comparisons and published rows. A removed-root view precomputes its eligible kinds once. Tied paths under the same root skip shared ancestors and compare the first differing component, including its following slash; disjoint roots retain canonical full-path ordering. A file-only result list is already sorted and is returned directly when no discovered app matches.

SQLite schema version 2 shares a migration with usage history. Initial/rebuild rows are staged in bounded transactions, followed by atomic activation. Incremental changes and their completed event checkpoint commit together. Usage writes remain independent of filesystem crawling; rebuild does not clear history. Cached data can satisfy initial search readiness, then events update it. A failed first source attempt completes readiness with the available data; explicit web queries need no local-source readiness.

Directory-level FSEvents start before crawling. New/moved-in directories are crawled to the remaining depth; deletions remove their supplied subtree. Bundle metadata events refresh the terminal app. Rule changes re-evaluate their subtree. Ignored-directory churn produces no index publication or database write. Paths are normalized before walking ancestors, including trailing separators from real events.

There is a device-relative stream per disjoint watch root: the SDK permits one path per such stream. Nested roots on the same device share coverage; discovered mount points get their own coverage. A cursor and event-log UUID are saved per stream/root. Changed/missing UUIDs, wrapped IDs, dropped events and root changes trigger the appropriate recovery. `HistoryDone` is a sentinel, and `RootChanged`'s zero ID is not a new cursor. Missing roots use non-recursive parent vnode watches; sibling churn does not trigger scans. An intentionally configured home root remains allowed.

## Verification recipe

Follow [setup](../verification/setup.md). `swift run ApparateCoreTests` exercises crawling, overlap, live updates, persistence, failure recovery, compact-search equivalence and typed app discovery. The Git oracle runs only in owned temporary repositories with external config/excludes disabled. Real FSEvents scenarios use temporary trees and observable completion, not fixed sleeps to assume an update.

`Tests/smoke-app.py --file-source fixture` exercises the signed app with a real temporary tree. Add `--show panel --query fixture-ledger --action-open` to inspect a file row and invoke one fake file open. Add `--fixture-app --show panel --query 'Fixture Editor' --action-open` to inspect a discovered app and invoke one fake application open. Each visible profile is brief and exits. Use `--mode live-readonly --file-source projects --runs 2` for a hidden two-process cache check. Only Projects is read; no real-data names appear in receipts.

The release harness supplies `--file-benchmark synthetic`, `--file-benchmark projects` and `--file-idle`. These record aggregate counts, timing boundaries and memory; see setup for isolation. Real-data mutation is prohibited. Change-to-search latency is measured in an owned fixture.

## Coverage and limits

These checks establish Core behavior and isolated signed-app integration. Native opens, keyboard delivery/focus, physical IME, real protected-folder grants and their persistence across normally launched rebuilds remain in the [supervised run](../verification/runs/2026-11-18T164001Z-m2-supervised.md), required before M7 release. M6 owns the end-to-end performance verdict. Sampled memory peaks are lower bounds on the true instantaneous peak; timing results describe the recorded corpus and machine.

## Verification history

- [M3 automated verification](../verification/runs/2026-11-18T181500Z-m3.md) — build-specific tests, signed-app checks, measurements and source fingerprints; independent review passed.

- [M3 search-speed review fix](../verification/runs/2026-11-18T181500Z-m3.md#post-review-search-fix) — compact scan buffers, matched-corpus equality and final performance measurements; independent recheck passed.

**2026-11-19 gate update:** Claude moved the pending native checks to the M7 release gate in the [M5 guide](../build/m5-settings-menu-first-run.md). Their recorded outcomes remain unchanged.

## M5 status integration

A separate status callback publishes loading/rebuild start, completion and failure for Settings. The snapshot supplies count and saved update time, including after reopening. Rebuild disables while active; changing ignore behavior rebuilds asynchronously. A Core fixture verifies start/finish, restored time, ignore changes and root removal during a rebuild. [M5 verification](../verification/runs/2026-11-18T212428Z-m5.md).


## M6 resource qualification

[Full-app hidden measurements](../verification/runs/2026-11-18T225138Z-m6.md) include persisted SQLite, real watchers/catalogs, retained preferences/setup, typing and sampled rebuild overlap at 20,000 and 200,000 entries. The fixture generator is outside the measured process. Projects is read-only and only counts enter evidence. These full-graph figures supersede no historical Core-only measurements; they expose additional app costs against DEC-008.

Unchanged file-node writes preserve the existing prepared chunk, including equal application metadata. Actual metadata/membership/children/application changes still create an edit and preserve older snapshots. Completed scans are counted separately from persisted updates, so a no-change recovery scan is observable without an unnecessary publication. The M6 regression checks both unchanged rebuilds and real additions.
