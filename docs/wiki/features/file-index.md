---
title: File index
section: Features
updated: 2026-11-20
---
# File index

**FEAT-file-index.** Search files, folders and apps inside configured folders, retain a usable index across launches, and update it without filesystem work while typing. Basis: [M3 guide and accepted answers](../build/m3-file-index.md#pushback-and-answers), [M3 plan](../plan.md#m3-file-index), and [DEC-041](../decisions.md#round-6-2026-11-19).

## Entry points and prerequisites

Production startup creates `FileIndexController` from the current config, `FileIndexStore` and saved access observations. Config changes update its folders/depth/rules. A successful explicit access step updates its access policy. Settings calls `rebuild()` through the Rebuild control; `rootStatuses` and `isIndexing` expose progress, and the snapshot holds counts and last-update time.

During a retry, `rootStatuses` retains the last actionable error/access state until new results arrive; previously ready roots may report indexing. `isIndexing` remains the aggregate progress source for Settings' single indicator and disabled Rebuild button. See [section 14 verification](../verification/runs/2026-11-20T121149Z-indexing-indicator.md).

`FileCrawler.crawl` and `update` accept an injected reader for controlled errors and synthetic corpora. `FileIndexSnapshot.search` is the standalone Core entry point. The panel captures the file snapshot together with the app/settings catalog and usage snapshot through `LauncherSession` and `SearchCoordinator`.

## Expected outcomes

- The root is depth 0; its children are depth 1. Entries at the configured maximum depth are listed but not descended into. With the default **Skip hidden files** enabled, dot-named entries are omitted. With it off, they are terminal entries (DEC-055). In either state an explicitly configured dot root is traversed, subject to the policy for its children. `node_modules` remains excluded; the Finder hidden flag is included (DEC-054), so Library and top-level system folders can be found. Links retain their own path and are not followed; packages are terminal entries.
- Each explicitly added root has an independent `.gitignore` scope. Rules above that root do not apply. Overlap combines eligible entries once; an inner root can supply entries excluded by an outer root's rules. Path-search ancestors start with the outermost configured root's name. Removing a root hides entries supplied only by that root immediately.
- Nested `.gitignore` files use Git-style order, negation, anchors, directory-only rules, escapes, classes and globstars. Excluded parents are pruned. The switch disables ignore rules, but not the dot-folder traversal boundary or `node_modules` exclusion. Dot entries themselves obey the ignore rules. Rule-file links are never read. Case handling follows the volume's case-sensitivity; search folding is separate.
- An `.app` package ranks as an app and has a typed application-open target. Names and alternates come from the same metadata reader used by the fixed app sources. An incomplete bundle temporarily uses its filename. Its contents are not indexed. Other packages remain files. Matching app IDs from both sources produce one row.
- Public file/folder IDs use their absolute paths. Same-named entries in different locations stay distinct. A rename changes the public ID; no usage-transfer heuristic is added.
- Missing or unreadable roots retain earlier policy-eligible entries as unavailable. Failed subtrees are persisted for retry on relaunch, a later event or rebuild. A failed read never proves a directory empty.
- Protected folders require a saved **Allowed** observation before automatic reads. Denied, not found and error observations do not enable reads. The gate also applies to protected children of an ancestor root. Saved observations are hints, not a promise about future macOS prompts.

## Updates and persistence

Names, parent links and metadata live in immutable 256-node chunks. Small updates copy and prepare affected chunks; searches holding an earlier snapshot continue against it. Vacated slots are reused. Full paths, IDs, targets and icons are materialized for results; the small discovered-app catalog retains app metadata separately.

The scan reads flat kind/visibility and parent buffers alongside prepared text, leaving reference-bearing file nodes for updates, occasional tie comparisons and published rows. A removed-root view precomputes its eligible kinds once. Equal tier/kind/score-plus-usage matches first prefer fewer path components, computed from cached parent depths without materializing full paths. Remaining tied paths under the same root skip shared ancestors and compare the first differing component, including its following slash; disjoint roots retain canonical full-path ordering. A file-only result list is already sorted and is returned directly when no discovered app matches.

SQLite schema version 3 shares a migration with usage history and the bounded Open With type preferences. Existing usage and file data are preserved. Initial/rebuild rows are staged in bounded transactions, followed by atomic activation. Incremental changes and their completed event checkpoint commit together. Usage writes remain independent of filesystem crawling; rebuild does not clear history. Cached data can satisfy initial search readiness, then events update it. A failed first source attempt completes readiness with the available data; explicit web queries need no local-source readiness.

For roots deeper than 1, directory-level FSEvents start before crawling. New/moved-in directories are crawled to the remaining depth; deletions remove their supplied subtree. Bundle metadata events refresh the terminal app. Rule changes re-evaluate their subtree. Ignored-directory churn produces no index publication or database write. Paths are normalized before walking ancestors, including trailing separators from real events.

For recursive coverage there is a device-relative stream per disjoint watch root: the SDK permits one path per such stream. Nested roots on the same device share coverage unless a dot or excluded component separates them; explicit roots across that boundary get independent coverage; discovered mount points get their own coverage only within the configured depth boundary. A cursor and event-log UUID are saved per stream/root. Changed/missing UUIDs, wrapped IDs, dropped events and root changes trigger the appropriate recovery. `HistoryDone` is a sentinel, and `RootChanged`'s zero ID is not a new cursor. Missing roots use non-recursive parent vnode watches; sibling churn does not trigger scans. An intentionally configured home root remains allowed.

## Verification recipe

Follow [setup](../verification/setup.md). `swift run ApparateCoreTests` exercises crawling, overlap, live updates, persistence, failure recovery, compact-search equivalence and typed app discovery. The Git oracle runs only in owned temporary repositories with external config/excludes disabled. Real FSEvents scenarios use temporary trees and observable completion, not fixed sleeps to assume an update.

`Tests/smoke-app.py --file-source fixture` exercises the signed app with a real temporary tree. Add `--show panel --query fixture-ledger --action-open` to inspect a file row and invoke one fake file open. Add `--fixture-app --show panel --query 'Fixture Editor' --action-open` to inspect a discovered app and invoke one fake application open. Each visible profile is brief and exits. Use `--mode live-readonly --file-source projects --runs 2` for a hidden two-process cache check. Only Projects is read; no real-data names appear in receipts.

The release harness supplies `--file-benchmark synthetic`, `--file-benchmark projects` and `--file-idle`. These record aggregate counts, timing boundaries and memory; see setup for isolation. Real-data mutation is prohibited. Change-to-search latency is measured in an owned fixture.

## Coverage and limits

These checks establish Core behavior and isolated signed-app integration. Native opens, keyboard delivery/focus, physical IME, real protected-folder grants and their persistence across normally launched rebuilds remain in the [supervised run](../verification/runs/2026-11-18T164001Z-m2-supervised.md), waived for 0.1.0 by [DEC-061](../decisions.md#round-13-2026-11-19). M6 owns the end-to-end performance verdict. Sampled memory peaks are lower bounds on the true instantaneous peak; timing results describe the recorded corpus and machine.

## Verification history

- [M3 automated verification](../verification/runs/2026-11-18T181500Z-m3.md) — build-specific tests, signed-app checks, measurements and source fingerprints; independent review passed.

- [M3 search-speed review fix](../verification/runs/2026-11-18T181500Z-m3.md#post-review-search-fix) — compact scan buffers, matched-corpus equality and final performance measurements; independent recheck passed.

**2026-11-19 gate update:** Claude moved the pending native checks to the M7 release gate in the [M5 guide](../build/m5-settings-menu-first-run.md). Their recorded outcomes remain unchanged.

## M5 status integration

A separate status callback publishes loading/rebuild start, completion and failure for Settings. The snapshot supplies count and saved update time, including after reopening. Rebuild disables while active; changing ignore behavior rebuilds asynchronously. A Core fixture verifies start/finish, restored time, ignore changes and root removal during a rebuild. [M5 verification](../verification/runs/2026-11-18T212428Z-m5.md).


## M6 resource qualification

[Full-app hidden measurements](../verification/runs/2026-11-18T225138Z-m6.md) include persisted SQLite, real watchers/catalogs, retained preferences/setup, typing and sampled rebuild overlap at 20,000 and 200,000 entries. The fixture generator is outside the measured process. Projects is read-only and only counts enter evidence. These full-graph figures supersede no historical Core-only measurements; they expose additional app costs against DEC-008.

Unchanged file-node writes preserve the existing prepared chunk, including equal application metadata. Actual metadata/membership/children/application changes still create an edit and preserve older snapshots. Completed scans are counted separately from persisted updates, so a no-change recovery scan is observable without an unnecessary publication. The M6 regression checks both unchanged rebuilds and real additions.

## Shallow home and root folders

New/default configurations append `~` and `/` at depth 1 after the original four folders. Explicit saved lists are not migrated. Overlap still supplies each entry once, including Projects inside home. A depth-1 root uses a vnode on that directory, with startup/rearm rechecking because vnodes have no replay cursor. Immediate create/rename/delete and root replacement update it; deeper changes generate no events for that watch. Independently configured nested recursive roots retain their own FSEvents coverage. Missing roots use the existing nonrecursive creation watch. File-rule signature 4 rebuilds older cached exclusions to include Finder-hidden entries.

[Section 5 verification](../verification/runs/2026-11-19T095817Z-path-folders.md) includes fixture home/root overlap, a simulated mounted boundary, hidden flags, real vnode replacement/relaunch, nested recursive coverage and a separate-process busy-subtree idle measurement. The release Core harness exposes `--shallow-idle`; it creates and removes only its own fixture tree and child writer.


## Dot names by name

With `skipHiddenFiles: false`, DEC-055 indexes dot-named entries wherever an eligible root/depth permits, without listing their contents. Dot directories do not supply descendants through an outer root; an explicit dot root supplies its ordinary children normally. Terminal dot-entry events refresh their parent; deeper events are dropped. Rule-file edits still re-evaluate eligible subtrees. Dot apps keep app kind and application targets; their original basename gates candidate visibility and is an alternate name even when metadata supplies a different display name.

Ordinary queries use prepared kind buffers with dot entries excluded before matching. A leading dot in the parsed final name enables them; an empty final name after a slash does not. Eligibility is also prepared in the regular app/file search index. Memory and iteration overhead are measured, not assumed to be zero. File-rule signature 5 rebuilds caches under the new rules. Existing explicit folder lists are not migrated.

[Section 6 verification](../verification/runs/2026-11-19T115135Z-dot-names.md) covers scans, updates, explicit-root watches, app deduplication, persistence, query visibility, native renders and dot-inclusive measurement corpora.


[Open With verification](../verification/runs/2026-11-19T123000Z-open-with.md) — DEC-057 shortcut, app groups, Back, success-only history and hidden native checks.


## Skip hidden files

DEC-059 adds default-on `skipHiddenFiles`. The crawler excludes entries by their own dot-prefixed name before metadata reads, while still reading and watching `.gitignore` for its rules. Finder-hidden entries without a leading dot remain eligible. Explicit roots retain their own membership, including overlapping or nested dot roots; their dot children are omitted unless independently configured as roots. Normal children of an explicit dot root remain searchable and watched. Typed `/`, `~/` and `~` browsing is unchanged, including its existing final-name dot filter.

File-rule signature 6 includes the switch. Legacy/mismatched caches rebuild once; matching caches retain the policy in saved snapshot metadata. A config change immediately publishes a filtered view, including the discovered-app catalog, while the rebuild is pending. Compact search uses ordinary-name kind buffers plus eligible explicit dot roots for dot queries. Failed reads cannot keep forbidden dot memberships under the new policy. Rebuilding a filtered view counts its underlying memberships before applying removals, avoiding double subtraction from the displayed count.

Off preserves section 6: dot entries are terminal, final-name-dot gated, and subject to ignore rules. The low-level crawler retains its legacy default for callers without a config; production passes the config value explicitly, and incremental work inherits the snapshot policy unless a new one is supplied. The comparison driver explicitly selects off to retain its established dot-inclusive corpus.

[Section 12 verification](../verification/runs/2026-11-20T113654Z-skip-hidden.md) covers defaults/invalid values, expected-value writes, pre-metadata exclusion, hidden flags, dot apps, nested roots, failed reads, persistence, incremental renames and rule edits, real explicit-root events, typed paths, migration/toggle counts and off-state comparison.


Indexed relative-path scoring applies DEC-060's capped skipped-folder penalty in both compact and regular search before bounded selection. It preserves the existing adjacency bonus and does no added work for non-path queries. See [tight relative paths](search.md#tight-relative-paths) and [section 13 verification](../verification/runs/2026-11-20T115638Z-tight-paths.md).
