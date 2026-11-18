---
title: Research alignment
section: Research
updated: 2026-11-18
status: Agreed by Claude and Codex
---
# Research alignment

Claude and Codex researched the whole topic independently, as the user asked, and then reviewed each other's work. This page records where the two reports agree, where they differed and how each difference was resolved, and which decisions belong to the user. Codex reviewed two drafts and approved this version on 2026-11-18 ("ALIGNMENT OK"). Its approval covers the research alignment only; the performance budgets and settings navigation are not yet demonstrated.

- [Claude research report](claude/report.md) and its [benchmark](claude/benchmark.md)
- [Codex research report](codex/report.md), with its [source review](codex/open-source-launchers.md), [fuzzy matching analysis](codex/fuzzy-matching.md) and [benchmark](codex/benchmark.md)

## How the comparison was done

1. Both agents worked from the same brief: the user's [requirements](../requirements.md), jstack conventions, and shared machine facts (hardware, toolchain, app count, the location of the settings `.searchTerms` files).
2. The task was first split between the agents. About ten minutes in, the user asked for independent, full-scope research instead. Both agents expanded their work to the full outline and carried their earlier research forward.
3. Before that change, the agents had exchanged a few findings:
   - Codex sent Claude: Sol's 1,000-row cap, Raycast's documented ranking order, and Alfred's initials matching.
   - Claude sent Codex: Raycast 2.0's own indexer and memory figures, Alfred's reliance on Spotlight, LaunchBar's rule-based index, and a pointer to Tinycast.

   Agreement on those points is not fully independent. Each agent re-verified them in primary sources.
4. Neither agent read the other's report until both were marked done. Codex then reviewed Claude's report (nine corrections). Claude reviewed Codex's report and applied the corrections it accepted, marked inline in [its corrections section](claude/report.md#corrections-after-review). Codex keeps its report as its independent baseline. Its only later additions are two post-comparison verifications, each labelled as such: the legacy settings count and the Keyboard pane's icon metadata.

## Agreed conclusions

These are shared conclusions after comparison. Some rest on findings exchanged early (disclosed above), and some were adopted after review. The evidence is in each report.

| Topic | Shared conclusion |
| --- | --- |
| Stack | Swift + AppKit for the launcher panel and list; SwiftUI acceptable for the settings window. A web runtime adds memory with no benefit for a macOS-only app. |
| Window | Create one non-activating `NSPanel` at launch, keep it alive, and show or hide it. Never build UI on the hotkey path. |
| Hotkey | Carbon `RegisterEventHotKey`; no Accessibility permission for the basic launcher. |
| Process | One process to start. Add a helper process, mmap snapshots or bulk syscalls only if measurement shows a need. |
| Apps | Scan the standard application folders, watch them for changes, and keep localized and alternate names. Nothing is discovered per keystroke. |
| Files | Own filename-only index for user-selected roots. Default exclusions for dependency, VCS and build folders. FSEvents with a persisted checkpoint and explicit recovery (`MustScanSubDirs`, wrapped IDs, root changes). Spotlight stays optional, for a later content search. |
| Settings | Read panes and sub-items from `Info.plist` and `.searchTerms` files in both ExtensionKit extensions and legacy `.prefPane` bundles (42 files / 691 English entries on macOS 27). Cache per OS build and locale. Opening a sub-item by URL anchor and extracting each pane's icon are both **unverified**; fall back to the pane and a generic icon. |
| Matching | fzy-style scorer over prepared, folded names, with a 64-bit character mask and a subsequence pre-check. Select the top K; never fully sort. `VSC` must work without an alias. |
| Ranking | Tiers first: exact/alias, prefix, word-start/acronym, then general fuzzy. Learned usage changes order only within comparable match quality. Ties break deterministically. |
| Result stability | Search one consistent snapshot, publish one complete list per query, drop obsolete query generations, fixed row geometry, keep the selected item by stable ID. |
| Scope of the first version | Name/path search only, no file contents. Defer clipboard history, window management, AI, extensions and sync. |
| Commercial launchers | Raycast 2.0 has its own file indexer (v1 used Spotlight). Alfred relies on the Spotlight index. LaunchBar scans rule-defined folders. |

## Differences and how they were resolved

| # | Topic | Claude | Codex | Resolution |
| --- | --- | --- | --- | --- |
| 1 | Why Spotlight is slow | Per-keystroke daemon queries and async result merging (stated as fact) | Not profiled; don't assign a cause | **Codex's position.** Causes are inference in both reports. |
| 2 | "Fast launchers avoid per-keystroke IPC" | Stated as a common factor | Counterexamples: Flow → Everything (IPC), Raycast 2.0 (several runtimes) | **Codex's position.** Reworded: predictable latency and one complete result set matter, not where the data lives. |
| 3 | Where search runs | Synchronously on the main thread | Serial cancellable worker, generation numbers, atomic publish | **Codex's position.** Background scoring avoids doing search work on the UI thread. Locking, publication and indexing contention still need measurement. Stability comes from four parts together: atomic publication, generation guards, snapshot consistency and selected-ID handling. |
| 4 | Sol's file matcher | fuse.js | `NSString.scoreAgainst` + alphabetical sort; MiniSearch for root search | **Codex correct.** Verified in Sol at `873ae1c`. |
| 5 | Settings item count | 42 files / 691 entries | 41 / 688 | **Both correct** for their scope. ExtensionKit has 41 / 688; the legacy `DateAndTime.prefPane` adds 1 / 3. |
| 6 | Directory enumeration | Cited Tinycast's `getattrlistbulk`; said the choice matters little at this scale | Start with `FileManager.enumerator`; `getattrlistbulk` only if measured as a bottleneck | **Codex's position** (simplest first). Claude agrees. |
| 7 | Index persistence | Compact snapshot file + last event ID | SQLite records + immutable in-memory search arrays | **Codex's position.** Usage history needs durable storage anyway, so one engine (system SQLite, no dependency) serves both. Revisit if measured. |
| 8 | Performance budgets | Hotkey ≤ 16 ms, query ≤ 8 ms at 20k, idle ≤ 40 MB at 20k | Hotkey p95 ≤ 33 ms, query p95 ≤ 16 ms at 20k / ≤ 33 ms at 200k, ≤ 60 MiB at 20k / ≤ 100 MiB at 200k | **Proposed:** Claude's numbers as targets, Codex's as acceptance limits, with Codex's boundaries. Hotkey latency is warm hotkey to presented frame, at p95. Query latency is input to stable displayed results, at p95, not scorer time. Memory is `phys_footprint` in MiB, including helper processes. Nothing has been achieved yet; there is no prototype. Raised with the user. |
| 9 | Benchmark numbers | 200k names, 1 thread, **including** top-50 selection: 1.303 ms = mean over keystrokes of each keystroke's best of 7 runs; 5.216 ms = the maximum of those per-keystroke minima | 200k names, 1 thread, **excluding** top-K selection: 3.941 ms = median of eleven query medians; 0.2–6.3 ms = range of query medians. Full paths: 43.9 ms median of query medians, up to 80.8 ms (a query median) | **Compatible, not comparable.** Neither figure is an observed worst case or p95 latency. Corpora, queries and statistics differ. Combined lesson: match names first. Full-path scoring at 200k does not fit a frame, so path search needs its own mode (Codex proposes typing `/`). |
| 10 | Configuration | Config file first, settings window later | Small settings window backed by versioned JSON. REQ-005 already says prefixes are "configurable in settings". | **Codex's position is the requirement.** v1 has versioned JSON plus a small native settings window. Starting with a file only would be a scope change, so the user decides whether to defer the window. |
| 11 | Default result mix | Kind priority apps > settings > folders > files, because `term` ranked two files above Terminal | Tiers plus bounded usage; result mix is a user decision | **Combined:** tiers first, kind priority within a tier; the default mix is a **user decision**. |
| 12 | Feature priority | Calculator, quicklinks, running-app and system commands in priority 1 | Calculator and quicklinks "next"; index status, exclusions editor and ranking reset first | **Open: user decision.** Both put aliases and file actions first. |
| 13 | Frecency formula | Tinycast's: +100 per open, 10-day half-life | Bounded log term, 30-day half-life, small weight | **Implementation detail.** Tune against golden examples during the build. |
| 14 | Settings icons | Content-type icons from `ISGraphicIconConfiguration` (as Tinycast does) | The extension's `IconName` resource, with fallback | **Unverified.** Test both in the settings spike. |
| 15 | TCC and signing | Ad-hoc signed rebuilds lose grants (stated as fact in the summary) | Unverified; add `NSOpenPanel` / security-scoped bookmarks | **Codex's position.** Test directly during development. |

## Findings only one report had

**Only Codex** (adopted into the recommendation):

- Enter must open the item the user can see selected, never an item that ranked into that row after a later update.
- Unicode, CJK and IME composition need a non-ASCII matching path; both benchmarks fold ASCII only.
- Licences: Tinycast is AGPL-3.0 and Albert is source-available with restrictions. Learn from their designs; don't copy code.
- Incremental narrowing must filter the previous complete match set, never the visible top K.
- Dataless iCloud files can trigger downloads if read; the crawler must not touch file contents.
- plocate-style trigram prefilters would reject acronym queries such as `vsc`.

**Only Claude:**

- A minimal hidden AppKit shell holding 23k names measured **18 MB `phys_footprint`** (as reported by `footprint`), with 0% CPU. It had no production index structures, icon cache, settings UI or active drawing. For context, Raycast's May 2026 figures are 200–450 MB, vendor-reported after usage, not a controlled comparison.
- The tested `mdfind` query did not find "Keyboard layouts", while `.searchTerms` provides a catalog that can be read directly. Whether settings items exist in other Spotlight stores was not established. Neither Tinycast nor Sol offers sub-items, so this is a gap Apparate can fill.
- Fully sorting all hits made one-letter queries the slowest keystroke; bounded top-K fixed it.
- Raycast's File Search manual describes its defaults: home folder + `/Applications`, name-only, honours `.gitignore`/`.ignore`, filters `node_modules` and caches.
- ⌘Space conflicts with Spotlight until its shortcut is disabled.

## Joint recommendation

Swift 6 + AppKit agent app (no Dock icon), one process:

- **Panel:** a non-activating `NSPanel` built at launch, with a search field and a fixed-row-height list.
- **Hotkey:** Carbon `RegisterEventHotKey`.
- **Sources:** apps from the application folders; settings panes and sub-items from `.searchTerms` in ExtensionKit extensions and legacy `.prefPane` bundles; files and folders from user-selected roots. Files are indexed by name only, persisted in SQLite, and kept current with FSEvents.
- **Query path:**
  1. Parse the configurable prefix (`'` files, `.` settings).
  2. A serial worker matches the scope with an fzy-style scorer, mask and pre-check.
  3. Results are ranked by tier, then kind and learned usage, and the top K is selected.
  4. The complete list is published once per current query generation.
- **Path search** gets its own mode instead of scoring every full path.
- **Config:** versioned JSON plus a small native settings window (REQ-005). Starting with the file only would need an explicit scope change (decision 2).

Before building the product, run two short spikes:

1. **Settings deep links:** for each `.searchTerms` group key, check whether `x-apple.systempreferences:<pane id>?<key>` opens the right section, and which icon source works.
2. **Panel latency and memory:** measure hotkey-to-first-frame, keystroke-to-results, and `phys_footprint` on a minimal build.

## Decisions for the user

1. **Default result mix:** what an unprefixed query searches, and in what order.
2. **Settings window:** keep it in v1 as REQ-005 states, or defer it and start with the JSON file.
3. **Hotkey:** take over ⌘Space, or use another chord.
4. **File roots:** which folders are indexed by default, and whether `.gitignore` is respected.
5. **v1 features** beyond the core: see differences 11 and 12.
6. **Performance budgets:** accept the targets and limits in difference 8.
7. **Minimum macOS version:** settings data, available APIs and testing scope depend on it (raised in Codex's risks).
8. **Distribution:** personal use, or public (Developer ID signing and notarization).
9. **Next step:** the spikes above, an implementation plan, or more research.
