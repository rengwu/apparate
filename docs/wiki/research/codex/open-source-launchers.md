---
title: Open-source launcher source review
section: Research
updated: 2026-11-18
---
# Open-source launcher source review

Supporting evidence for the [Codex research report](report.md). **Verified—source** means inspected source at the linked commit, not a running-app performance test. Repositories were shallow-cloned outside the project. No launcher was installed or built.

## Scope and freshness

| Project | Inspected HEAD date | Toolkit | Status at inspection |
| --- | --- | --- | --- |
| Sol | 2026-11-10 | TypeScript/React Native macOS, Swift/Objective-C native bridge | Active |
| Tinycast | 2026-11-18 | SwiftUI + AppKit | Active; AGPL-3.0 |
| Quicksilver | 2026-10-30 | Objective-C/Cocoa | Active; useful mature native reference |
| Albert | 2026-10-27 | C++/Qt | Active; **source-available**, not an unrestricted reuse candidate |
| Ueli | 2026-11-16 | TypeScript/React/Electron | Active |
| Kunkun | 2026-11-17 | Rust/Tauri + TypeScript/Svelte | Active |
| Flow Launcher | 2026-11-15 | C#/.NET/WPF | Active; inspected development branch |
| Loungy | 2025-10-05 | Rust/GPUI | Archived; replaced by Kunkun in the detailed comparison |
| FSearch | 2026-11-16 | C/GTK/GLib | Active; current development source |
| plocate | 2026-09-06 | C++/CLI | Official upstream inspected |

“Active” means recent source activity, not a maintenance guarantee. Albert's current license limits redistribution, including Apple-targeted binaries. Consult the actual [license](https://github.com/albertlauncher/albert/blob/c703546832dd8e7c961b74895d43b8d0cdadf7c8/LICENSE) before any reuse. Loungy's [README](https://github.com/MatthiasGrandl/Loungy/blob/303e7d2c46db13c49f8c7ca30762e5ee0ac582d2/README.md) confirms GPUI and discontinued development: it is not a Tauri example. Cerebro and Script Kit were not audited; this sample already covers native, Electron, Tauri, Qt, and Windows index integration.

## Native macOS references

### Sol

**Verified—source.** Apps are found by walking system, local, and user application directories, with alias handling and selected fixed locations. Metadata supplies localized names; this is not a Spotlight query for every keystroke. App-folder FSEvents trigger refreshes, with a 10-second stream latency and another debounce. [ApplicationSearcher.swift](https://github.com/ospfranco/sol/blob/873ae1c28b153f190a57a56a5ad2bea2159611f8/macos/sol-macOS/lib/ApplicationSearcher.swift)

Files use a private SQLite table containing path, name, folder flag, and parent path. A directory walk builds it; a separate FSEvents stream updates paths with 500 ms latency. These are update batching parameters, **not measured search latencies**. The current search executes `SELECT path, name, is_folder FROM files LIMIT 1000`, applies `NSString.scoreAgainst`, then sorts by name. That cap precedes matching and can exclude valid results anywhere beyond the first 1,000 rows. Serial `queue.sync` search can also wait behind indexing. [FileSearchIndex.swift](https://github.com/ospfranco/sol/blob/873ae1c28b153f190a57a56a5ad2bea2159611f8/macos/sol-macOS/lib/FileSearchIndex.swift), [FileSearchIndexer.swift](https://github.com/ospfranco/sol/blob/873ae1c28b153f190a57a56a5ad2bea2159611f8/macos/sol-macOS/lib/FileSearchIndexer.swift)

Root commands/apps live in JavaScript arrays and a MiniSearch index. Sorting uses relevance tiers, whether an item was selected, text score, selection timestamp/count, and name. The retained AppKit `NSPanel` uses React Native content and `isReleasedWhenClosed = false`; showing calls `makeKeyAndOrderFront`. [ui.store.tsx](https://github.com/ospfranco/sol/blob/873ae1c28b153f190a57a56a5ad2bea2159611f8/src/stores/ui.store.tsx), [Panel.swift](https://github.com/ospfranco/sol/blob/873ae1c28b153f190a57a56a5ad2bea2159611f8/macos/sol-macOS/views/Panel.swift), [PanelManager.swift](https://github.com/ospfranco/sol/blob/873ae1c28b153f190a57a56a5ad2bea2159611f8/macos/sol-macOS/managers/PanelManager.swift)

**Take:** resident window, prebuilt app corpus, background refresh, relevance tiers. **Do not copy:** pre-match row truncation or sharing the search queue with long scans. RAM and hotkey latency: unmeasured.

### Tinycast

**Verified—source.** The strongest directly relevant native reference. App discovery walks configured scopes, resolves paths, reads bundle/localized names, distinguishes duplicate installations, and prepares searchable fields before publishing the array. Its app catalog rescans on each open and on scope edits; unchanged entries avoid republishing. [AppIndex.swift](https://github.com/abue-ammar/tinycast/blob/99d1d17abfe591775f824a36981380e709278171/Tinycast/Features/Launcher/Service/AppIndex.swift), [SearchScopes.swift](https://github.com/abue-ammar/tinycast/blob/99d1d17abfe591775f824a36981380e709278171/Tinycast/Features/Launcher/Model/SearchScopes.swift)

Files use their own index. `getattrlistbulk` batches directory metadata. The snapshot is a read-only memory-mapped binary with interned names, name masks, compact integer arrays, directory bitmaps, and hierarchy offsets; full paths can be reconstructed. In-memory additions and tombstones cover changes until rebuild. A helper builds snapshots, and FSEvents replay starts from an event ID taken before the crawl. Root changes/wrapped IDs cause rebuilding; subtree flags drive rescanning. [FileIndexCrawler.swift](https://github.com/abue-ammar/tinycast/blob/99d1d17abfe591775f824a36981380e709278171/Tinycast/Features/FileSearch/Service/FileIndexCrawler.swift), [FileIndexSnapshot.swift](https://github.com/abue-ammar/tinycast/blob/99d1d17abfe591775f824a36981380e709278171/Tinycast/Features/FileSearch/Service/FileIndexSnapshot.swift), [FileIndex.swift](https://github.com/abue-ammar/tinycast/blob/99d1d17abfe591775f824a36981380e709278171/Tinycast/Features/FileSearch/Service/FileIndex.swift), [FileIndexer.swift](https://github.com/abue-ammar/tinycast/blob/99d1d17abfe591775f824a36981380e709278171/Tinycast/Features/FileSearch/Service/FileIndexer.swift), [FileIndexHelper.swift](https://github.com/abue-ammar/tinycast/blob/99d1d17abfe591775f824a36981380e709278171/Tinycast/Features/FileSearch/Helper/FileIndexHelper.swift)

App matching prepares folded UTF-16 and camel-case boundaries, then computes an alignment. Ranking explicitly combines aliases, fields, usage, and deterministic ties. File search has a separate prepared byte/token matcher and a 64-bit name mask; it is not the same algorithm as app fuzzy matching. Native `NSPanel`/`NSHostingView` content is retained between uses; Carbon hotkey registration is separate from optional event taps. [LauncherMatch.swift](https://github.com/abue-ammar/tinycast/blob/99d1d17abfe591775f824a36981380e709278171/Tinycast/Features/Launcher/Model/LauncherMatch.swift), [LauncherOrder.swift](https://github.com/abue-ammar/tinycast/blob/99d1d17abfe591775f824a36981380e709278171/Tinycast/Features/Launcher/Model/LauncherOrder.swift), [FileSearchQuery.swift](https://github.com/abue-ammar/tinycast/blob/99d1d17abfe591775f824a36981380e709278171/Tinycast/Features/FileSearch/Model/FileSearchQuery.swift), [PalettePanel.swift](https://github.com/abue-ammar/tinycast/blob/99d1d17abfe591775f824a36981380e709278171/Tinycast/Palette/PalettePanel.swift), [HotKeyCenter.swift](https://github.com/abue-ammar/tinycast/blob/99d1d17abfe591775f824a36981380e709278171/Tinycast/Features/HotKeys/Service/HotKeyCenter.swift)

**Take:** compact names/hierarchy, immutable snapshots, explicit update recovery, prepared strings. Its snapshot comment that clean mapped pages “never count as app memory” should not become an Apparate claim: mapped pages still consume resident/cache resources when accessed. Idle RAM and latency were not measured. The current app also has a much broader scope than its original minimal-launcher description.

### Quicksilver

**Verified—source.** Cocoa application source calls an `NSWorkspace` category that uses private `_LSCopyAllApplicationURLs`. This is evidence of one implementation, not a public-API recommendation. Its catalog stores arrays of objects and per-entry `.qsindex` files; file-system sources scan selected folders with configurable watch behavior and index validity checks. [NSWorkspace extensions](https://github.com/quicksilver/Quicksilver/blob/12d754357c538fd15dfa874970df99d378229f6d/Quicksilver/Code-QuickStepFoundation/NSWorkspace_BLTRExtensions.m), [QSCatalogEntry.m](https://github.com/quicksilver/Quicksilver/blob/12d754357c538fd15dfa874970df99d378229f6d/Quicksilver/Code-QuickStepCore/QSCatalogEntry.m), [QSFileSystemObjectSource.m](https://github.com/quicksilver/Quicksilver/blob/12d754357c538fd15dfa874970df99d378229f6d/Quicksilver/PlugIns-Main/QSCorePlugIn/Code/QSFileSystemObjectSource.m)

The default ranker normalizes strings, computes abbreviation scores, and layers explicit/learned query mnemonics and usage counts. Its window controller loads the window and subsequently shows/orders it out. Watcher backend and exhaustive catalog refresh triggers were not audited. [QSStringRanker.m](https://github.com/quicksilver/Quicksilver/blob/12d754357c538fd15dfa874970df99d378229f6d/Quicksilver/Code-QuickStepCore/QSStringRanker.m), [QSObjectRanker.m](https://github.com/quicksilver/Quicksilver/blob/12d754357c538fd15dfa874970df99d378229f6d/Quicksilver/Code-QuickStepCore/QSObjectRanker.m), [QSInterfaceController.m](https://github.com/quicksilver/Quicksilver/blob/12d754357c538fd15dfa874970df99d378229f6d/Quicksilver/Code-QuickStepInterface/QSInterfaceController.m)

**Take:** learn query-to-item intent, cache a limited catalog, preserve stable IDs. Memory and latency: unmeasured.

## Cross-platform references

### Albert

**Verified—source.** macOS application plugin walks known app roots and uses `QFileSystemWatcher`; Linux uses desktop-entry discovery. Files have a private directory tree persisted as JSON, selected-root/depth/exclusion policies, optional directory watches, and periodic rescan timers. This is not Spotlight-backed file search. [mac/plugin.cpp](https://github.com/albertlauncher/albert-plugin-applications/blob/2c4738009b91f8ceb4cf25b2de04490b3691fa76/src/mac/plugin.cpp), [xdg/plugin.cpp](https://github.com/albertlauncher/albert-plugin-applications/blob/2c4738009b91f8ceb4cf25b2de04490b3691fa76/src/xdg/plugin.cpp), [fsindexnodes.h](https://github.com/albertlauncher/albert-plugin-files/blob/74435c5f60858f65ff3d3c6cf9a01a45940caf3a/src/fsindexnodes.h), [fsindexpath.cpp](https://github.com/albertlauncher/albert-plugin-files/blob/74435c5f60858f65ff3d3c6cf9a01a45940caf3a/src/fsindexpath.cpp)

Search keeps flat item/string arrays, a word-to-occurrence inverted index, and a bigram map; Levenshtein-based fuzzy word matching is different from fzf-style subsequences. SQLite stores activations; ranking derives decayed usage weights by activation order. The Qt frontend owns a window and toggles visibility. [itemindex.cpp](https://github.com/albertlauncher/albert/blob/c703546832dd8e7c961b74895d43b8d0cdadf7c8/src/util/itemindex.cpp), [usagedatabase.cpp](https://github.com/albertlauncher/albert/blob/c703546832dd8e7c961b74895d43b8d0cdadf7c8/src/query/usagedatabase.cpp), [frontend plugin.cpp](https://github.com/albertlauncher/albert-plugin-widgetsboxmodel/blob/d7476bf16747e058af62e153d0327e53d1bc0761/src/plugin.cpp)

**Take:** root-specific index policy and measured need before introducing an inverted index. Do not assume an edit-distance word matcher guarantees `VSC`. Performance: unmeasured. The archived monolithic plugins repository was superseded by dedicated plugin repositories; those were inspected here.

### Ueli

**Verified—source.** macOS apps come from `mdfind`, filtered to configured folders and excluding nested `.app` paths. “Simple File Search” independently enumerates chosen folders into `SearchResultItem[]`, resolving types/icons during collection. The rescan orchestrator defaults to 300 seconds when enabled; no FSEvents watcher was identified in these paths. [MacOsApplicationRepository.ts](https://github.com/oliverschwendener/ueli/blob/94104292d82b95dfa9300a432dd2ad45d41c2e28/src/main/Extensions/ApplicationSearch/macOS/MacOsApplicationRepository.ts), [SimpleFileSearchExtension.ts](https://github.com/oliverschwendener/ueli/blob/94104292d82b95dfa9300a432dd2ad45d41c2e28/src/main/Extensions/SimpleFileSearch/SimpleFileSearchExtension.ts), [RescanOrchestrator.ts](https://github.com/oliverschwendener/ueli/blob/94104292d82b95dfa9300a432dd2ad45d41c2e28/src/main/Core/RescanOrchestrator/RescanOrchestrator.ts)

The renderer searches arrays with selectable fuzzysort/Fuse.js, then groups favorites and instant results. This reviewed sort is not verified frecency. Electron creates one search `BrowserWindow`, then toggles it. [fuzzySortFilter.ts](https://github.com/oliverschwendener/ueli/blob/94104292d82b95dfa9300a432dd2ad45d41c2e28/src/common/Core/Search/fuzzySortFilter.ts), [getSearchResult.ts](https://github.com/oliverschwendener/ueli/blob/94104292d82b95dfa9300a432dd2ad45d41c2e28/src/renderer/Core/Search/Helpers/getSearchResult.ts), [SearchWindowModule.ts](https://github.com/oliverschwendener/ueli/blob/94104292d82b95dfa9300a432dd2ad45d41c2e28/src/main/Core/SearchWindow/SearchWindowModule.ts)

**Take:** collect outside the query path. Avoid eager per-file icon work and polling as the sole update mechanism. Memory and latency: unmeasured.

### Kunkun

**Verified—source.** The Rust `applications-rs` library maintains `Arc<Mutex<Vec<App>>>`; its macOS path combines application discovery with filesystem search and Spotlight helpers. Tauri exposes explicit synchronous/background refresh commands. Frontend app arrays are fed to Fuse.js. [common.rs](https://github.com/HuakunShen/applications-rs/blob/04306329f02afb31a8cfc4cd67ce1f8d11d9c4b1/src/common.rs), [mac.rs](https://github.com/HuakunShen/applications-rs/blob/04306329f02afb31a8cfc4cd67ce1f8d11d9c4b1/src/platforms/mac.rs), [macOS utilities](https://github.com/HuakunShen/applications-rs/blob/04306329f02afb31a8cfc4cd67ce1f8d11d9c4b1/src/utils/mac.rs), [apps.rs](https://github.com/kunkunsh/kunkun/blob/d4383c5edfb6c7700f34fb5fba1e4202aefb7902/packages/tauri-plugins/jarvis/src/commands/apps.rs), [apps.ts](https://github.com/kunkunsh/kunkun/blob/d4383c5edfb6c7700f34fb5fba1e4202aefb7902/apps/desktop/src/lib/stores/apps.ts)

The reviewed file-search command builds a `rust_search::SearchBuilder` for supplied locations and collects results. It does not maintain a persistent file index in that command. Tauri keeps the main WebView window and toggles show/hide. No automatic file watcher or frecency formula was established in these inspected paths; extensions may behave differently. [file_search.rs](https://github.com/kunkunsh/kunkun/blob/d4383c5edfb6c7700f34fb5fba1e4202aefb7902/packages/tauri-plugins/jarvis/src/commands/file_search.rs), [desktop lib.rs](https://github.com/kunkunsh/kunkun/blob/d4383c5edfb6c7700f34fb5fba1e4202aefb7902/apps/desktop/src-tauri/src/lib.rs)

**Take:** native APIs behind a small interface. Tauri's use of a system WebView does not itself establish low memory or keystroke latency. Both are unmeasured.

## Windows references

**Verified—source.** Flow Launcher caches Win32/UWP program lists. Win32 discovery includes Start Menu, registry, PATH, and configured sources, with `FileSystemWatcher` updates. Its matcher has acronym handling plus fuzzy scoring, and the main result pipeline adds selected-count and plugin-priority scores. WPF window visibility is toggled while the application stays alive. [Program/Main.cs](https://github.com/Flow-Launcher/Flow.Launcher/blob/58b799721a343811d8c42046cb2b4d63de1b3da6/Plugins/Flow.Launcher.Plugin.Program/Main.cs), [Win32.cs](https://github.com/Flow-Launcher/Flow.Launcher/blob/58b799721a343811d8c42046cb2b4d63de1b3da6/Plugins/Flow.Launcher.Plugin.Program/Programs/Win32.cs), [StringMatcher.cs](https://github.com/Flow-Launcher/Flow.Launcher/blob/58b799721a343811d8c42046cb2b4d63de1b3da6/Flow.Launcher.Infrastructure/StringMatcher.cs), [MainViewModel.cs](https://github.com/Flow-Launcher/Flow.Launcher/blob/58b799721a343811d8c42046cb2b4d63de1b3da6/Flow.Launcher/ViewModel/MainViewModel.cs)

Its Explorer plugin delegates to either Windows Search or Everything. Everything has SDK/IPC adapters, a result cap, full-path options, and optional run-count sorting. Flow does not build Everything's filesystem index. [EverythingSearchManager.cs](https://github.com/Flow-Launcher/Flow.Launcher/blob/58b799721a343811d8c42046cb2b4d63de1b3da6/Plugins/Flow.Launcher.Plugin.Explorer/Search/Everything/EverythingSearchManager.cs), [WindowsIndexSearchManager.cs](https://github.com/Flow-Launcher/Flow.Launcher/blob/58b799721a343811d8c42046cb2b4d63de1b3da6/Plugins/Flow.Launcher.Plugin.Explorer/Search/WindowsIndex/WindowsIndexSearchManager.cs)

**Verified—official docs.** PowerToys Run's built-in file provider uses the Windows Search Index service; Everything is a separate integration, not proof that Run privately indexes every file. Its docs expose input smoothing and different plugin delays—potential sources of delayed results. [PowerToys Run](https://learn.microsoft.com/windows/powertoys/run). Neither launcher's memory nor latency was measured here.

## File engines

| Engine | Verified design | Matching/ranking and relevance to Apparate |
| --- | --- | --- |
| Everything | Closed source. Official docs: resident filename/path database, NTFS USN Journal updates; optional metadata costs memory. Folder indexing is a slower alternative with monitoring and rescans. | Search/filter and selectable sort/run history, not a verified fzy-style scorer. Windows NTFS machinery is not portable to APFS. Keep the narrow metadata scope and resident index idea. |
| plocate | C++; `updatedb` scan/reuse; trigram posting lists select compressed filename blocks, Zstd decompresses candidates, optional Linux `io_uring` feeds reads. | Substring/glob/regex filtering, not acronym fuzzy ranking or frecency. Contiguous trigram intersections are unsafe as a required filter for `VSC` → Visual Studio Code. No resident launcher window. |
| FSearch | C/GTK; own scanned database, parent/name entries, sorted chunked arrays per property, parallel search workers. Current source includes inotify/fanotify monitoring and rescan recovery. | Filename/path substring/regex/query functions and column sorting; no learned launcher frecency established. Useful cache locality and result-view design; GUI is not a hotkey palette. |

Sources: [Everything index](https://www.voidtools.com/support/everything/indexes/), [Everything FAQ](https://www.voidtools.com/faq/), [folder indexing](https://www.voidtools.com/support/everything/folder_indexing/); [plocate upstream](https://git.sesse.net/?p=plocate;a=tree;h=cc0423b00042f51b648d0fb7cdadffc62c0b0daf), files `database-builder.cpp`, `plocate.cpp`, `updatedb.cpp`, `README`; [FSearch index store](https://github.com/cboxdoerfer/fsearch/blob/74295de2f4a576c41b8df70957934c77ae255363/src/fsearch_database_index_store.c), [scan](https://github.com/cboxdoerfer/fsearch/blob/74295de2f4a576c41b8df70957934c77ae255363/src/fsearch_database_scan.c), [inotify](https://github.com/cboxdoerfer/fsearch/blob/74295de2f4a576c41b8df70957934c77ae255363/src/fsearch_folder_monitor_inotify.c), [fanotify](https://github.com/cboxdoerfer/fsearch/blob/74295de2f4a576c41b8df70957934c77ae255363/src/fsearch_folder_monitor_fanotify.c), [query matchers](https://github.com/cboxdoerfer/fsearch/blob/74295de2f4a576c41b8df70957934c77ae255363/src/fsearch_query_matchers.c).

**Published figures, not local measurements:** Everything's current FAQ gives about 35 MB RAM and five seconds initial indexing for approximately 250,000 Windows 11 entries, and about one minute for one million entries. Hardware/settings are not specified sufficiently for comparison. There are no comparable locally measured numbers for the audited launchers. Apparate's [matching benchmark](benchmark.md) measures a scorer, not these products.

## What Apparate should take from this

1. Keep one native panel and prepared app/settings records alive; no discovery, subprocess, or icon extraction per keystroke.
2. Own a filename-only index for user-selected roots; batch filesystem changes and recover from missed events.
3. Match basenames first; keep compact parent/name storage and load only visible icons.
4. Separate index mutation from immutable search snapshots; discard obsolete query generations.
5. Rank exact/prefix/acronym tiers before bounded learned preferences, with stable IDs and deterministic ties.
6. Measure at 20k and 200k entries before adding helper processes, mmap formats, or more indexes.
