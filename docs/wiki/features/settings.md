---
title: Settings
section: Features
updated: 2026-11-20
---
# Settings

**FEAT-settings.** One retained native preferences window with General, Search and Folders toolbar tabs. Basis: [M5 guide and accepted pushback](../build/m5-settings-menu-first-run.md#pushback-and-answers). This is Apparate's preferences; searchable macOS panes remain [System Settings items](settings-items.md).

The [UI follow-up](../build/ui-follow-up.md) (DEC-051) retains the tab order, content and 620-point width, adding shared AppKit cards, native switches, rounded fields and a shortcut keycap. Content grows within a bounded scroll area; long folder lists and error messages stay reachable. Plain labels show actionable state rather than success or unchecked boilerplate.

## Entry points and prerequisites

Open **Settings…** from the menu, press ⌘, in the launcher, reopen the app, or choose **Choose Folders…** in setup. Each route uses the same controller; the launcher hides and releases its foreground activity first. Settings resizes to the selected tab. ⌘W closes the window and ⌘Q quits through the application menu. Native presentation and global key delivery require the supervised checks below.

## Expected outcomes

General records the Open Apparate shortcut with ⌘, ⌥ or ⌃. Esc, tab change, closing or losing key status cancels recording. The current global shortcut is consumed by the recorder while recording. A replacement registers before saving, keeps the previous token until the save succeeds, and rolls back on failure. The menu shows the active key; if an external config requests an unavailable key, Settings explains which old key is still active. Focus refresh retries the configured key without duplicating an existing registration.

**Location in results** is a native, labelled segmented control on General, in its own card: Inline / Right / Below. Inline is the default. A choice persists immediately and updates an open launcher without rerunning its search; external config changes refresh the selection. A stale choice is rejected, failed saves retain the previous value, and broken config disables the control.

The shortcut card groups the shortcut and its error description with a separate conditional Spotlight/action row. Prefix characters are centered in compact fields. Depth numbers and native stepper arrows share one rounded fill. Single-line titles center on their controls.

The Spotlight notice requires both enabled key 64 and an actual ⌘Space binding. Missing or malformed preferences are unknown, not a conflict or success. The app only reads `com.apple.symbolichotkeys`; the keyboard link opens the standard Shortcuts anchor. macOS may show its last selected category.

Launch at login reads `SMAppService.mainApp.status`, never config: enabled is on; not registered and not found are off with an enabled switch; requires approval is on with an inline explanation. A never-registered ad-hoc bundle can report not found and must still allow registration. Unavailable is reserved for runs outside an identified `.app` bundle and disables the switch with an explanation. Changes and focus refresh reread the service. Pending approval can be disabled. Failure remains inline and does not pretend the request succeeded.

Search uses grouped card rows with right-aligned rounded fields, one prefix per scope. **Add Prefix** chooses a scope that has none, then a symbol; each row has its own keyboard-focusable, accessibility-labelled remove button. Shared config validation rejects duplicates, letters, `/` and `~`. DuckDuckGo, Google, Bing and Kagi presets use HTTPS templates with `{query}`; the selected preset derives from exact URL equality. Custom preserves the saved URL and focuses its field.

Folders displays normalized identities, a labelled depth field with a native stepper, and separate unavailable-root status in grouped rows. A single name or name/status group is vertically centred, with no empty status line. The folders-only picker accepts multiple selections, excludes packages, and adds a duplicate only once without changing its depth. Picking never probes protected folders. **Allow Access…** appears when any of the three saved Allowed observations is missing, even with no index folders: direct path navigation can reach those folders too. A denied/waiting configured protected root also keeps the retry visible. **Rebuild** is disabled during indexing. Count and update date come from the file snapshot; relative time refreshes every 30 seconds only while this tab is visible. Index start, finish and failure publish status without waiting for new search results.

**Skip hidden files** is a second switch in the same Folders card, directly below **Skip files listed in .gitignore**, with no description. It defaults on even for older configs without the key. Turning it off restores dot-name indexing; typed paths stay available under the existing dot-name filter. Changes save against the last rendered value and trigger one index rebuild; external edits refresh the switch and malformed config disables it.

Indexing uses one small native spinner and secondary **Indexing…** label, 8 points after **Add Folders…**, vertically centered in its button-height row. Its reserved space keeps the buttons and cards stationary when it appears or disappears. The indicator follows the aggregate indexing state immediately; no timer, delay or minimum display time is added. Folder rows have no indexing line. Denied, Not found, Unavailable and Waiting for access remain visible during retries until new results replace them. The Index card retains its existing count/status text. The spinner's accessibility label is **Indexing**; animation runs only while the Folders tab is visible.

Switches, segmented choices, presets and add/remove save immediately. Text fields commit on Return or end of editing; Esc restores. Each edit reads fresh config, preserves unrelated external fields and rejects changes to the same edited field. This is not a lock against another process writing in the final filesystem race. Broken config keeps last-valid behavior, disables editing and offers **Show in Finder**; repair re-enables controls. No Reset or Apply button is added.

## Automated verification recipe

Use [M5 verification setup](../verification/setup.md#m5-settings-menu-and-setup). Core checks cover transactional config/key changes, refusal and write failure, presets, path identity, all login and Spotlight states, partial/cancelled access and cached index status. The native check drives owned hidden NSTextField editors, buttons, native switches, steppers and popups; it never installs the native services or shows a window.

## Supervised recipes — Untested

Run only in a user-agreed slot, with a backed-up config and agreed fixture folders. These checks remain Untested and are waived for 0.1.0 by [DEC-061](../decisions.md#round-13-2026-11-19).

1. Open Settings through menu, panel ⌘,, app reopen and setup. Confirm one window, selected toolbar item, per-tab size, appearance in light/dark, focus return, ⌘W and ⌘Q. Reopen with the status icon hidden. Check ordinary text editing, selection, Tab, undo/cut/copy/paste and non-US keyboard layout.
2. Record an agreed safe shortcut; cancel using Esc, tab, close and focus loss. Try a known occupied key and confirm the previous key still opens the launcher. Confirm menu text tracks the actual key. With the user's agreement, inspect Spotlight's binding, free ⌘Space manually and return; Apparate should retry registration. Restore the user's shortcut preferences afterward. Never edit symbolichotkeys automatically.
3. Toggle launch at login only with explicit supervision. Compare the switch against Login Items, including pending approval when available, a refused change and disable. Restore the starting registration. The test harness never performs these changes.
4. Edit valid/invalid prefix, URL and depth; verify saved JSON after Return, tab/close and Esc. Make an unrelated external edit during a draft, then a conflicting edit; confirm preservation/rejection. Break JSON, exercise Show in Finder, repair it and verify controls recover.
5. Pick several agreed fixture directories and cancel once; confirm packages cannot be selected as roots, a duplicate retains depth, and per-row removal still targets the named folder after external reorder. Change .gitignore handling, rebuild and observe count/time plus start/finish. Follow [folder access](access.md) for actual privacy prompts; selecting folders itself must not prompt.

## Coverage and limitations

Hidden content renders cover layout and inline states, not toolbar/window chrome, focus, real registration, native picker presentation or Login Items. No performance qualification is claimed; M6 owns the finished app budgets. The test harness remains compiled into this development build; its removal from distribution remains M7 work.

## Verification history

- [M5 automated verification](../verification/runs/2026-11-18T212428Z-m5.md).

- [M5 post-review table-layout fix](../verification/runs/2026-11-18T212428Z-m5.md#post-review-fix) — compact rows and centred content; native editing checks and light/dark renders passed.

- [UI follow-up verification](../verification/runs/2026-11-19T064952Z-ui.md) — new card controls, native field/stepper actions, labels, overflow and light/dark states. Spoken VoiceOver remains Untested under DEC-050.

- [Six UI review fixes](../verification/runs/2026-11-19T070456Z-ui-review.md) — centered titles, in-card Spotlight action, compact centered prefixes, integrated native depth stepper, no redundant panel frame calls and aligned magnifier; hidden checks/renders passed, live appearance pending.

- [Result-location setting verification](../verification/runs/2026-11-19T085025Z-row-location.md) — segmented actions, persistence, live launcher update, external edit/conflict and disabled state; all existing Settings/setup states rechecked.

- [Inline-default follow-up](../verification/runs/2026-11-19T090422Z-inline-default.md) — DEC-053 round 15 changes the missing-key/new-config default to Inline; explicit saved choices remain intact.

[Section 5 verification](../verification/runs/2026-11-19T095817Z-path-folders.md) checks that an empty folder list still offers explicit access checking without adding a root or probing automatically.


## Open With shortcut

DEC-057 adds a separate General card, **Open With**, using the same keycap recorder and cancel behavior. It defaults to ⇧Return, is local to the panel and adds no Carbon registration. Shift with a nonprinting key is allowed; Shift-only typing keys are rejected. The recorder and config validator reject panel navigation keys (Tab/Esc/arrows in any modifier combination), the configured launcher key, primary/numbered actions, Quit, Settings and native ⌘A/X/V/Z/⇧Z editing shortcuts. Invalid changes show the ordinary validation message and retain the working key. The recorder uses an expected-value write so external changes cannot be silently overwritten. The launcher recorder keeps its existing ⌘/⌥/⌃ requirement.


[Open With verification](../verification/runs/2026-11-19T123000Z-open-with.md) — DEC-057 shortcut, app groups, Back, success-only history and hidden native checks.

[Login correction verification](../verification/runs/2026-11-20T084750Z-login-icon.md) — a fixture not-found state uses the native status mapping; successful registration turns the switch on, refusal stays off with an inline error, and unsupported runs stay disabled. Real login changes remain supervised.

[Skip hidden files verification](../verification/runs/2026-11-20T113654Z-skip-hidden.md) — native on/off persistence, external conflict/refresh, accessibility label, broken-config disabling and light/dark Folders renders; Core checks cover indexing and one rebuild per toggle.

[Single indexing indicator verification](../verification/runs/2026-11-20T121149Z-indexing-indicator.md) — exact native frame equality across idle/indexing states, retained actionable statuses, both Skip switch actions and light/dark renders. Visible animation and spoken VoiceOver remain supervised.
