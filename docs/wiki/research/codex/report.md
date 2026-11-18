---
title: Codex research report
section: Research
updated: 2026-11-18
---
# Codex research report

Independent research for Apparate's [requirements](../../requirements.md), completed 2026-11-18. This report covers the full brief. Claude's independent report was not read before writing it. Earlier shared pointers were checked against primary sources. No product code or packages were added to the project.

**Evidence labels:** **Verified—source/docs** means inspected source or official documentation; **Measured** means executed here; **Recommendation** is a proposed design; **Unverified** identifies a remaining gap. Source evidence establishes implementation, not end-to-end performance.

Supporting pages: [launcher source review](open-source-launchers.md), [fuzzy matching](fuzzy-matching.md), [Swift benchmark and reproduction code](benchmark.md).

## Summary

- **Recommendation:** Swift with an AppKit `NSPanel`, native search field/list, and SwiftUI settings. Keep one small window resident. A cross-platform web runtime adds little value for this macOS-only scope.
- **Recommendation:** maintain a private filename/path index for selected folders, with cached app and settings catalogs. Keep Spotlight available for optional metadata/content search later.
- **Verified—source:** fast launchers commonly prepare catalogs before typing and retain their search window. Native and web-based launchers both do this; toolkit alone does not establish speed.
- **Verified—docs:** Raycast v1 used Spotlight file search; v2 introduced a separate Rust file indexer. Alfred still uses macOS metadata plus an application cache. LaunchBar scans configured indexing rules.
- **Measured:** at 200k candidates, a simple Swift basename scorer with a character mask took 0.20–6.31 ms across eleven queries. Scoring entire paths took 0.47–80.82 ms. Field choice and selectivity are decisive.
- **Recommendation:** fzy-like matching with explicit acronym/word-start tiers, bounded usage learning, deterministic ties, and one publication per query generation. This directly addresses `VSC` and result jumping.
- **Verified locally:** “Keyboard layouts” exists in Keyboard's `.searchTerms` metadata under `InputSources`. **Unverified:** the proposed deep link's actual destination and universal anchor support.
- **Recommendation:** name/path indexing only, visible-row icon loading, one process initially, and no permanent polling. Treat memory and perceived latency budgets below as targets awaiting an app prototype.

## How existing launchers are fast

**Raycast — verified official architecture, author-reported memory.** v1 used Swift/AppKit with a Node extension backend. v2 uses native shells, system WebViews, React/TypeScript, Node, and Rust. It keeps its main WebView ready by controlling visibility/throttling and pre-rendering the expanded layout. Its new file indexer runs separately, scans directly, and follows filesystem events; Windows uses a dedicated NTFS MFT scanner. The May 2026 article reports roughly 200–300 MB for v1 versus 350–450 MB for v2 after usage, not a controlled benchmark. Later releases changed performance, so these are historical figures, not measurements of today's build. The article does not disclose the private index's complete data structure or prove macOS uses a particular FSEvents API. [Raycast technical deep dive](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast), [current changelog](https://www.raycast.com/changelog).

**Alfred — verified docs.** Restricting default result scope avoids unnecessary noise/work; broad file search is explicitly invoked. Applications are cached separately and can be reloaded. File search depends on the system metadata index and its exclusions/health. Faster UI than Spotlight does not imply a separate disk index. Exact matcher, memory layout, window class, and comparable latency/RAM figures remain unverified. [Alfred indexing troubleshooting](https://www.alfredapp.com/help/troubleshooting/indexing/).

**LaunchBar — verified docs.** Indexing rules decide which apps, folders, and other sources are searched; file rules scan chosen directories with depth/package controls. Updates can happen at launch or periodically, with additional rule-specific behaviours. That bounded catalog supports abbreviation search. Exact structures, filesystem watcher backend, and measured latency/memory were not established. [Indexing rules](https://www.obdev.at/resources/launchbar/help/IndexingRules.html), [files and folders](https://www.obdev.at/resources/launchbar/help/FilesAndFolders.html), [index update settings](https://help.obdev.at/resources/launchbar/help/IndexWindow.html).

**Spotlight 26/27 — verified product docs, internal performance unverified.** Tahoe expanded Spotlight into app/file/action/clipboard browsing with App Intents actions. Current macOS 27 help also describes broader search and Siri interaction. Neither source specifies the scoring implementation or explains the user's experienced delay. It is not sound to blame all delay on metadata indexing without measuring UI, query, and provider timing separately. [Apple's Tahoe announcement](https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/), [macOS 27 Spotlight guide](https://support.apple.com/guide/mac-help/find-what-you-need-with-spotlight-mchlp1008/27/mac/27).

**Open-source/source-available — verified source.** Sol and Tinycast retain `NSPanel` instances. Quicksilver retains Cocoa UI and a catalog. Ueli retains an Electron `BrowserWindow`; Kunkun retains a Tauri WebView; Albert toggles a retained Qt window; Flow retains WPF UI and cached program lists. Their relevant implementations, ranking, update triggers, and limitations are detailed in the [source review](open-source-launchers.md). No claim that one is faster than another is based on local launch timing.

Tinycast is particularly useful for compact filename snapshots and recovery from filesystem changes. Sol is a cautionary example: its current file search limits to 1,000 rows **before matching**. Albert's current restrictive license also means available source must not be mistaken for freely reusable macOS product code.

## How they index apps and files

| Approach | Verified examples | Implication for Apparate |
| --- | --- | --- |
| OS metadata index | Alfred files, Raycast v1 files, Ueli macOS app discovery; Kunkun's macOS app discovery starts with `mdfind` and adds configured filesystem paths | Minimal private indexing effort, but coverage/freshness follows the OS index. A UI can cache and rank results independently. |
| Private bounded catalog | LaunchBar folder rules, Quicksilver catalog, Albert file trees, Ueli Simple File Search | Good fit for selected roots; background scans need explicit update and recovery policies. |
| Private event-updated filename index | Sol SQLite/FSEvents; Tinycast binary snapshot + changes; Raycast v2 private index | Search can be independent of Spotlight. Correctness requires handling missed events, moves, permissions, and cold starts. |
| External service | Flow's Everything or Windows Search provider; PowerToys Run's built-in Windows Search provider | A launcher may inherit speed and memory cost from another process. Count the whole system when comparing. |

The [source review](open-source-launchers.md) provides pinned paths for each row.

**Reference engines:** Everything documents a resident filename/path database and NTFS USN updates; its folder indexing follows a different scan/monitor/rescan path. plocate uses trigram posting lists and compressed filename blocks, updated by scans. FSearch's current development source uses private entries, sorted chunked arrays, worker searches, and Linux filesystem monitors. These are useful storage designs, not interchangeable fuzzy engines. A contiguous-trigram prefilter would reject valid acronym queries. NTFS MFT/USN techniques do not transfer directly to APFS. [Engine evidence](open-source-launchers.md#file-engines).

**Recommendation:** own the narrow index the requirements need. Keep name, parent/root identity, type, stable ID, normalized search text, and a character mask. Do not index file contents. Start with SQLite persistence plus an immutable in-memory search representation; use compact parent/name storage as corpus size grows. FTS5 token matching alone does not satisfy arbitrary subsequences or `VSC`.

## macOS platform

**Metadata queries — verified docs.** `NSMetadataQuery` is the Foundation interface to Spotlight metadata; `MDQuery` is its lower-level counterpart. Queries gather asynchronously, can be scoped to selected locations, and can remain live. Batch notifications require explicit result-generation handling. A launcher need not spawn `mdfind` for every keystroke. Use a long-lived query to enrich a background catalog if needed; direct filenames should remain searchable when Spotlight excludes a selected root. [Apple metadata query guide](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/SpotlightQuery/Concepts/QueryingMetadata.html).

**Enumeration — verified docs/source.** Start with `FileManager.enumerator(at:includingPropertiesForKeys:options:errorHandler:)`, request only necessary properties, and skip descendants for excluded directories/packages. Define symlink and mount traversal deliberately. `getattrlistbulk` is a lower-level optimization used by Tinycast; it increases implementation complexity and is unnecessary until enumeration is measured as a bottleneck. Cloud/dataless files can cause unexpected materialization; keep filesystem work off the main thread and avoid content reads. [FileManager enumeration](https://developer.apple.com/documentation/foundation/filemanager/enumerator(at:includingpropertiesforkeys:options:errorhandler:)), [Apple dataless-file guidance](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files), [Tinycast crawler](open-source-launchers.md#tinycast).

**Change tracking — verified docs; recovery policy recommended.** FSEvents provides batched change hints, not an infallible journal of every file operation. Capture the stream/checkpoint before the initial scan and reconcile events that occur during it. Rescan affected subtrees for `MustScanSubDirs`; dropped events, wrapped IDs, root movement, or invalid checkpoints require a broader reconciliation. Persist checkpoints only with the corresponding durable index state. Revalidate on wake, remount, policy changes, and occasional integrity sweeps. Coalesce build-tool churn and keep UI refresh separate. [Apple FSEvents guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).

**Permissions — verified docs.** TCC still applies outside App Sandbox. Desktop, Documents, Downloads, iCloud Drive, and network locations may require consent. Let users select roots through `NSOpenPanel`; if sandboxed, use read-only security-scoped bookmarks and balance access calls, including stale-bookmark repair. Selected-folder access does not override every other protection. Full Disk Access should not be a default requirement for a selected-folder launcher. Accessibility is not a prerequisite for simply opening apps/files; optional UI automation/window features have different needs. [Apple file-access privacy](https://support.apple.com/en-ie/guide/security-pdf/secddd1d86a6/web), [sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).

**Hotkey/window — recommendation backed by inspected native implementations.** Use Carbon `RegisterEventHotKey` for a normal configurable global shortcut, handle registration failure/conflicts, and keep the search field on the main thread. Global `NSEvent` keyboard monitoring has Accessibility requirements and is not equivalent to exclusive hotkey registration. Do not request that permission for the basic launcher. Test keyboard layouts, IME composition, Spaces/fullscreen, multiple displays, and focus restoration. [Tinycast hotkey source](https://github.com/abue-ammar/tinycast/blob/99d1d17abfe591775f824a36981380e709278171/Tinycast/Features/HotKeys/Service/HotKeyCenter.swift), [Apple event monitor documentation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html). A retained nonactivating `NSPanel` that can become key is the proposed shell; exact activation/Space behaviour remains to be prototyped.

**Icons/opening — verified APIs; caching recommended.** `NSWorkspace.icon(forFile:)` supplies file/app icons and is callable off the main thread. Cache small rendered images by identity/change stamp, request only visible rows plus a small prefetch, and use generic type icons immediately. Launch apps using `NSWorkspace.openApplication(at:configuration:)`; open files/folders with the workspace URL APIs. Do not construct shell command strings from paths. Surface launch errors and revalidate stale entries. [Icons](https://developer.apple.com/documentation/appkit/nsworkspace/icon(forfile:)), [app launch](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:)).

## System Settings items

**Verified locally.** The machine contains:

```text
/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex/
  Contents/Info.plist
  Contents/Resources/en.lproj/Keyboard.searchTerms
```

The bundle ID is `com.apple.Keyboard-Settings.extension`. Under `EXAppExtensionAttributes.SettingsExtensionAttributes`, the plist names `searchTermsFileName: Keyboard`, `IconName: icon`, `allowsXAppleSystemPreferencesURLScheme: true`, and the legacy identifier `com.apple.preference.keyboard`.

The `.searchTerms` plist groups `localizableStrings` under anchor keys. `InputSources` contains title `Keyboard layouts` and keywords such as QWERTY, Dvorak, languages, and typing. My direct `en.lproj` pass found 41 files/688 entries; that is a specific scan scope, not a guarantee of total settings coverage. The earlier shared inventory reported 42/691. **Post-comparison verification:** an additional legacy file, `/System/Library/PreferencePanes/DateAndTime.prefPane/Contents/Resources/en.lproj/DateAndTimePref.searchTerms`, contains three entries. That reconciles 42/691 across ExtensionKit plus legacy panes; 41/688 remains correct for the original ExtensionKit-only pass.

**Recommendation:** read these data resources without loading extension code. Respect the user's preferred language with explicit fallback; cache by OS build and locale. Preserve title, synonyms, owning pane, anchor, and provenance. Deduplicate duplicate localized records and provide stable IDs. Index title/acronym separately from lower-weight keywords.

**Unverified navigation candidate:**

```text
x-apple.systempreferences:com.apple.Keyboard-Settings.extension?InputSources
```

Bundle metadata supports participation in this URL scheme; it does **not** establish that every group key opens a working anchor on every macOS version. A direct UI navigation test could not be completed because the browser host was unavailable. App inspection succeeded, but no deep-link destination was verified. Test known anchors on each supported OS; fall back to the parent pane when a route is unsupported. API success only proves dispatch, not that the correct sub-item opened. These resources and anchors are an observed system convention, not a documented stable public catalog API.

**Icons:** the extension's `IconName` points to its resource/asset name. Try that bundle resource with a cached fallback to its workspace icon or a generic settings symbol. **Post-comparison verification:** Keyboard also declares `CFBundleIcons.ISGraphicIconConfiguration.ISTypeIdentifier = com.apple.graphic-icon.keyboard`; a content-type icon is another useful route. Correct icon extraction across all panes is unverified. Do not embed a permanent hand-maintained copy of hundreds of current English strings; use a small compatibility map only where testing proves it necessary.

Reproduce the metadata inspection without changing settings:

```python
from pathlib import Path
import plistlib
bundle = Path('/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex')
info = plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
attrs = info['EXAppExtensionAttributes']['SettingsExtensionAttributes']
terms = bundle/'Contents/Resources/en.lproj'/f"{attrs['searchTermsFileName']}.searchTerms"
print(info['CFBundleIdentifier'], attrs)
print(plistlib.loads(terms.read_bytes())['InputSources'])
```

## Fuzzy matching and ranking

**Verified—source comparison:** fzf v1 is a fast greedy scan; fzf v2, fzy, nucleo, SkimMatcherV2, and VS Code's `fuzzyScore` use richer alignments. fzy is the simplest suitable Swift starting point; nucleo provides stronger optimization/Unicode examples. Sublime's exact implementation is proprietary; public approximations must be labelled as such. Alfred documents initial-letter matching; Raycast documents fuzzy titles, aliases, and usage learning. [Full comparison and sources](fuzzy-matching.md).

**Recommendation:** preserve original word/camel-case boundaries, fold for comparison, and use exact → prefix → word/acronym → substring → general subsequence tiers. Limit history's influence within comparable match quality. `VSC` must work without manual aliases. Make non-ASCII matching/grapheme highlighting explicit; the experiment's ASCII path is insufficient for production.

**Measured:** median of eleven query medians, milliseconds:

| Candidates | Full paths + mask | Basenames + mask |
| --- | --- | --- |
| 1,000 | 0.216 | 0.011 |
| 20,000 | 4.492 | 0.266 |
| 200,000 | 43.863 | 3.941 |

Across queries at 200k, basename+mask ranged from 0.201 to 6.312 ms; full paths ranged from 0.474 to 80.823 ms. The corpus repeats 13,746 real names/paths to reach 200k, and measurement excludes sorting/UI/indexing. The harness's high allocation footprint is disclosed separately; it is not a production memory estimate. [Benchmark method, per-query values, and source](benchmark.md).

**Result stability:** search a consistent snapshot, publish a complete ranked batch, and drop obsolete generations. Keep row geometry fixed and selected IDs stable once the user navigates. History updates after successful actions, not while a query remains visible. Re-ranking across *different* queries is legitimate; late results shifting a fixed query or Enter target are not. Never incrementally filter only the previous visible top-K.

## Recommended architecture

**Proposal, not an accepted implementation decision.** One Swift executable with a retained AppKit palette; SwiftUI is suitable for settings. Swift is already available and directly supports the required platform APIs. Go/Rust can implement a fast index, but introduce bridging/build/runtime choices that this scope has not justified. Use Rust/nucleo later only if a measured Swift bottleneck remains after field selection and allocation fixes.

| Component | Proposed design |
| --- | --- |
| UI | `NSPanel`, native search field and reusable list rows; fixed icon slots and list geometry. Construct once; hide between uses. |
| Query | Parse user-configurable `'` file/folder and `.` settings prefixes before matching. Unprefixed input searches apps/settings/files in one snapshot. Escape/literal-prefix behaviour must be specified. |
| Apps | Scan standard app roots and explicitly included app directories; skip bundle internals, resolve aliases carefully, retain localized/alternate names. Use filesystem/workspace changes to refresh; optional metadata enrichment stays off the query path. |
| Settings | Small versioned locale-aware catalog from system extension metadata, with tested routes and parent fallbacks. |
| Files | User-selected roots only; default exclusions for dependency/VCS/build trees; persistent SQLite records and compact immutable search arrays. Separate basename and path search fields. |
| Concurrency | One process initially. UI on main actor; bounded utility indexing queue; serial cancellable search worker with reusable scratch. Swap complete snapshots atomically. No disk work under the query lock. |
| Updates | Batched FSEvents, subtree reconciliation, durable checkpoint/recovery, and clear index status. Bound old snapshots and pending change buffers during large rebuilds. |
| Search | Prepared normalized names/boundaries, 64-bit mask, subsequence check, fzy-like score, top-K heap/selection, stable tie-break. Path-aware narrowing for `/` queries; no arbitrary pre-match cap. |
| Config/history | Versioned Codable JSON for prefixes, roots, exclusions, aliases, and UI preferences; opaque bookmarks persisted separately. SQLite for index and bounded local usage records. Atomic config saves; explicit reset/rebuild actions. |
| Launch | Typed app/file/settings actions using workspace APIs, with error handling. Cache only the icon working set. |

**Proposed budgets, all unverified until an app exists:**

| Metric | Initial target on this M1 Pro |
| --- | --- |
| Warm hotkey to first presented frame | p95 ≤33 ms; inspect 60/120 Hz separately |
| Query to stable displayed results | p95 ≤16 ms for ordinary app/settings and 20k-name searches; ≤33 ms at 200k names |
| File-index event freshness | Usually within 1–2 seconds after a local change; correctness recovery may take longer |
| Idle CPU/energy | No continuous scan/polling; near-zero CPU when no files change |
| Warm memory footprint | Aim ≤60 MiB at 20k files and ≤100 MiB at 200k, with bounded icon cache; measure footprint and total child-process cost |

These are engineering targets, not forecasts guaranteed by the microbenchmark. Cold start, first indexing, Unicode/path searches, remote/cloud roots, UI drawing, and sorting must be measured separately. An approximate compact-index calculation—names plus parent IDs, flags, masks and records in tens of MB at 200k—supports prototyping, but does not establish the AppKit application's footprint.

Start with correctness at the actual ~13k selected-project scale. Add mmap snapshots, compacted name interning, bulk syscalls, parallel scoring, or a crash-isolated index helper only when measurements show the simpler design misses a requirement. Keep filename indexing independently replaceable so those changes do not alter the UI contract.

## Additional feature suggestions

| Priority | Feature | Reason |
| --- | --- | --- |
| First | Explicit aliases and pinning | Predictable shortcuts for ambiguous names; low resource cost. |
| First | Reveal in Finder, copy path, open with | Natural actions on existing results; minimal added indexing. |
| First | Index status, excluded-folder editor, rebuild/reset ranking | Makes missing/stale results diagnosable. |
| Next | Calculator and unit conversion | High utility, no filesystem expansion; keep it local and optional. |
| Next | Recent files and configurable quick links | Uses existing IDs/history; avoid a second catalog. |
| Later | Quick Look on demand | Useful verification before opening; load only when requested. |
| Later | Explicit Shortcuts/script actions | Powerful, but require action semantics and clear permissions. |
| Defer | Clipboard history, global menu search, window management | Add data retention, background work, or Accessibility requirements beyond the core request. |
| Defer | AI, cloud sync, extension store | Large runtime/product scope; no requirement justifies them yet. |

## Risks and open questions

- **Needs user choice:** default hotkey and Spotlight conflict, minimum macOS version, direct distribution versus App Store, default result mix, selected roots/exclusions, basename versus implicit full-path search, and whether hidden/package/cloud/network content is included. These should be resolved after comparing the two reports.
- **Settings compatibility:** test the actual “Keyboard layouts” route, not merely URL opening, and test ExtensionKit plus legacy-pane coverage. Some anchors may be dynamic, gated by hardware, or obsolete.
- **Index correctness:** renames/moves, symlinks, permission revocation, root removal, event loss, crash recovery, mount identity, and incomplete cloud directories need adversarial tests. A full scan and persistent journal are different responsibilities.
- **Matching quality:** Unicode case/diacritics, CJK names, IME composition, duplicate installs, acronym conflicts, and history reset require acceptance examples. A copied VS Code 128-unit limit would break long paths.
- **Memory/perceived speed:** big icon sets, duplicated string buffers, overlapping snapshots, and indexing contention can dominate a fast scorer. Test slow filesystem providers and active build churn with UI frame timing.
- **Source reuse:** Tinycast is AGPL; Albert has a restrictive custom license; nucleo is MPL and fzf/fzy are MIT in inspected repositories. Read upstream licenses before choosing code reuse. This report recommends designs, not importing those projects wholesale.
- **Evidence gaps:** no controlled Raycast/Alfred/LaunchBar/Spotlight latency/RAM comparison, no built Apparate UI, no universal settings-anchor verification, and no cross-algorithm local benchmark. Do not present proposed budgets as achieved performance.

## Sources

The report links claims directly to official docs and pinned source. The [source review](open-source-launchers.md) records repository dates, source paths, indexing, matching, and window strategies; [matching analysis](fuzzy-matching.md) cites exact algorithms; [benchmark](benchmark.md) contains the executed Swift/Python source and measured results.

Primary platform references are Apple's metadata/FSEvents guides, FileManager/NSWorkspace documentation, App Sandbox and TCC guidance, and locally inspected system plists. Commercial-product evidence comes from Raycast's engineering article/manual, Alfred help, Objective Development's LaunchBar help, and Apple Spotlight documentation. Closed-source internals not disclosed by those sources remain unverified.
