---
title: M3 guide — File index
section: Build
updated: 2026-11-18
status: Ready
---
# M3 guide — File index

Written by Claude for Codex after the [M2 review](m2-sources-actions-panel.md#review). Same process: read it, reply with pushback before writing code, then build ([how guides are used](index.md#how-a-guide-is-used)). M1 and M2 are reviewed; Claude keeps exact copies of both, so each can be committed on its own once the user sets up git.

Scope: [M3 in the plan](../plan.md#m3-file-index). The plan's lists there are the contract; this guide adds the design, the order of work, and what M1 and M2 taught.

## Goal

Files and folders from the indexed folders appear in search, stay current while Apparate runs, and survive restarts, without ever slowing typing or waking the Mac for nothing.

M3 is done when the plan's M3 lists hold, the tests [below](#tests) pass, the [measurements](#measurements) are recorded, and the review has passed.

## Decisions that apply

| Decision | What it means for M3 |
| --- | --- |
| [REQ-003](../requirements.md), [REQ-008](../requirements.md) | Open files and folders in chosen folders; users add folders and set a depth. |
| [DEC-005](../decisions.md#round-1-2026-11-18), [DEC-020](../decisions.md#round-2-2026-11-18) | Default folders `~/Projects`, `~/Desktop`, `~/Documents`, `~/Downloads`, depth 10. |
| [DEC-006](../decisions.md#round-1-2026-11-18), [DEC-033](../decisions.md#round-4-2026-11-18) | Hidden files and `node_modules` never indexed; `.gitignore` respected, with a switch that is on by default. |
| [DEC-002](../decisions.md#round-1-2026-11-18) | Folders rank above files when matches are equally good. |
| [DEC-031](../decisions.md#round-4-2026-11-18) | A query containing `/` searches paths. |
| [DEC-016](../decisions.md#round-2-2026-11-18) | Index status and Rebuild live in settings (M5); Core exposes them now. |
| [DEC-028](../decisions.md#round-4-2026-11-18) | The 200,000-item goals: keystroke to stable results ≤ 16 ms target, ≤ 33 ms limit; memory ≤ 100 MiB. |

## What M1 and M2 taught

- **Memory** ([M1 review](m1-foundation.md#review), item 3). Each `SearchItem` keeps its ID, name and path as strings; at 200,000 items that dominated memory. Files must not be stored that way.
- **Path search** (item 4). Ancestor chains must start at the indexed folder's name, not at `/`. `users/` must not match everything.
- **Snapshot cost.** Building a `SearchIndex` for 200,000 items took about 630 ms. Rebuilding the whole index for every file change is too slow; the file index needs cheap small updates.
- **Watching** ([M2 review](m2-sources-actions-panel.md#review), item 3). Directory-level FSEvents are enough, and nothing may watch the home folder recursively.
- **Typing path** (M2 item 1). No SQLite, file-system access or locks on the keystroke path.

## Design

### Storage in memory

- **Folders** are nodes: name (prepared text, as in M1), parent node, and the indexed folder (root) they belong to.
- **Files** are entries: name (prepared text), parent folder node, kind.
- No full path and no ID string is stored per file. A result's path is built from its chain of folder nodes, and only for the rows that are published.
- **Usage** is keyed by ID strings (`file:` or `folder:` plus the absolute path, as in M1). Resolve the at most 2,000 usage records to entries once per snapshot, by walking folder nodes, instead of building an ID for every candidate.
- Names repeat a lot (`README.md`, `index.ts`, `src`). Intern repeated name texts if the measurements show it pays.

### Searching files with apps and settings

- Keep the file index as its own snapshot, separate from the M2 catalog snapshot. A search runs over both and merges them with the M1 ranking, so the order is the same as if they were one list.
- **Small changes** (a file added, renamed or removed) must reach search without rebuilding the prepared buffers for everything. One shape that works: append new entries, mark removed ones, and compact in the background once the marked share passes a threshold. Codex can propose another, with numbers.
- A published snapshot never changes. A search started on the old one finishes on the old one.
- Path mode walks ancestor chains from the root's own name downwards (`projects/klip/sources`).

### Storage on disk

- Entries go in `index.sqlite` beside the usage table, with `PRAGMA user_version` raised to 2.
- Per entry: a stable integer ID, root, parent, name, kind, and the change details needed to rescan (modification time is enough to start; add more only with a reason).
- Store the last FSEvents event ID per root, and the stream's device UUID (`FSEventsCopyUUIDForDevice`) so lost history is noticed.
- **At launch,** load from SQLite on a background task, publish that snapshot, then replay events since the saved ID. A full crawl is needed only on the first run, after a rules or folder change, or when history is lost.
- **Rebuild:** crawl into new rows inside one transaction, then publish the new snapshot. Searching continues on the old one until then. Usage rows are untouched.

### Crawling

- **Depth:** the root is depth 0 and its children depth 1. Entries at the maximum depth are indexed but not opened.
- **Never followed:** symbolic links and packages (`URLResourceKey.isPackageKey`, which covers apps, Photos libraries, Xcode projects). They are listed as entries but not opened.
- **Skipped:** hidden entries (`isHiddenKey`, which covers dot-names and the hidden flag) and `node_modules`, always.
- **Overlapping roots:** one entry per real path. An entry is included if any root reaches it within that root's depth. Its ancestor chain starts at the outermost root that contains it.
- **Errors:** "could not read" is not "empty". A folder that cannot be read keeps its previous entries, marked unavailable, and is retried on the next event or rebuild.
- **Bounded:** the crawl runs at utility priority and yields between folders. Event backlogs are coalesced per folder.

### `.gitignore`

- Git's own rules, as in the plan: nested files apply to their folder and below; later lines win; `!` re-includes; a leading or middle `/` anchors; a trailing `/` matches folders only; `*`, `?`, `[...]`, `**`; `\` escapes; trailing spaces are ignored unless escaped; a file under an excluded folder cannot be re-included.
- `.gitignore` files are hidden, so they are never listed, but they are read.
- Only `.gitignore` files inside the indexed folders count: no global excludes, no `.git/info/exclude`, no `.ignore`.
- When a `.gitignore` changes, recheck the folder it governs.
- The config switch (`respectGitignore`) turns all of this off; changing it rebuilds.
- **Oracle:** test the matcher against real Git. Create fixture repositories in temporary folders and compare with `git check-ignore --no-index`. Git is only run inside those temporary folders, never in the project.

### FSEvents

- One stream for the existing roots, directory-level (no `kFSEventStreamCreateFlagFileEvents`), with `kFSEventStreamCreateFlagWatchRoot`. Missing roots use the M2 vnode approach on their parent, non-recursively.
- Watching starts before the first crawl, from a captured event ID, so changes during the crawl are replayed.
- **An event on a folder:** list that folder's children (one level) and apply the difference.
- **Full rescan of a subtree:** `MustScanSubDirs`, `UserDropped` or `KernelDropped`.
- **Full rescan:** `RootChanged`, `EventIdsWrapped`, a changed device UUID, or a failed stream.
- **Root moved or removed:** keep its entries, marked unavailable, until it comes back or the user removes it.
- Save an event ID only after the changes it covers are stored, so a crash replays safely.
- A folder the user removes from the config leaves search results at once.

### Protected folders

- Desktop, Documents and Downloads prompt for access the first time they are read ([M2 access step](m2-sources-actions-panel.md#6-access-step)).
- Do not read a protected default folder until the user has run the access step once (there is a saved observation). After that, launches read it normally: macOS does not prompt again after a decision.
- Until then, its status is "waiting for access". The other roots are indexed normally.

### Status for settings

Expose for M5: per root, the entry count and a status (indexed, indexing, unavailable, denied, not found, waiting for access); in total, the entry count and the time of the last completed update.

### Apps in indexed folders

**Decided** ([DEC-041](../decisions.md#round-6-2026-11-19)): an `.app` package found in an indexed folder is an app. It is listed but not opened, like any package; it ranks with the app kind, opens as an app, and shows its folder as its location. Read its display name and alternates the way M2 does, but only from its `Info.plist`, never by loading it. Other packages stay file entries.

## Safety while testing

The M2 rules all still apply ([safety while testing](m2-sources-actions-panel.md#safety-while-testing)). For M3:

- Automated runs use a test config with fixture folders in a temporary location, plus `~/Projects` for the real-data measurements. `~/Projects` is not protected.
- **Never read Desktop, Documents or Downloads unattended.** The default config lists them, so never run the app against the default config.
- Real-data records hold counts and timings only. No file or folder names from the user's folders appear in the wiki, screenshots or receipts.
- Git runs only in temporary fixture folders.

## Tests

Headless, in temporary folders, with real FSEvents where the plan names them:

- **Crawl:** depth limits, links and packages listed but not followed, hidden entries and `node_modules` skipped, overlapping roots once, same-named files in different folders kept apart.
- **`.gitignore`:** the oracle comparison over a fixture set covering every rule above, including nested files, negation, anchors, folder-only patterns, `**`, escapes and an excluded folder that a later rule tries to re-include; the switch off; a rule file edited while running.
- **Events:** create, rename, move between folders and delete; changes during the first crawl; a burst of 1,000 changes coalesced; an injected `MustScanSubDirs`, dropped events and `EventIdsWrapped`; a root moved away and back; a root removed from the config.
- **Persistence:** quit and relaunch replays only what changed; a simulated crash between storing changes and saving the event ID replays safely; a changed device UUID forces a full rescan.
- **Errors:** an unreadable folder keeps its entries as unavailable; a missing root is reported as not found.
- **Search:** files merge with apps and settings in M1 order; path mode starts at the root name; `users/` does not match everything; usage still lifts a file within its tier and kind; results are identical whether the index came from a crawl or from SQLite.
- **Protected folders:** with no saved access observation, a protected root is not read.

## Measurements

Release build, recorded in the M3 run:

- **Real data** (`~/Projects` only): entry count, first crawl time, load time from SQLite at relaunch, `phys_footprint` after loading, search timings per keystroke (median, p95, max) for names and paths, and time from a file change to its being searchable.
- **Synthetic 200,000 entries** (seeded, as in M1): load time, footprint, search timings, the time for a small change to reach search, and search timings while a rebuild runs.
- **Idle:** CPU over 60 quiet seconds with the watchers running.

Report these against [DEC-008](../decisions.md#round-1-2026-11-18) as core measurements, not as the end-to-end verdict, which is M6's.

## References

- [M1 guide](m1-foundation.md) §6–§10: prepared text, tiers, path mode, ranking, coordinator. M3 extends them; it does not replace them.
- M2 `CatalogController` and `AppFolderWatcher`: watch-before-scan, coalescing, the `/var` alias fix, vnode watches for missing roots.
- Git's documentation for `gitignore` (`git help gitignore`, available offline with the Command Line Tools) and `git check-ignore`.
- Apple: File System Events Programming Guide; `FSEventStreamCreate` flags; `FSEventsCopyUUIDForDevice`; `URLResourceKey.isPackageKey`, `isHiddenKey`, `isSymbolicLinkKey`.
- [Codex's benchmark](../research/codex/benchmark.md) and [Claude's benchmark](../research/claude/benchmark.md): name versus path costs.
- [Research alignment](../research/alignment.md): exclusions, `.gitignore`, FSEvents recovery.

## Pushback and answers

Codex's pushback of 2026-11-18. All nine points are accepted; where they differ from the sections above, these win. Claude's answers add two decisions (7 and 8).

| # | Codex | Claude |
| --- | --- | --- |
| 1 | Append-and-mark on flat arrays still copies every buffer when an old search holds the snapshot. Use immutable chunks with copy-on-write, or a bounded delta over a base, whichever is simpler when measured. Keep the original name text; no per-file path, ID or catalog entry; build action targets only for published rows. Measure small updates and peak memory while an old snapshot is held. | Accepted. |
| 2 | One comparator across both sources, ending in the path-based ID. Both snapshots and the usage snapshot belong to one query generation, merged into one top 50. No per-source web fallback; the fallback is decided after the merge. Resolve usage IDs off the main thread when the snapshot pair changes. First readiness waits for each source's first complete attempt; cached data counts. The `?` scope never waits. | Accepted. |
| 3 | A one-level listing is not the whole update: new folders are crawled to the remaining depth, deleted ones remove their subtree, moved-in trees are crawled, moves re-evaluate depth and rules, and a folder replaced at the same path drops the old subtree (store identity and type, not only times). Creating, deleting or replacing a `.gitignore` rechecks its subtree. Skip events under excluded paths early. | Accepted. |
| 4 | One stream per device, with `FSEventStreamCreateRelativeToDevice` and a stored UUID and cursor per device. A missing UUID means a full crawl. Dropped events recover every root on that stream. `RootChanged` has event ID 0 and `HistoryDone` has a placeholder path; neither may corrupt the cursor. Inject multi-device cases in tests; never mount the user's volumes. | Accepted. In practice this is one stream: all default folders are on one volume. |
| 5 | One shared, idempotent database migration that keeps usage (today `UsageStore` rejects version 2). Store changes and their checkpoint together. Never skip unfinished work. Remember folders that failed to read, so a relaunch retries them. Crawl outside the write transaction, since SQLite has one writer and opens must still be recorded during a rebuild. Removing a root hides its entries at once. | Accepted. |
| 6 | Read a protected folder automatically only after an *allowed* observation; denied, not found and error wait for the user to retry. Apply the gate to protected folders reached through an ancestor root too. Do not claim macOS never prompts again. An explicitly configured home folder is a deliberate root and is watched normally; only a *missing* root must never widen to a recursive home watch. | Accepted. |
| 7 | Overlapping roots: the outermost root names the ancestor chain and defines the `.gitignore` scope, and a nested root extends depth but never brings back a folder that a rule excludes. | Ancestor chain accepted. **Rules: Claude decides differently.** A folder the user adds is indexed as if it were the only one: its own subtree's `.gitignore` files apply, and rules above it do not. The results are combined. So an explicitly added folder is always indexed, even inside a folder whose rules exclude it, because adding it says the user wants it searched. Hidden entries and `node_modules` stay excluded inside every root. If Codex still disagrees, this goes to the user. |
| 8 | The Git oracle runs with global and system config, global excludes and `info/exclude` all disabled, with NUL-separated input and output. Match the raw file name, not the folded search text. Never follow a linked `.gitignore`. Links keep their own identity. Action presence checks must not treat a dangling link as deleted. | Accepted. **Case:** match case-insensitively on a case-insensitive volume, which is what Git does there (`git init` sets `core.ignorecase = true`). Run the oracle with `-c core.ignorecase=true` for those fixtures, and test both settings. |
| 9 | Keep `~/Projects` read-only; measure change-to-search time with owned temporary fixtures. Include old-snapshot, rebuild and compaction overlap in memory. Report SQLite read, preparation and search times separately. Move the test diagnostics out of `AppDelegate`. | Accepted. |

Proposal 5 (`.app` packages as files until the user answers) is agreed, and other packages are treated the same way.

## Review

Claude reviewed M3 on 2026-11-19: the new and changed sources, the [run](../verification/runs/2026-11-18T181500Z-m3.md) and its evidence. Claude re-ran `swift run ApparateCoreTests`: 61 groups passed, 0 failed. The records contain no personal names or paths. The behaviour is thorough: every pushback point and DEC-041 are in, with tests.

**Result: one fix before the commit, on search speed.**

| # | Finding | Fix |
| --- | --- | --- |
| 1 | At 200,000 files, name search takes 13.0 ms median and 14.7 ms p95 (30.6 ms maximum), against 2.8 / 3.5 ms in M1. That leaves almost nothing of the 16 ms goal for drawing. The scan loop reads `chunk.nodes` as `[FileNode?]`, and every `FileNode` is a large struct holding a `String` name, `children`, `otherOwners`, an optional `anchor` and an optional `FileApplication`. Binding each one copies those references, so each of the 200,000 entries pays several retain and release operations, and `searchable` searches `otherOwners` too. The corpus also differs from M1's, so the two numbers are not yet directly comparable. | **Split hot from cold.** Give each chunk flat arrays for what the scan reads: kind, parent, a searchable flag or owner, and the prepared text that already exists. Keep `FileNode` for updates and for building published rows only. Then measure **both** the M1 corpus and query list through the file path, and the M3 corpus. Aim for 200,000-name p95 within 2× of M1 on the M1 corpus, and report the M3 corpus beside it. Report memory after loading and during a rebuild again: it read 109.9 MiB during rebuild overlap, against the 100 MiB goal, and the split should lower it. |

**Recheck, 2026-11-19: passed.** Claude re-ran the suite (63 groups passed). The scan now reads flat per-chunk buffers instead of binding every `FileNode`, and path tie-breaks compare only from the first differing folder. On the M1 corpus run through both engines, 200,000-name p95 is 3.30 ms against 3.74 ms for the flat M1 engine (0.88×), down from 27.7 ms; paths are 12.3 ms against 11.2 ms (1.10×). On the M3 corpus, names are 2.18 ms p95 and paths 8.89 ms. Memory is 47.9 MiB after loading and 99.3 MiB during rebuild overlap, which leaves almost no room under the 100 MiB goal for the app around it: M6 measures the whole app. Details: [post-review search fix](../verification/runs/2026-11-18T181500Z-m3.md#post-review-search-fix).

Two observations from Codex's run, followed up outside this milestone:

- **Unexplained app-list rescans.** One live idle run of the full app saw 14 catalog scans and 13 publications (2.1% CPU) with no file updates. Claude found no file changes in any app folder in that window, and the catalog code barely changed in M3. The likely cause is metadata churn on app bundles (for example, macOS updating the last-used date when an app opens): with folder-level events, each such touch starts a full rescan and a republish. Follow-up for Codex before M4: trace the trigger with counts only, then publish only when the catalog actually changed, and make rescans cheap by reusing unchanged bundles.
- **A visible test took keyboard focus.** During one visible panel check, the query changed while the panel had focus, so someone was typing. Codex stopped visible runs and deleted the captures that held text the test did not type. From now on, visible checks need the user's go-ahead.

Carried forward, no action now:

- M4: long app-folder locations clip at the row's right edge; the cold first show took 34–62 ms to return. M4 owns the rows and the warm-up, and M6 measures.
- The 200,000-entry launch reads SQLite for 1.1 s and prepares for 0.5 s in the background. That is acceptable, because search uses the catalog until files are ready. Watch it in M6.

## Proposals to confirm

Claude's proposals, not user decisions. Push back on any of them.

1. A separate file snapshot merged at search time, with append-and-mark updates and background compaction.
2. Directory-level events with a one-level listing per changed folder.
3. Protected folders read only after the access step has run once.
4. Overlapping roots: the outermost root names the ancestor chain.
5. `.app` packages listed as files until the user answers the app-folder question.
6. Testing the `.gitignore` matcher against `git check-ignore` in temporary folders.

## Records

- Feature page `FEAT-file-index` (crawl, exclusions, events, persistence, status), and updates to `FEAT-search` for merged results and path roots.
- One verification run for M3, with the real-data numbers as counts and timings only.
