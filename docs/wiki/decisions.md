---
title: Decisions
section: Planning
updated: 2026-11-18
---
# Decisions

Accepted product decisions for Apparate. These are expected behaviours and choices, not implementation or verification claims.

## Round 1 — 2026-11-18

Source: the user's submitted grill-form ("Apparate decisions — round 1"), asked after the [research alignment](research/alignment.md).

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-001 | A query without a prefix searches apps, settings, folders and files. | User choice; matched the recommendation. Prefixes narrow the search ([REQ-005](requirements.md)). |
| DEC-002 | When matches are equally good, kinds rank apps > settings > folders > files. Learned usage reorders only within a match tier. | User choice; matched the recommendation. Without it, `term` ranked two files above Terminal. |
| DEC-003 | v1 has a small native settings window that saves to an editable, versioned JSON file. | User choice; required by [REQ-005](requirements.md). The user asked that nativeness and simplicity follow their apps Klip, Yacht and Portia. |
| DEC-004 | The default hotkey is ⌘Space, and it can be changed. The user turns off Spotlight's shortcut. | User choice; matched the recommendation. |
| DEC-005 | Default indexed folders: `~/Projects`, `~/Desktop`, `~/Documents`, `~/Downloads`. Users can add folders and set a maximum folder depth. | User choice plus the user's note ([REQ-008](requirements.md)). |
| DEC-006 | Files listed in `.gitignore` are left out of the index. Hidden files and `node_modules` are excluded regardless. | User choice; matched the recommendation. Whether this can be turned off, and whether `.ignore` files also count, was proposed but not asked. |
| DEC-007 | Extra v1 features: web search in the default browser, and system commands Lock, Sleep, Restart and Show Trash. | User's note ([REQ-009](requirements.md), [REQ-010](requirements.md)). The user ticked none of the listed features (aliases, file actions, index status, calculator, quicklinks, running apps, recent files, scripts); round 2 asks about the ones both agents recommended. |
| DEC-008 | Performance budgets accepted (table below). | User choice. |
| DEC-009 | Apparate is released publicly from the start. | User choice. Channel and signing are asked in round 2. |
| DEC-010 | macOS 27 only. | User choice; matched the recommendation. |
| DEC-011 | Claude and Codex continue as builder and reviewer: one builds, the other reviews. | User choice; matched the recommendation. |
| DEC-012 | Next: ask any remaining decisions, then Claude alone runs a UI design prototype spike in grill-form, with 3–4 variations of each major interface. | User's answer to "what next" (chose "something else" with this note). |

Performance budgets (DEC-008). Nothing has been achieved yet. Latencies are p95, measured end to end. Memory is `phys_footprint` in MiB, including any helper process.

| Measure | Target | Limit (p95) |
| --- | --- | --- |
| Warm hotkey → panel's first presented frame | ≤ 16 ms | ≤ 33 ms |
| Keystroke → stable displayed results, 20k items | ≤ 8 ms | ≤ 16 ms |
| Keystroke → stable displayed results, 200k items | ≤ 16 ms | ≤ 33 ms |
| Memory with a 20k-item index | ≤ 40 MiB | ≤ 60 MiB |
| Memory with a 200k-item index | — | ≤ 100 MiB |
| Idle CPU | 0% | no polling |

## Round 2 — 2026-11-18

Source: the user's submitted grill-form ("Apparate decisions — round 2").

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-013 | The joint technical recommendation in the [research alignment](research/alignment.md) is the basis for the build. The settings window is AppKit too, matching the reference apps (no SwiftUI). Build uses SwiftPM plus `build.sh`. | User accepted. |
| DEC-014 | Public releases follow Klip and Yacht: GitHub Releases, ad-hoc signed with a fixed designated requirement, not notarized. | User choice; matched the recommendation. |
| DEC-015 | Updates are a manual download from GitHub Releases. No update code or dependency in v1. | User choice; matched the recommendation. |
| DEC-016 | v1 also includes file actions (Reveal in Finder, Copy path), and index status with a Rebuild button in settings. Aliases and pinned results are not in v1. | User choice. |
| DEC-017 | Web search has a prefix and a fallback row shown when nothing local matches. Results open in the default browser. | User choice; matched the recommendation. The prefix character (proposed `?`) is not yet confirmed. |
| DEC-018 | The default search engine is DuckDuckGo. The URL template is editable in settings. | User choice. |
| DEC-019 | Restart asks for confirmation (Return again). Lock, Sleep and Show Trash run immediately. | User choice; matched the recommendation. |
| DEC-020 | The default maximum depth for indexed folders is 10 levels, adjustable per folder. | User choice. |
| DEC-021 | Apparate has a menu bar icon, which can be hidden in settings. | User choice; matched the recommendation. |
| DEC-022 | The UI spike covers all five interfaces: launcher panel, result rows, settings window, menu bar menu, and first run. | User choice. |

## Round 3 — UI design spike — 2026-11-18

Source: the user's submitted grill-forms ("Apparate UI — round 3" and "round 3b"). Variations are described in the [UI design spike](spikes/2026-11-18-ui-design.md).

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-023 | The launcher panel is variation A: compact and fixed in size, with a search field, 28 pt rows, ⌘1–9 hints, and a footer with the selected result's keys (like Klip). | User choice; matched the recommendation. |
| DEC-024 | Result rows are variation C: one line, matched letters in bold, location dimmed after the title, ⌘N hint on the right. | User choice; matched the recommendation. |
| DEC-025 | The settings window uses toolbar tabs: General (hotkey with the Spotlight conflict notice, launch at login, menu bar icon), Search (prefix table, search engine, search URL), and Folders (folder table with depth and +/−, the .gitignore switch, index status with Rebuild). | User choice in round 3b; Claude had recommended the one-page layout. |
| DEC-026 | The menu bar menu has Open Apparate (⌘Space), Settings… (⌘,) and Quit Apparate (⌘Q). Index status and Rebuild live in the settings Folders tab, not the menu. | User choice in round 3b; Claude had recommended adding index status to the menu. |
| DEC-027 | First launch shows one setup window with two steps and their status: free up ⌘Space (opens Keyboard Shortcuts) and allow access to Desktop, Documents and Downloads. Buttons: Choose Folders… and Done. | User choice in round 3b; matched the recommendation. |

In round 3, the form showed option previews in three narrow columns, which squeezed the designs. The user asked to see the settings window, menu and first run again in a single full-width column. Round 3b decided them.

## Round 4 — 2026-11-18

Source: the user's submitted grill-form ("Apparate decisions — round 4"), asked after the [settings deep-link spike](spikes/2026-11-18-settings-deep-links.md), the [panel latency spike](spikes/2026-11-18-panel-latency.md) and the draft [implementation plan](plan.md).

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-028 | The DEC-008 budgets stay as accepted, as provisional end-to-end goals. They are measured properly during the build (M6), then revisited. | User choice; matched the joint recommendation of Claude and Codex. |
| DEC-029 | When System Settings is already open, Apparate opens the settings link directly. It does not quit System Settings first, and there is no "Close and reopen" action. | User choice of Codex's option, with the note "just open directly, no need to close and reopen", citing jstack's `rule-lean`. Claude had preferred quitting first; Codex had proposed the extra action. |
| DEC-030 | The web search prefix is `?`. | User choice; matched the recommendation. Confirms the prefix left open in DEC-017. |
| DEC-031 | A query containing `/` searches full paths. Other queries match names only. | User choice; matched the recommendation (Codex's proposal in the [alignment](research/alignment.md)). |
| DEC-032 | **Provisional:** no other default prefixes, so the defaults are `'` files and folders, `.` settings and `?` web. Users can add or change prefixes in settings. | Not answered: the question was left untouched, and grill-form treats that as unresolved, not as "none". These defaults match the recommendation and stand until the user answers. Asked again in round 5. |
| DEC-033 | `.gitignore` handling has a switch in the settings Folders tab, on by default. | User choice; matched the recommendation. Refines DEC-006. |
| DEC-034 | The public repository uses the MIT licence. | User choice; matched the recommendation. |
| DEC-035 | None of the four icon directions. Rework the icon as a serious, sleek direction, not in the style of Klip. | User's note ("rework. don't do it in the style of klip. do a serious, sleek direction"). A new set of four directions follows. |
| DEC-036 | Codex builds and Claude reviews. Claude gives detailed guidance for each milestone, with visual and non-visual references. Codex follows it but can push back. Disagreements between them go to the user in a grill-form. | User choice with this note. It fixes the roles left open in DEC-011; Claude had recommended the reverse. |
| DEC-037 | The project is under local git, with one commit per milestone. Nothing is pushed without the user's go-ahead. | User choice; matched the recommendation. |

## Observed from the reference apps

Klip, Yacht and Portia (in `~/Projects`) are SwiftPM packages built by a `build.sh` script with Command Line Tools only. They are pure AppKit (no SwiftUI) menu bar apps. Each is released as a zip or DMG on GitHub Releases, ad-hoc signed and not notarized. Klip signs with a fixed designated requirement (`identifier "local.klip"`), which keeps privacy grants valid across rebuilds. These are observations, not decisions for Apparate; round 2 asks whether to follow them.

## Not yet decided

- The app icon and menu bar glyph: a new set of serious, sleek directions ([DEC-035](#round-4-2026-11-18)), in round 5.
- Whether there are default prefixes beyond `'`, `.` and `?` ([DEC-032](#round-4-2026-11-18) is provisional), in round 5.
- Creating the GitHub repository and publishing a release need the user's go-ahead when M7 is reached.
