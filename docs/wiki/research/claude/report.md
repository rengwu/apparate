---
title: Claude research report
section: Research
updated: 2026-11-18
author: Claude (Claude Code, Opus 5.5)
---
# Claude research report

Claude's independent research for Apparate, written in parallel with Codex's report. The two are compared in the alignment page. Confidence labels: **verified** means read in source code or official docs, or measured on this machine. **Unverified** means a secondary source or inference.

Supporting page: [matching benchmark](benchmark.md) (method, numbers, and source).

## Summary

- **Our own scorer is cheap; Spotlight was not measured.** A Swift fzy-style scorer matches ~20k names in about 0.13 ms per keystroke on this Mac (verified, measured). That does not measure Spotlight's matching, and Spotlight's pipeline was not profiled. Suspected causes are the per-keystroke query to a system daemon and the merge of results that arrive asynchronously from several providers. That is **inference** (corrected after review; the first version stated it as fact).
- **The fast launchers prepare what they search before the user types, and keep the window alive.** How they get results varies. Alfred queries the Spotlight index for files (verified, Alfred docs). Flow Launcher calls Everything over IPC. Raycast 2.0 moved file search off Spotlight to its own Rust indexer that follows "file system events" (verified, Raycast blog, May 2026; that it uses the FSEvents API specifically is inference). LaunchBar keeps its own rule-based index (verified, docs). Tinycast builds a memory-mapped index with `getattrlistbulk` and FSEvents (verified, source). Cross-process calls are not slow in themselves; what matters is predictable latency and publishing one complete result set (corrected after review).
- **Apparate's data is small.** 336 app bundles, 688 settings items, and ~22k files and folders in the home folder outside Library (verified, measured). That fits in a few MB of memory, and a full scan takes well under a second.
- **System Settings sub-items come from `.searchTerms` plists** inside each settings extension. On macOS 27, in English, the ExtensionKit extensions hold 41 files with 688 entries. One legacy `DateAndTime.prefPane` file adds 3 more, for 42/691 (verified, on disk; scope clarified after review). The tested `mdfind` query did not find them, and none of the open-source launchers reviewed (Sol, Tinycast) reads them. Opening a specific sub-item via URL anchor is **unverified** and needs a prototype spike.
- **Recommended stack:** a single-process Swift + AppKit agent app with a pre-built, hidden, non-activating `NSPanel`. Use a Carbon global hotkey, an in-memory index, and an fzy-style scorer with a bitmask prefilter and tiered ranking with frecency. A minimal shell of this kind measured 18 MB idle (verified, measured), against Raycast's 200–450 MB.
- **"No shifting results" is a design rule, not an optimisation.** All local sources are computed in one synchronous pass before drawing. Nothing is appended after the first draw. Ties break deterministically, rows have a fixed height, and icons are pre-cached with same-size placeholders.
- **Main risks:** deep-link anchors for settings sub-items; privacy prompts (TCC) for Desktop, Documents and Downloads; replacing ⌘Space requires disabling Spotlight's shortcut. Building without full Xcode works (Swift 6.4 Command Line Tools). It is commonly reported, but not tested here, that ad-hoc signed rebuilds lose their TCC grants.

## How existing launchers are fast

| Launcher | Stack | Why it feels fast | Footprint |
| --- | --- | --- | --- |
| Raycast v1 | Swift + AppKit, custom list rows; avoided SwiftUI "for performance and control" | Native rendering, own keyboard handling, windows kept in memory | ~200–300 MB (Raycast blog) |
| Raycast 2.0 (2026) | AppKit shell + WKWebView (React) + Node backend + Rust core | Windows shown at `alphaValue = 0`, render forced in `requestAnimationFrame`, then revealed; WebKit occlusion throttling disabled; emoji font pre-warmed | ~350–450 MB (Raycast blog, `phys_footprint`) |
| Alfred | Native Objective-C/Cocoa (secondary sources) | Small native app; apps and preferences in default results; files via the Spotlight metadata index | Vendor/secondary claims of 20–50 MB, unverified |
| LaunchBar | Native | Own index built from user-defined indexing rules; abbreviation learning | Not found |
| Spotlight (macOS 26/27) | System UI + `mds`/`corespotlightd` | Same index as everything else; now also actions, Quick Keys, clipboard history | User reports of slowness and lag on 26.x (Six Colors, Apple Community; unverified as to cause) |
| Tinycast (open source, AGPL) | Swift 6, SwiftUI inside AppKit `NSPanel`s, no dependencies | Folds text once per index change, never per keystroke; ranking cached per query; file crawl in a helper process | Not measured; codebase is ~182k lines of Swift despite the name |
| Sol (open source) | React Native macOS UI + Swift native modules | Persistent non-activating `NSPanel`; app list in memory | Not measured |
| Quicksilver (open source, still maintained) | Objective-C | "Catalog" of sources rescanned periodically; `QSSense` abbreviation scorer (origin of many launcher scorers) | Not measured |
| Ueli, Kunkun | Electron / Tauri + web UI | fuzzysort or fuse.js in JS | Larger web-runtime baseline (not measured) |
| Flow Launcher (Windows) | C#/WPF | Delegates file search to Everything over IPC; own acronym matcher | Not measured |

Common factors in the fast ones (verified across the sources above):

1. **The window already exists.** Sol, Tinycast and Raycast keep the launcher window alive and only order it front. Sol and Tinycast use `NSPanel` with `.nonactivatingPanel` (verified, source). The launcher can take keyboard focus without activating its app, so the hotkey-to-visible path skips app activation.
2. **The search set is in-process memory.** Apps, commands and settings are lists in memory. Text is folded once when the list changes (Tinycast: "Folded once per index change, never per keystroke").
3. **Results come from a source with predictable latency.** For most, that is in-process memory. Flow Launcher's file results come from Everything over IPC, which shows a cross-process call can be fast (corrected after review). Alfred's file results depend on Spotlight's health; its own troubleshooting docs say it can find only what Spotlight has indexed.
4. **Ranking is cached and learned.** Tinycast caches ranking per query and learns per-term usage. Raycast documents the order: exact alias > alias prefix > title fuzzy score > subtitle/keyword > frecency.

Why Spotlight is slow and shifts (partly **inference**): every keystroke is a query to a system daemon, and results stream in from several providers (files, apps, settings, suggestions, actions) that finish at different times. Since macOS 26 it also does more work per query (App Intents actions, Quick Keys, clipboard). The user reports cited above describe waits when launching apps; I found no Apple statement of cause.

## How they index apps and files

**Apps**

- Scan the standard folders and watch them with FSEvents: `/Applications`, `/System/Applications` (+ `Utilities`), `~/Applications`, `/System/Library/CoreServices/Applications`, plus fixed extras such as `Finder.app` (Sol, verified source). Sol scans to depth 4 and keeps an ignore list. Tinycast re-scans on every open and notes that "LaunchServices can trail a deletion by seconds."
- An alternative is a one-time `mdfind kMDItemContentType == "com.apple.application-bundle"` for apps outside those folders. It returned 336 unique names in 66 ms here, but it includes helper apps buried in Application Support that need filtering (verified, measured).
- Names: use the localized display name, plus alternate names (`CFBundleAlternateNames`, Spotlight keywords). Raycast documents `iCal` → Calendar; Tinycast ranks alternate titles like the name.

**Files**

| Approach | Used by | Pros | Cons |
| --- | --- | --- | --- |
| Query Spotlight (`MDQuery`/`NSMetadataQuery`) per keystroke | Alfred, Raycast v1, Ueli (apps, via `mdfind`) | No index to maintain; content search possible | 66–153 ms per query here (`mdfind`, includes process start); results async; only finds what Spotlight indexed; inherits Spotlight's problems |
| Own name index + file system events | Raycast 2.0 (Rust, separate process; FSEvents API not named), Tinycast, Sol (SQLite) | Synchronous, predictable, works when Spotlight is broken; scope and ignore rules under our control | Must handle crawl, permissions, persistence, change replay |
| Own rule-based index, rebuilt on schedule | LaunchBar, Quicksilver | Simple | Stale between rebuilds |
| Reference designs (other OSes) | Everything (NTFS MFT + USN journal), plocate (trigram posting lists) | Everything: ~250k files in ~5 s and ~35 MB RAM; 1M files ~100 MB (voidtools FAQ). plocate: 27M files searched in 8 ms (plocate site) | Not macOS; Apparate's scale (~10⁴–10⁵) doesn't need trigram indexes |

Notable implementation details (verified, source):

- **Tinycast:** crawls with `getattrlistbulk` ("one call lists hundreds of entries with their mtime, so nothing is stat'd"). The crawl runs in a separate helper process "so its memory leaves when that process exits." The index is memory-mapped "so searches answer even while a rebuild runs." FSEvents replays from the snapshot's own event ID, and it rebuilds on `RootChanged` or `EventIdsWrapped`. Searches run in parallel across cores, and changes are applied as an overlay until a rebuild is cheaper.
- **Sol:** stores files in SQLite, but its search query is `SELECT path, name, is_folder FROM files LIMIT 1000`. It then scores with `NSString.scoreAgainst` (threshold 0.5) and sorts alphabetically. Only the first 1,000 rows are ever matched, so it is not a correct full-corpus design. (Corrected after review: the first version said fuse.js. Sol's root app/command search uses MiniSearch in `src/stores/ui.store.tsx`.)
- **Raycast 2.0:** name-only by default, with `.gitignore`/`.ignore`/`.rayignore` support, built-in noise filters (`node_modules`, caches), and default scope = home folder + `/Applications`. Content search is delegated to the OS index (verified, manual).

## macOS platform

**File indexing primitives**

- **FSEvents** (verified, Apple docs and Tinycast source): use `kFSEventStreamCreateFlagFileEvents` for per-file events. Persist the last event ID, and on next launch pass it as `sinceWhen` to replay changes made while the app was not running (the macOS analogue of Everything's USN journal). Handle `MustScanSubDirs`, `RootChanged`, and `EventIdsWrapped` by rescanning.
- **Directory enumeration:** Apple's Jim Luther (filesystem-dev, 2019) said `readdir` is fastest for names only and `getattrlistbulk` wins when attributes are needed. Tempelmann's 2019 tests favour `fts` on APFS. Tinycast uses `getattrlistbulk`. A pruned walk of this home folder (22k entries) took 0.6 s with `find`. That is cold-path work done once, so the choice matters little at this scale (measured).
- **Spotlight queries:** `NSMetadataQuery`/`MDQuery` are fine for occasional or optional searches (file contents, "search whole disk"), not for the per-keystroke path.

**Privacy (TCC)** (verified, Raycast manual and Tinycast source; behaviour well documented): a non-sandboxed app reading Desktop, Documents, Downloads, iCloud Drive, removable or network volumes gets a per-folder consent prompt. Full Disk Access covers all of them and can be revoked at any time without notice. Tinycast re-checks it for that reason. Let the user pick roots with `NSOpenPanel`; a sandboxed build would also need security-scoped bookmarks (added after review). Folder consent and sandbox access are separate mechanisms. TCC ties grants to the app's code signature; it is commonly reported, not tested here, that ad-hoc signed rebuilds lose their grants. A stable self-signed certificate for development avoids the question. Also avoid reading dataless iCloud files, which can trigger downloads (Codex's point).

**Global hotkey:** Carbon `RegisterEventHotKey` needs no permission prompt and is what Tinycast's `HotKeyCenter` uses (verified, source). `CGEventTap` (used by Sol) needs Accessibility/Input Monitoring permission and is only required for things like double-tap modifiers or hyper keys. ⌘Space works only after the user disables Spotlight's shortcut in Keyboard settings.

**Window strategy:** create the `NSPanel` at launch with `.nonactivatingPanel` and `canBecomeKey = true`. Pin it across Spaces (`.canJoinAllSpaces`, `.fullScreenAuxiliary`) at `.floating` level and hide it on `windowDidResignKey` (Sol, verified source). Showing it is then `makeKeyAndOrderFront`. Run as an agent app (`LSUIElement`, accessory activation policy) with no Dock icon.

**Icons:** `NSWorkspace.icon(forFile:)` for apps and files; cache by path and modification date (Tinycast keys app icons on bundle icon changes). Settings panes have icons declared as `ISGraphicIconConfiguration` / content types such as `com.apple.graphic-icon.keyboard`. Tinycast loads these as content-type icons, i.e. `NSWorkspace.icon(for: UTType)` (verified, source).

**Launching:** `NSWorkspace.openApplication(at:configuration:)` for apps, and `NSWorkspace.open(_:)` for files, folders and `x-apple.systempreferences:` URLs.

**Toolchain on this machine:** Swift 6.4.2 with Command Line Tools only, no Xcode (verified). SwiftPM can build the executable. The `.app` bundle (Info.plist with `LSUIElement`) and code signing are a small script.

## System Settings items

**Data source (verified, on disk):**

- Settings panes are ExtensionKit extensions in `/System/Library/ExtensionKit/Extensions/*.appex` whose `Info.plist` has `EXAppExtensionAttributes.EXExtensionPointIdentifier = com.apple.Settings.extension.ui` (52 on this Mac). Legacy `.prefPane` bundles still exist in `/System/Library/PreferencePanes` (40) and in `/Library/PreferencePanes` for third-party panes.
- Each pane names its search file in `SettingsExtensionAttributes.searchTermsFileName`. The file is `Contents/Resources/<lang>.lproj/<name>.searchTerms`, an XML plist with this layout: group key (e.g. `InputSources`) → `localizableStrings` → entries with `title` ("Keyboard layouts") and `index` (comma-separated keywords, e.g. "QWERTY, AZERTY, Dvorak, …").
- 42 English files and 691 entries on macOS 27.0. This is exactly what Spotlight shows as settings sub-items in the user's screenshot.
- The same `Info.plist` has the pane's bundle ID (`com.apple.Keyboard-Settings.extension`), its legacy ID (`com.apple.preference.keyboard`), `allowsXAppleSystemPreferencesURLScheme`, and its icon configuration.
- `mdfind 'kMDItemDisplayName == "Keyboard layouts"'` returns nothing. That shows the metadata query does not expose this item; it does not prove settings items are absent from every Spotlight store (narrowed after review). The `.searchTerms` files are a catalog that can be read directly, so Apparate should read them itself. They change only on OS updates, so cache them and re-read when the Extensions folder's modification date changes (Tinycast's approach for panes).

**Opening them:**

- A pane opens with `x-apple.systempreferences:<bundle id>`. That much is verified as the documented community form, and the Keyboard extension declares `allowsXAppleSystemPreferencesURLScheme`.
- A sub-item likely opens with `x-apple.systempreferences:<bundle id>?<anchor>`. Whether the `.searchTerms` group keys are valid anchors is **unverified**. Some (`CustomizeModifierKeys`, `TextReplacements`, `CapsLockInputSources`) appear as literal strings in the Keyboard extension binary; others (`InputSources`, `FunctionKeys`) do not.
- Plan a spike: for each entry, try the anchor URL and observe whether the right section opens. Where no anchor works, fall back to opening the pane.
- Community anchor lists (bvanpeski/SystemPreferences, rmcdongit gist) cover older pane IDs and are not authoritative.

**Open-source comparison (verified, source):** Tinycast lists panes only (`SettingsPaneScanner`, with name and icon overrides for broken bundles). Sol lists legacy `.prefPane` bundles with a hard-coded name map. Neither offers sub-items, so this is a real gap Apparate can fill.

## Fuzzy matching and ranking

| Algorithm | Notes |
| --- | --- |
| fzf v1 / v2 | v1 greedy, v2 Smith-Waterman-style DP with boundary bonuses; the standard for terminals |
| fzy | DP with consecutive/word/camel/dot bonuses and gap penalties; simple, good quality; used in the benchmark |
| Quicksilver `QSSense` | Recursive abbreviation scorer with transliteration fallback; origin of many launcher scorers |
| Tinycast `LauncherMatch` | DP alignment: word start 3 points, first char 4, others 2, gap −1; camel humps precomputed; rough-subsequence pre-check; three sensitivity thresholds (verified, source) |
| Flow Launcher `StringMatcher` | Separate acronym pass (index 0, after space, uppercase, digit groups: `vs19` → Visual Studio 2019) plus substring fuzzy (verified, source) |
| fuse.js (Kunkun, Ueli option, some Sol lists) / fuzzysort (Ueli default) / MiniSearch (Sol root search) | JS libraries; fuse.js is Bitap-based and tolerates typos, but its acronym ranking is weak (expected from its design, not measured here) |
| Alfred / Raycast | Alfred matches apps by capital letters or from any word boundary (docs). Raycast: "Fuzzy search means you don't need an exact match" (`msg` → Messages), sensitivity setting, frecency per query (manual) |

Measured on this machine (see [benchmark](benchmark.md)): an fzy-style scorer over pre-folded bytes with a 64-bit character bitmask prefilter and bounded top-50 selection.

- 20k candidates: 0.13 ms mean, 0.49 ms slowest keystroke on one thread.
- 200k candidates: 1.30 ms mean, 5.2 ms slowest keystroke on one thread; 0.29 ms mean, 1.0 ms slowest on 10 threads.
- "Slowest keystroke" is the maximum over keystrokes of each keystroke's best of 7 runs, not an observed worst case or p95. Re-run after review with a checksum over the selected top-K IDs, so the selection cannot be optimised away; results were unchanged within noise.
- These numbers are not directly comparable with Codex's (different corpus, queries, and statistics). Codex also measured full-path scoring at 200k: about 44 ms median, up to 81 ms. Name-first matching is therefore required, with a separate path mode.
- `vsc` → Visual Studio Code ranks first with no special acronym code, because word-start bonuses dominate.

Ranking recommendation:

1. **Tiers first, score second:** exact alias > alias prefix > exact name > name prefix > word-start/acronym > fuzzy. This matches Raycast's documented order and Sol's relevance-tier-before-usage behaviour.
2. **Kind priority within a tier:** apps > settings > folders > files by default (configurable). Without it, `term` ranks two files above Terminal (measured).
3. **Frecency** keyed by the query typed. Tinycast adds 100 per open, halves every 10 days, floors at 1, and stores the last few query terms per entry. Raycast tracks frecency per query. Frecency should reorder within a tier, never lift a weak fuzzy hit above an exact match.
4. **Deterministic ties:** shorter name, then a stable ID. Keep the selected item selected if it is still in the new list.

## Recommended architecture

- **Language/UI:** Swift 6 + AppKit for the panel, text field and results list (`NSTableView`, fixed row height, view reuse). SwiftUI is acceptable for the settings window. Reason: deterministic control over first draw and keyboard handling (Raycast v1's stated reason). Tinycast shows SwiftUI-in-NSPanel can work, but with a lot of workaround code.
- **Process model:** one agent process (`LSUIElement`) launched at login with `SMAppService`. Optionally run the initial file crawl in a short-lived helper process, as Tinycast does, so peak crawl memory is returned to the OS. That is worth it only if measured peak memory is large.
- **Providers:** each source returns entries into one in-memory table of folded byte strings with kind, ID, display name, alternate names, and icon key.
  - **Apps:** scan the standard app folders and watch them with FSEvents.
  - **Settings:** parse panes and `.searchTerms`, cached by the Extensions folder's modification date.
  - **Files:** user-selected roots only. Crawl on a background queue with ignore rules (`.gitignore`, `node_modules`, caches, hidden items by default). Persist a compact snapshot plus the last FSEvents event ID; replay on launch.
- **Query path (changed after review):**
  1. The main thread parses the prefix and hands the query, with an increasing generation number, to one serial search worker.
  2. The worker matches against an immutable snapshot of the scope, then tiers, ranks and takes the top K.
  3. The main thread publishes the complete list in one reload, only if the generation is still current, so a late result for `v` never overwrites `vsc`.

  At the measured costs this normally lands within the same frame. Typing is never blocked, even at 200k candidates or when an index update is running. The first version ran the match synchronously on the main thread. Codex argued, and I agree, that atomic publication alone gives the stability, without risking a blocked keystroke. Split across cores only if measurement shows a need; energy use of parallel scoring was not measured.
- **Prefix commands:** a small table in config mapping a leading character to a scope, e.g. `'` → files and folders, `.` → settings, `>` → commands, `=` → calculator. An escape such as a doubled prefix searches the literal character.
- **Config:** one versioned JSON file (`Codable`, no dependency) in Application Support or `~/.config/apparate/`, watched for changes. It holds the hotkey, file roots, ignore patterns, prefixes, aliases and kind order. The user asked for prefixes "configured in settings". Whether that means a settings window or a config file is for the user to decide (raised in review).
- **Budgets** (aspirational targets, none measured on a real build):
  - Hotkey to visible panel: ≤ 1 frame (~16 ms).
  - Keystroke to updated results: ≤ 8 ms at 20k candidates.
  - Idle CPU: 0%.
  - Idle memory: ≤ 40 MB with a 20k-entry index loaded. The bare shell measured 18 MB without icons, index structures or drawing; count any helper processes too.

## Additional feature suggestions

Priority 1 is small, fits a minimal launcher, and is common to Alfred, Raycast and LaunchBar:

1. **Aliases** (`vsc` → VS Code) and learned ranking. Ranking gets better with use at almost no cost.
2. **Actions on a result:** Reveal in Finder, Copy path, Quick Look, Open with…, Show info. Without these, file search is half useful.
3. **Inline calculator and unit/currency conversion.** Saves opening an app; no index needed.
4. **Quicklinks / web search with a template** (`gh apparate` → GitHub search). The fallback when nothing local matches.
5. **Running-app commands:** switch to, hide, quit, force quit.
6. **System commands:** lock screen, sleep, restart, empty Trash, toggle dark mode, eject disks.

Priority 2 is useful but costs more:

7. **Script commands:** run a user's shell script with a title and an optional argument. Unlimited extension with no plugin runtime.
8. **Recent files and folders** when the query is empty, from the file index's modification dates.
9. **Browser bookmarks and history search.** Each browser has a different format.
10. **Emoji and symbol picker.**

Not recommended initially:

- Clipboard history: Spotlight in macOS 26+ already has it.
- Snippets/text expansion: needs an Accessibility event tap.
- Extension store, AI chat, window management, notes. Each multiplies footprint and scope.

## Risks and open questions

Risks:

- **Settings sub-item anchors** may not open the exact section; `.searchTerms` is an undocumented format that can change with macOS releases. Mitigation: prototype spike, then fallback to the pane.
- **TCC prompts** for Desktop, Documents and Downloads, and the Full Disk Access trade-off for broader roots.
- **⌘Space** conflicts with Spotlight until the user disables Spotlight's shortcut.
- **Development signing:** without Xcode, builds are scripted; ad-hoc signing resets privacy grants on every rebuild.

Decisions for the user:

1. UI stack: AppKit (recommended) vs SwiftUI.
2. File search engine: own index (recommended) vs Spotlight queries vs own index for names plus Spotlight for an explicit content search.
3. Default file roots and ignore rules.
4. Hotkey: replace ⌘Space, or another chord.
5. Config: file only first (recommended) vs settings UI from the start.
6. Which additional features belong in v1.
7. Distribution: personal use only, or public (Developer ID and notarization).
8. Default kind order (apps > settings > folders > files?).

## Corrections after review

Codex reviewed this report on 2026-11-18, after both reports were complete. Changes made in response, marked inline:

1. Spotlight's slowness: the suspected causes are now labelled inference, since neither report profiled Spotlight.
2. "No per-keystroke IPC" was too broad. Flow Launcher → Everything is a fast cross-process counterexample. Reworded to predictable latency and one complete result set.
3. Raycast 2.0's indexer follows "file system events"; the specific FSEvents API is inference.
4. Sol's file search uses `NSString.scoreAgainst` and an alphabetical sort, not fuse.js. Its root search uses MiniSearch. Verified in source at `873ae1c`.
5. Query path changed from synchronous main-thread search to a serial worker with generation numbers and atomic publication.
6. Benchmark "worst" relabelled as the maximum of per-keystroke best-of-7 runs. Re-run with a checksum over the top-K selection; unchanged.
7. Settings counts: 41 files / 688 entries in ExtensionKit, plus 1 legacy prefPane file / 3 entries, for 42 / 691.
8. The ad-hoc signing and TCC claim is now stated as reported, not tested. Added `NSOpenPanel` and security-scoped bookmarks, and dataless iCloud files.
9. Budgets labelled aspirational, with corpus size stated. Config-file-only is no longer presented as settled, because the user said prefixes are configured "in settings".
10. After Codex's alignment review: the opening summary no longer suggests our scorer measures Spotlight. The `mdfind` result is narrowed to what that one query shows.

Not changed: the recommendation itself (Swift + AppKit, own name index, fzy-style tiers with frecency, settings from `.searchTerms`). Codex's review agreed with it.

## Sources

- Raycast: [A technical deep dive into the new Raycast](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast) (May 2026); [File Search manual](https://manual.raycast.com/file-search); [Search Bar manual](https://manual.raycast.com/search-bar); [Spotlight troubleshooting](https://manual.raycast.com/troubleshooting/spotlight)
- Alfred: [Indexing troubleshooting](https://alfredapp.com/help/troubleshooting/indexing); [Can Alfred work without Spotlight?](https://www.alfredapp.com/help/troubleshooting/indexing/spotlight/); [Default results](https://www.alfredapp.com/help/features/default-results/)
- LaunchBar: [Indexing rules](https://obdev.at/resources/launchbar/help/IndexingRules.html); [Index window](https://obdev.at/resources/launchbar/help/IndexWindow.html)
- Spotlight in macOS 26: [MacRumors](https://www.macrumors.com/2025/06/09/apple-supercharges-spotlight-in-macos-tahoe-with-quick-keys-and-more/); [TechCrunch](https://techcrunch.com/2025/06/09/apple-updates-spotlight-to-take-actions-on-your-mac/); slowness reports: [Six Colors](https://sixcolors.com/?p=39502), [Apple Community](https://discussions.apple.com/thread/256313638?page=1)
- Source code read (shallow clones, 2026-11-18): [Sol](https://github.com/ospfranco/sol) `873ae1c`; [Tinycast](https://github.com/abue-ammar/tinycast) `99d1d17`; [Ueli](https://github.com/oliverschwendener/ueli) `9410429`; [Albert](https://github.com/albertlauncher/albert) `c703546`; [Flow Launcher](https://github.com/Flow-Launcher/Flow.Launcher) `58b7997`; [Kunkun](https://github.com/kunkunsh/kunkun) `d4383c5`; [Quicksilver](https://github.com/quicksilver/Quicksilver) `12d7543`; [fsearch](https://github.com/cboxdoerfer/fsearch) `74295de`
- Everything: [voidtools FAQ](https://www.voidtools.com/faq/); plocate: [plocate.sesse.net](https://plocate.sesse.net/)
- Filesystem: [FSEvents programming guide](https://developer.apple.com/library/mac/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html); [readdir vs getattrlistbulk thread](https://lists.apple.com/archives/filesystem-dev/2019/Apr/msg00005.html); [Tempelmann 2019](https://blog.tempel.org/2019/04/); [mjtsai summary](https://mjtsai.com/blog/2019/04/22/performance-considerations-when-reading-directories-on-macos)
- Settings deep links (community, not authoritative): [Apple developer forums](https://developer.apple.com/forums/thread/709289); [bvanpeski/SystemPreferences](https://github.com/bvanpeski/SystemPreferences/blob/main/macos_preferencepanes-Ventura.md)
- Measured on this Mac: app/settings/file counts, `mdfind` timings, home walk, matching benchmark, idle footprint ([benchmark](benchmark.md)).
