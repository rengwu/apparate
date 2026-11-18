---
title: Implementation plan
section: Planning
updated: 2026-11-18
status: Approved
---
# Implementation plan

Status: **approved** in grill-form round 4 ([DEC-036](decisions.md#round-4-2026-11-18)). Codex reviewed the drafts, and this version includes its changes and the round-4 answers.

It builds what the [requirements](requirements.md) and [decisions](decisions.md) describe, using the three spikes:

- [UI design](spikes/2026-11-18-ui-design.md)
- [settings deep links](spikes/2026-11-18-settings-deep-links.md)
- [panel latency](spikes/2026-11-18-panel-latency.md)

## How the build runs

Roles follow [DEC-036](decisions.md#round-4-2026-11-18) and [DEC-037](decisions.md#round-4-2026-11-18).

1. **Guide.** Before each milestone, Claude writes a build guide in [Build](build/index.md). It lists the decisions that apply, the scope and its order, the tests, and references: code in Klip, Yacht and Portia, Apple documentation, and screenshots of the agreed design.
2. **Build.** Codex builds the milestone, following the guide. Codex can push back on any part, in writing and with reasons.
3. **Disagreements.** If Claude and Codex still disagree after one exchange, the question goes to the user in a grill-form, with both positions attributed. Work that does not depend on the answer continues.
4. **Review.** Codex reports what it built and how it verified it. Claude reviews the diff and the verification run, and Codex fixes what the review finds.
5. **Commit.** After the review passes, the milestone is one local git commit. Nothing is pushed without the user's go-ahead.

Two jstack rules apply throughout: `rule-lean` (the user cited it in [DEC-029](decisions.md#round-4-2026-11-18)) and `rule-plain-ui` for every visible part. Both are in `~/Projects/jstack/skills/`.

## Shape

The layout follows Klip, Yacht and Portia ([DEC-013](decisions.md#round-2-2026-11-18)).

| Part | Role |
| --- | --- |
| `ApparateCore` (library, no AppKit) | Config, the item and query model, matcher and ranking, the settings catalog, the file crawler and FSEvents handling, SQLite storage, usage history. |
| `Apparate` (AppKit app) | Adapters for hotkey, icons, opening items and launch at login; the panel; settings window, menu bar menu and first run. |
| `ApparateCoreTests` (plain executable) | Core tests run with `swift run ApparateCoreTests`. On this Mac, `import XCTest` and `import Testing` both fail with Command Line Tools only, so tests use the same executable pattern as Klip. |
| `build.sh` | Builds `build/Apparate.app`: arm64 only, ad-hoc signed with the designated requirement `identifier "local.apparate"` ([DEC-014](decisions.md#round-2-2026-11-18)). |

- No third-party packages. SQLite comes from the system `libsqlite3`.
- The build is arm64 only because Apple named macOS 26 the last release for Intel Macs, and Apparate needs macOS 27 ([DEC-010](decisions.md#round-1-2026-11-18)).
- Data lives in `~/Library/Application Support/Apparate/`: `config.json` and `index.sqlite`.
- Testing aids, as in Klip:
  - `APPARATE_HOME` points a run at another folder.
  - `APPARATE_SHOW=panel|settings|setup` opens that window at launch.
- Core tests use a temporary home, fake actions and recorded file events. They never open real URLs, run system commands or touch the real index.

## Ground rules for every milestone

- **One consistent snapshot per search.** Search runs off the main thread on an immutable snapshot of the index. SQLite, crawling and icon loading never run on the keystroke path.
- **Generations.**
  - Every query, scope, config or snapshot change starts a new generation.
  - Cancellation uses a synchronized token, not a shared plain integer.
  - Only the current generation's complete result set is published. There are no partial sources and no stale results.
- **Stable selection.** The selection follows an item ID across updates. If the item drops out, the selection falls back to the first row. Return, ⌘Return and ⌘C act on the selected item's ID, never on a row number.
- **Typed text shows at once.** Typing is never held back to wait for results. Whether a short wait helps is tested in M4, not assumed; Claude and Codex differ on it.
- **Measure early.** Each milestone records the timings and memory it can, using a corrected measurement method (see M6). The budgets in [DEC-008](decisions.md#round-1-2026-11-18) stay as provisional end-to-end goals ([DEC-028](decisions.md#round-4-2026-11-18)).

## Milestones

Each milestone ends with core tests passing, a verification run recorded in this wiki, Claude's review, and one commit (see [How the build runs](#how-the-build-runs)).

### M1. Foundation, matching and ranking

**Scaffold:** SwiftPM targets, `build.sh` with the real signing identity, and adapters for the environment, clock and actions.

**Config:**

- A versioned `config.json` with defaults, validation, atomic writes and migration.
- If a hand edit breaks it, Apparate keeps the last valid config and reports the error.
- Apparate reloads the file when it changes on disk, without polling and without reacting to its own saves.
- Defined errors for:
  - colliding or empty prefixes;
  - bad depths or paths;
  - an invalid search URL template.

**Items and queries:**

- Stable item IDs for every kind: app, settings item, folder, file, system command, web search.
- Prefixes, configurable ([REQ-005](requirements.md)). Defaults, with no others for now ([DEC-032](decisions.md#round-4-2026-11-18) is provisional until round 5):
  - `'` searches files and folders;
  - `.` searches settings;
  - `?` searches the web ([DEC-030](decisions.md#round-4-2026-11-18)).
- Path search ([DEC-031](decisions.md#round-4-2026-11-18)): a query containing `/` matches full paths instead of names. It is a separate mode, so ordinary queries never score every full path.
- An explicit prefix is read first, so a web query containing `/` still goes to the web.
- Two features can never share one prefix.

**Matching:**

- Names first, fzy-style, with a character mask and subsequence pre-check as in the [benchmark](research/claude/benchmark.md).
- Unicode is normalized consistently. Matched letters map back to what is displayed for the bold highlight.
- The mask never rules out a real match.
- No length limits are inherited from the benchmark.

**Ranking, in order:**

1. Tier: exact > prefix > word start or acronym > fuzzy > settings keyword.
2. Kind: apps and commands > settings > folders > files ([DEC-002](decisions.md#round-1-2026-11-18)).
3. Fuzzy score plus a bounded usage boost, so usage reorders only within a tier and kind.
4. A fixed final tie-break: folded name, then ID.

"Exact" includes an app's built-in alternate names, but not user aliases, which [DEC-016](decisions.md#round-2-2026-11-18) leaves out. Top 50 are kept.

**Usage history:**

- Stored in SQLite with a bounded size.
- Survives a rebuild.
- Updated only after an item actually opens.
- Opening an item never reorders the list you are looking at.

**Tests:**

- `vsc` → Visual Studio Code, `keyboard la` → Keyboard layouts, `term` → Terminal before files.
- A strong file match against a weak app match; ties between same-kind matches.
- Prefixes and the fallback row.
- Accented letters in both composed and decomposed forms, CJK, emoji, very long names and queries.

### M2. Apps, settings, actions, and a first panel

**Apps:**

- Found in `/Applications`, `/System/Applications` (with Utilities), `~/Applications`, and any app folders the user adds. Kept current with FSEvents.
- Duplicate installs and localized names are handled.
- The plan does not promise to find apps stored elsewhere.

**Settings items:**

- From ExtensionKit `.searchTerms` and the legacy Date & Time pane.
- Names from the localized bundle info, icons from the bundle, with overrides for Battery and Headphones.
- The cache is rebuilt when the macOS build or language changes.
- Opening: the pane-and-anchor URL, opened directly even when System Settings is already running ([DEC-029](decisions.md#round-4-2026-11-18)). If the URL fails to open, the error is reported. Settings rows show their pane, so landing on the pane alone is not a surprise.

**Actions:**

- Each kind has a typed action: open apps, files and folders ([REQ-003](requirements.md)); reveal and copy the path of the same item.
- Missing items and launch failures are reported, and stale entries are dropped.

**System commands:**

- Lock, Sleep, Restart and Show Trash rank like apps.
- Restart needs a second, deliberate Return ([DEC-019](decisions.md#round-2-2026-11-18)). Typing, moving the selection, Esc or hiding cancels it, and a held-down Return does not count.
- Tests use a fake executor. One supervised smoke test checks that each real command works on macOS 27.
- Automated checks never lock, sleep or restart the user's Mac.

**Web search:**

- Uses the prefix, plus the fallback row, which appears only after a complete local search finds nothing. An empty query is never a web search.
- The URL template is checked, and the query is encoded properly (spaces, `&`, `+`, `#`, non-Latin text).
- Opens through the default-browser API ([DEC-017](decisions.md#round-2-2026-11-18), [DEC-018](decisions.md#round-2-2026-11-18)).

**First panel:**

- A plain panel with the Carbon hotkey (default ⌘Space) and the real signed identity, so hotkey, focus and window behaviour are tested early.
- A basic folder-access step from first run, so M3 never crawls protected folders without consent.

### M3. File index

**Folders:**

- `~/Projects`, `~/Desktop`, `~/Documents` and `~/Downloads` by default, plus folders the user adds ([DEC-005](decisions.md#round-1-2026-11-18)).
- Depth 10 by default, adjustable per folder ([DEC-020](decisions.md#round-2-2026-11-18)). Depth is defined as follows:
  - the folder itself is depth 0, its children depth 1;
  - entries at the maximum depth are indexed but not descended into.
- Overlapping folders are indexed once. Symbolic links and app packages are listed but not followed.

**Exclusions:**

- Hidden files and `node_modules` are always skipped ([DEC-006](decisions.md#round-1-2026-11-18)).
- `.gitignore` files follow Git's own rules:
  - nested files, order, negation, anchored and folder-only patterns, `**`, and escaping;
  - a file under an excluded folder cannot be re-included.
- Rule files are read even though hidden files are not listed. When a rule file changes, that subtree is checked again.
- Only `.gitignore` counts, not global Git excludes or `.ignore` files. A setting turns this off; it is on by default ([DEC-033](decisions.md#round-4-2026-11-18)).

**Stored per entry:**

- a stable ID;
- which folder it belongs to;
- its path relative to that folder;
- its name, kind and change details.

Same-named files in different places stay distinct.

**Keeping it current with FSEvents:**

- Watching starts before the first crawl, so changes during the crawl are not lost.
- The last event ID is saved only after the changes it covers are stored, so a crash replays safely.
- Rescans are triggered by:
  - `MustScanSubDirs`;
  - dropped events (`UserDropped`, `KernelDropped`);
  - root moves and removals (watched with `WatchRoot`);
  - `RootChanged` and `EventIdsWrapped` (full rescan);
  - lost event history and failed streams;
  - a change of folders, depth or rules.
- "Could not read" is not "empty". A denied or unavailable folder keeps its old entries, marked unavailable, until it can be read again. A folder the user removes leaves search results at once.

**Rebuild:**

- The searcher sees either the old index or the new one, never a mix.
- Usage history and config are kept.
- Searching stays responsive while it runs.
- Event backlogs and crawl work are bounded.

**Tests (headless, in temporary folders):**

- rename and delete;
- changes during the first crawl;
- crash and replay;
- injected dropped events;
- a moved or removed folder;
- permission failure;
- a change of rules.

Timings and memory are also measured while searching during a rebuild.

### M4. The launcher panel

- Variation A layout with C rows ([DEC-023](decisions.md#round-3-ui-design-spike-2026-11-18), [DEC-024](decisions.md#round-3-ui-design-spike-2026-11-18)): fixed size, 9 visible rows, ⌘1–9 for the visible rows.
- ↑ and ↓ scroll through all 50 results, so results past the ninth stay reachable. The hints follow the visible rows.
- **Rows:** compare a custom Core Text list (fast in the spike) with manually laid-out table cells. Both must support:
  - keyboard and mouse selection, VoiceOver, truncation and highlighting.

  Choose by measured results with equal behaviour.
- **Publishing:** start with immediate typing and asynchronous publishing of complete results. Measure whether a short wait gives a better result.
- **Warm-up:** draw at launch without taking focus. Check that the first real hotkey press is fast.
- **Keys:** ↑ ↓, Return (open), ⌘Return (reveal), ⌘C (copy path), ⌘1–9, Esc ([DEC-016](decisions.md#round-2-2026-11-18)).
- **States:** empty, loading, error and "no results", plus the footer showing the selected item's keys.
- Behaves correctly over full-screen apps and in other Spaces.

### M5. Settings, menu bar and first run

**Settings, toolbar tabs** ([DEC-025](decisions.md#round-3-ui-design-spike-2026-11-18)). All of these work against the M1 config:

- **General:**
  - hotkey recording, with the Spotlight conflict notice; a failed new hotkey keeps the old one;
  - launch at login (`SMAppService`, showing its real state);
  - menu bar icon on or off.
- **Search:** prefixes, search engine, URL template.
- **Folders:**
  - folders with per-folder depth and + / −;
  - the `.gitignore` switch ([DEC-033](decisions.md#round-4-2026-11-18));
  - index status and Rebuild.

**Menu bar menu:**

- Open (showing the configured hotkey), Settings, Quit ([DEC-026](decisions.md#round-3-ui-design-spike-2026-11-18)).
- With the icon hidden ([DEC-021](decisions.md#round-2-2026-11-18)), Settings and Quit stay reachable: ⌘, and ⌘Q in the panel, and opening the app again shows Settings.

**First run** ([DEC-027](decisions.md#round-3-ui-design-spike-2026-11-18)):

- Two steps with live status: free up ⌘Space, with a button that opens Keyboard Shortcuts; and folder access.
- Buttons: Choose Folders… and Done.
- Partly granted, denied or cancelled access is a normal state, and the launcher still works.
- Folder access is stored apart from the hand-editable paths.

### M6. Performance qualification

**Measurement harness,** corrected from the spike:

- each result set carries a generation marker that the detector checks;
- every observation window has an end;
- key presses are timed independently of results;
- logging is thread-safe, with per-event records kept;
- Core Animation commits happen naturally, not forced.

**Runs on the built app:**

- cold and warm hotkey presses from another app;
- typing names, paths and Unicode;
- searching during a rebuild and during file changes;
- at the display's real refresh rates.

**Reporting:**

- Apparate's own timings (dispatch, search, commit) separately from on-screen timings.
- Steady memory after typing, the peak during indexing, and any helper processes.
- Idle CPU and wake-ups over at least 60 quiet seconds.

These are judged against DEC-008, kept as goals by [DEC-028](decisions.md#round-4-2026-11-18). The results then go back to the user.

### M7. Release 0.1.0

- App icon from the reworked direction ([DEC-035](decisions.md#round-4-2026-11-18)), refined, plus a menu bar glyph. `make-icon.sh` as in Klip.
- README with install and update steps, and the MIT licence ([DEC-034](decisions.md#round-4-2026-11-18)).
- A clean install check:
  - version and minimum macOS are consistent;
  - the signature and designated requirement are verified;
  - existing config and index survive an upgrade;
  - no personal data is in the zip.
- A zip on GitHub Releases ([DEC-014](decisions.md#round-2-2026-11-18), [DEC-015](decisions.md#round-2-2026-11-18)). Creating the GitHub repository and publishing need the user's go-ahead at that point.
- Before the repository is made public, check the wiki and `docs/design/` for personal details. Research pages, prototypes and screenshots name apps installed on this Mac and folders under `~/Projects`. The user decides what stays.

## Records

Following jstack conventions:

- [feature map](features/index.md), with verification recipes;
- runs in `verification/runs/`, with evidence in `evidence/`;
- build guides in [`build/`](build/index.md), one per milestone;
- this page tracks progress (below).

## Progress

| Milestone | Guide | Built | Reviewed | Commit |
| --- | --- | --- | --- | --- |
| M1 Foundation, matching and ranking | [written](build/m1-foundation.md) | [yes](verification/runs/2026-11-18T154000Z-m1.md) | [passed](build/m1-foundation.md#review); [fix verified](verification/runs/2026-11-18T154000Z-m1.md#post-review-fix) | waiting for git |
| M2 Apps, settings, actions, first panel | draft | — | — | — |
| M3 File index | — | — | — | — |
| M4 Launcher panel | — | — | — | — |
| M5 Settings, menu bar, first run | — | — | — | — |
| M6 Performance qualification | — | — | — | — |
| M7 Release 0.1.0 | — | — | — | — |

## Risks

- **Budgets:** the spike's display times were above the DEC-008 limits, but its harness was too rough for a verdict. The corrected M6 harness measures it, and the user revisits the budgets with those results ([DEC-028](decisions.md#round-4-2026-11-18)).
- **Settings anchors:** in the spike, 10 of 57 settings anchors did not reach their item and 4 reached only the right sheet. In the one tested sequence where System Settings already showed a sheet, later links did not navigate. [DEC-029](decisions.md#round-4-2026-11-18) accepts this: Apparate opens links directly and adds no recovery action.
- **Folder permissions:** the first prompts for Desktop, Documents and Downloads, and whether grants survive rebuilds of this app, are tested early (M2–M3). The fixed signing identity is meant to help, but signing alone does not grant access.
- **Hotkey:** ⌘Space only works after the user frees it from Spotlight. First run guides this, and a failed hotkey must be visible.
