---
title: Decisions
section: Planning
updated: 2026-11-24
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
| DEC-032 | No other default prefixes: the defaults are `'` files and folders, `.` settings and `?` web. Users can add or change prefixes in settings. | Left untouched in round 4, so recorded as provisional; confirmed by the user in round 5 ("No others, just these three"). |
| DEC-033 | `.gitignore` handling has a switch in the settings Folders tab, on by default. | User choice; matched the recommendation. Refines DEC-006. |
| DEC-034 | The public repository uses the MIT licence. | User choice; matched the recommendation. |
| DEC-035 | None of the four icon directions. Rework the icon as a serious, sleek direction, not in the style of Klip. | User's note ("rework. don't do it in the style of klip. do a serious, sleek direction"). A new set of four directions follows. |
| DEC-036 | Codex builds and Claude reviews. Claude gives detailed guidance for each milestone, with visual and non-visual references. Codex follows it but can push back. Disagreements between them go to the user in a grill-form. | User choice with this note. It fixes the roles left open in DEC-011; Claude had recommended the reverse. |
| DEC-037 | The project is under local git, with one commit per milestone. Nothing is pushed without the user's go-ahead. | User choice; matched the recommendation. |

## Round 5 — 2026-11-19

Source: the user's submitted grill-form ("Apparate icon — round 5").

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-038 | None of the four sleek icon directions. Start the icon again from scratch, with the work of designer Katya Neray (contra.com/katyaneray/work) as the reference; earlier icon briefs no longer apply. | User's note: "try again with the redesign. from scratch. ignore all previous instructions. heres your reference https://contra.com/katyaneray/work". |
| DEC-039 | Confirms DEC-032: no default prefixes beyond `'`, `.` and `?`. | User choice; matched the recommendation. |

## Round 6 — 2026-11-19

Source: the user's submitted grill-form ("Apparate — round 6").

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-040 | None of the four reference-style icon directions yet; draw four more. | User's note: "give me four more". |
| DEC-041 | No user-added app folders. An app found in an indexed folder ranks and opens as an app. | User choice; matched the recommendation. Changes the plan's M2 app sources and M3 file kinds. |
| DEC-042 | Claude sets up local git and commits M1 and M2. | User choice; matched the recommendation. Done on 2026-11-19: `bf15efe` (M1) and `87a6c41` (M2). |

## Round 7 — 2026-11-19

Source: the user's submitted grill-form ("Apparate icon — round 7").

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-043 | The icon direction is F · Poof: the puff of smoke when you apparate, glowing on black. Explore more variations of it before refining. | User choice, with the note "lets explore more variations of poof". Claude had recommended E · Doorway. |

## Round 8 — 2026-11-19

Source: the user's submitted grill-form ("Apparate icon — round 8").

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-044 | None of the four Poof variations (glow, face, violet tile, prismatic). Explore different shapes instead of colours and decorations: the puff looked too symmetrical. | User's note: "i was wondering if we could have more shape variations, rather than just color or decorations. it looks too symmetrical". Round 9 offers four asymmetric silhouettes in one colour. |

## Round 9 — 2026-11-19

Source: the user's submitted grill-form ("Apparate icon — round 9").

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-045 | Keep the Poof a round-ish ball. The variations wanted are of that ball itself, like different random seeds of the same recipe, not new silhouettes (curl, burst, trail, ring). | User's note: "no, keep the smoke shape round-ish, like a normal ball of poof. i was just asking for more variations of that ball of poof, like different RNG seeds". Round 10 offers eight seeded balls. |

## Round 10 — 2026-11-19

Source: the user's submitted grill-form ("Apparate icon — round 10").

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-046 | The icon is the ball of poof generated from seed 10, in the round-7 glow on black. Reposition its sparkles so the composition is visually balanced but not symmetrical. | User choice (G · Seed 10), with the note "position the star/sparkles so that it looks visually balanced (but not symmetrical)". Round 11 offers two sparkle layouts and the menu bar glyph. |

## Round 11 — 2026-11-19

Source: the user's submitted grill-form ("Apparate icon — round 11").

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-047 | The icon's sparkles: the largest at the upper left, a medium one at the right, a small one at the lower left (layout B). The icon is final; see [App icon](design/icon.md). | User choice. Claude had recommended layout A. |
| DEC-048 | The menu bar glyph is the puff's outline, as a template image. | User choice; matched the recommendation. |

## Round 12 — 2026-11-19

Source: the user's submitted grill-form ("Apparate — round 12").

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-049 | M6's on-screen speed runs happen unattended, and only after the user says in the chat that they are away. | User choice; matched the recommendation. |
| DEC-050 | The supervised session's optional checks are launch at login and switching ⌘Space from Spotlight. The input method, VoiceOver, Lock Screen, Sleep and a real Restart are left out; they stay Untested and the release notes say so. Arming and cancelling Restart is still checked. | User choice. Claude had also recommended Lock Screen and Sleep. |

## Round 13 — 2026-11-19

Source: the user's messages in the chat during the supervised session, with screenshots (in the [UI follow-up guide](build/ui-follow-up.md)), and the round-13 to round-18 grill-forms. DEC-059 to DEC-061 came from the chat on 2026-11-20 (round 19).

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-051 | The setup window drops status text that says nothing, such as "Ready — Apparate holds …" next to a ✓ and "Not checked" for each folder. Settings keep their layout ([DEC-025](#round-3-ui-design-spike-2026-11-18)), but their groups, options and input fields take their style from Rex: grouped cards, switches, a keycap shortcut button, and Rex-style menus, fields and buttons. The settings stay AppKit ([DEC-013](#round-2-2026-11-18)). | The user: "i don't like this. rule-plain-ui." and "keep our current settings layout, but can the rest of the settings UI (e.g. options, and input fields) take inspiration from Rex?", with three screenshots of Rex's settings. |
| DEC-052 | The panel opens as just its search strip. When results appear it grows downward to fit them, up to nine rows, and shrinks back when the field is cleared. This replaces the fixed size in [DEC-023](#round-3-ui-design-spike-2026-11-18); the rows, footer and other details stay. | User choice in the round-13 form; matched the recommendation. The user asked after seeing the empty full-size panel: "alfred and spotlight search only shows the input strip". |
| DEC-053 | Result rows drop the em dash between the title and its location. How the location shows is a setting with three choices: next to the title after a gap (A), aligned right before the ⌘1–9 hints (B), or on a second line under the title (C). The default is A, inline. | User in the round-14 visual spike: "i accept the first three options: A B C. make it customizable in settings". The default is the user's choice in round 15 (Claude had recommended B, right). D (parent folder only, full location in the footer) was not chosen. |
| DEC-054 | Folders outside the indexed ones are reached two ways. **By path:** a query starting with `/` or `~/` lists that folder directly, without the index, and narrows by what follows the last `/`; names starting with a dot appear once the typed name starts with a dot; Tab steps into the selected folder. A `/` elsewhere in a query still searches indexed paths ([DEC-031](#round-4-2026-11-18)). **By name:** new configs also index the home folder and the top of the disk, one level deep, and equal matches prefer the shorter path. To make ~/Library findable, the Finder "hidden" flag no longer excludes an item; names starting with a dot and `node_modules` still do ([DEC-006](#round-1-2026-11-18)). | User choice in round 16 (C), after asking for Applications, Library, Application Support, ~/.ssh, ~/.codex and ~/.config. Claude's recommendation. The hidden-flag change is Claude's, needed for Library; the user can overrule it. |
| DEC-055 | Items whose names start with a dot are indexed by name wherever the index looks, but Apparate doesn't look inside them. They appear only when the typed name starts with a dot (for example `'.config`, `'.env`, `'.git`); other searches never show them. A dot folder added as its own folder in Settings is indexed inside as usual. This narrows [DEC-006](#round-1-2026-11-18) for dot names; `node_modules` stays excluded, and the `.gitignore` switch still applies to dot items. | User choice in round 17 (B), after `'.config` found vite.config.js instead of ~/.config. Claude had recommended A (only the hidden folders in the home folder). |
| DEC-056 | Tab completes the selected result in every search, not only in path queries. A folder becomes its path plus `/`, which lists what's inside it; a file becomes its path; an app, setting or command becomes its name. Tab never moves focus out of the field. | The user: "when i have an suggested item highlighted and press tab, it should autocomplete. kinda like how terminal emulators autocomplete a half-typed valid name". What each kind completes to is Claude's choice; the user can change it. |
| DEC-057 | Open With: a key (⇧Return by default, changeable in Settings) on a file or folder turns the panel's list into the apps that can open it. The app last chosen for that kind of file comes first, then the default app, then the rest A–Z; typing also reaches every other app. Return opens with the selected app; Esc goes back to the results. | User choice in round 18: Claude's suggested version as a whole, with the note "make this hotkey configurable". Researched against Raycast's Action Panel and Alfred's File Actions. |
| DEC-058 | → completes a selected folder the same way Tab does ([DEC-056](#round-13-2026-11-19)), when the caret is at the end of the text with nothing selected. Anywhere else, and on any other kind of result, → moves the caret as usual. | The user, while trying the Tab build: "pressing right arrow key on a highlighted folder works the same as 'tab', autocompleting it". The caret-at-end condition is Claude's, so → still moves the caret while editing. |
| DEC-059 | The Folders tab gets a "Skip hidden files" switch below the `.gitignore` switch, **on** by default. On: items whose names start with a dot are not indexed at all, so `'.config` finds nothing from the index; typing a path such as `~/.config` still works. Off: [DEC-055](#round-13-2026-11-19) as before. A dot folder added as its own folder in Settings is still indexed inside either way. | The user: "we should have a similar switch here for ignoring hidden files". What on means was the user's choice in round 19, matching Claude's recommendation. The user first chose off by default, then changed it to on: "it should be on by default. i'm considered a power user". Built in [UI follow-up section 12](build/ui-follow-up.md#12-skip-hidden-files). |
| DEC-060 | In a path query (one with `/`), each folder skipped between the matched parts, and between the last matched part and the result, lowers the result's score. `apparate/build` then ranks `~/Projects/apparate/build` above `~/Projects/apparate/docs/wiki/build`, even after one open of the deeper folder; a folder opened often can still rise. Searches without `/` are unchanged. | The user, after `docs/wiki/build` (opened once) outranked `apparate/build`: "it has less depth, and furthermore its an exact match". Claude proposed the skipped-folder penalty; the user: "cool solution, lets do it". Built in [UI follow-up section 13](build/ui-follow-up.md#13-path-queries-prefer-the-tightest-path). |
| DEC-061 | Release 0.1.0 without the supervised on-screen checks (M2, M4, M5 and the UI follow-up) and without the M6 on-screen speed measurements. The release notes list them as not yet checked on a real Mac. This waives the rule Claude set in the M5 guide that M7 would not release until they passed. | The user: "waive the checks for now, proceed with the release". The checks stay open for a later session. |

## Round 20 — 2026-11-21

Source: the user's chat request, then two grill-forms: "Apparate icon — background tint" (round 20) and "Apparate icon — Dusk, content size" (round 21).

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-062 | The icon's background changes from near-black to Dusk: a dark blue at the top fading to plum at the bottom, with a soft violet lift behind the ball. It stays dark. The poof, its colours and the sparkle layout stay as in [DEC-046](#round-10-2026-11-19) and [DEC-047](#round-11-2026-11-19). | The user: "i like the current icon, but i think the background can be better than pure black. maybe add a slight tint or either purple, or blue. (still keep it dark though)". User choice in round 20 (D · Dusk) from Plum, Indigo, Midnight and Dusk, all equally dark. Claude had recommended B (Indigo). |
| DEC-063 | The poof and sparkles are drawn 20% larger inside the same tile. The sparkles keep their size relative to the ball but move outward less than it grows, so they stay clear of the tile edge. | The user's note on round 20: "can we make the contents a little bigger? (lesser padding / empty space)". User choice in round 21 (120%) from 110%, 120% and 130%; matched the recommendation. |

## Round 22 — 2026-11-24

Source: the user's chat request (with a screenshot of the panel, not kept because it shows real file names), then the grill-form "Drag results out — Claude's calls" (round 22) on the calls Claude made in the [drag-out brief](build/drag-out.md).

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-064 | File, folder and app results can be dragged out of the panel and dropped anywhere that takes a drag from Finder; the drop carries the item's file URL. Pressing a row selects it, and releasing without dragging opens it. Settings items, commands and web searches don't drag. | The user: "it's be nice if i can mouse drag and drop files to anywhere, as if i'm dragging it from finder". Built and committed in `9053c75`. |
| DEC-065 | The panel stays while the drag is over it and hides as soon as the drag leaves it, so whatever is behind it can take the drop. A drag released over the panel cancels and leaves the panel as it was. | Claude's call in the brief; the user kept it in round 22 from four choices (hide when the drag starts, stay until a drop, stay until closed). |
| DEC-066 | Settings → General gets a choice for dragged files: **Like Finder** (the default) or **Never move**. Like Finder lets the destination move the file, so a drop into a Finder folder on the same disk moves it and ⌥ copies. Never move takes the move away, so that drop copies. Apparate never copies, moves or deletes a file itself. | Claude's call was Like Finder only. The user in round 22: "make this toggleable in settings. between like finder and never move. default: like finder." |
| DEC-067 | The drag image is the row's icon only, without the name. | Claude's call; the user kept it in round 22. Claude had recommended adding the name, like Finder. |
| DEC-068 | A completed drop counts as a use for ranking, the same as opening the item. A cancelled drag doesn't count. | Claude's brief left drags out; the user chose to count completed drops in round 22, matching Claude's recommendation there. |

## Round 23 — 2026-11-25

Source: the user's chat requests while trying the drag-out build.

| ID | Decision | Basis |
| --- | --- | --- |
| DEC-069 | When a drag leaves the panel, the panel fades out over 0.15 seconds instead of vanishing. Only that hide fades; Esc, losing focus, opening a result and the others stay instant. | The user: "can we add a very short fade out animation when it disappears on our drag?" The duration and keeping other hides instant are Claude's calls, in [drag-out section 7](build/drag-out.md#7-fade-out-when-the-drag-leaves). |
| DEC-070 | Release the drag work as **0.2.0** (a new feature, so the minor number goes up). The on-screen drag checks are not all done; the release notes say which haven't been checked by hand. | The user tried the fade build and said "looks great. commit, push, release." The version number is Claude's call. |

## Observed from the reference apps

Klip, Yacht and Portia (in `~/Projects`) are SwiftPM packages built by a `build.sh` script with Command Line Tools only. They are pure AppKit (no SwiftUI) menu bar apps. Each is released as a zip or DMG on GitHub Releases, ad-hoc signed and not notarized. Klip signs with a fixed designated requirement (`identifier "local.klip"`), which keeps privacy grants valid across rebuilds. These are observations, not decisions for Apparate; round 2 asks whether to follow them.

## Not yet decided

- ~~Creating the GitHub repository and publishing a release need the user's go-ahead when M7 is reached.~~ Done 2026-11-21 at the user's request: public `rengwu/apparate`, release `v0.1.0`.
