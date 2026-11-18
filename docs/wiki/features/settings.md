---
title: Settings
section: Features
updated: 2026-11-19
---
# Settings

**FEAT-settings.** One retained native preferences window with General, Search and Folders toolbar tabs. Basis: [M5 guide and accepted pushback](../build/m5-settings-menu-first-run.md#pushback-and-answers). This is Apparate's preferences; searchable macOS panes remain [System Settings items](settings-items.md).

## Entry points and prerequisites

Open **Settings…** from the menu, press ⌘, in the launcher, reopen the app, or choose **Choose Folders…** in setup. Each route uses the same controller; the launcher hides and releases its foreground activity first. Settings resizes to the selected tab. ⌘W closes the window and ⌘Q quits through the application menu. Native presentation and global key delivery require the supervised checks below.

## Expected outcomes

General records a shortcut with ⌘, ⌥ or ⌃. Esc, tab change, closing or losing key status cancels recording. The current global shortcut is consumed by the recorder while recording. A replacement registers before saving, keeps the previous token until the save succeeds, and rolls back on failure. The menu shows the active key; if an external config requests an unavailable key, Settings explains which old key is still active. Focus refresh retries the configured key without duplicating an existing registration.

The Spotlight notice requires both enabled key 64 and an actual ⌘Space binding. Missing or malformed preferences are unknown, not a conflict or success. The app only reads `com.apple.symbolichotkeys`; the keyboard link opens the standard Shortcuts anchor. macOS may show its last selected category.

Launch at login reads `SMAppService.mainApp.status`, never config: enabled is on, not registered off, requires approval mixed with inline explanation, and unavailable disabled. Changes and focus refresh reread the service. Pending approval can be disabled. Failure remains inline and does not pretend the request succeeded.

Search uses 24 pt rows with vertically centred fields and edits one prefix per scope. + chooses a scope that has none, then a symbol; − removes the selected entry. Shared config validation rejects duplicates, letters, `/` and `~`. DuckDuckGo, Google, Bing and Kagi presets use HTTPS templates with `{query}`; the selected preset derives from exact URL equality. Custom preserves the saved URL and focuses its field.

Folders displays normalized identities, depth and separate unavailable-root status in constant 36 pt rows. A single name or name/status group is vertically centred, with no empty status line. The folders-only picker accepts multiple selections, excludes packages, and adds a duplicate only once without changing its depth. Picking never probes protected folders. **Allow Access…** appears only when a configured protected root needs checking. **Rebuild** is disabled during indexing. Count and update date come from the file snapshot; relative time refreshes every 30 seconds only while this tab is visible. Index start, finish and failure publish status without waiting for new search results.

Switches, presets and add/remove save immediately. Text and table cells commit on Return or end of editing; Esc restores. Each edit reads fresh config, preserves unrelated external fields and rejects changes to the same edited field. This is not a lock against another process writing in the final filesystem race. Broken config keeps last-valid behavior, disables editing and offers **Show in Finder**; repair re-enables controls. No Reset or Apply button is added.

## Automated verification recipe

Use [M5 verification setup](../verification/setup.md#m5-settings-menu-and-setup). Core checks cover transactional config/key changes, refusal and write failure, presets, path identity, all login and Spotlight states, partial/cancelled access and cached index status. The native check drives owned hidden NSTextField editors, buttons, popups and table selection; it never installs the native services or shows a window.

## Supervised recipes — Untested

Run only in a user-agreed slot, with a backed-up config and agreed fixture folders. These checks are required before M7 release.

1. Open Settings through menu, panel ⌘,, app reopen and setup. Confirm one window, selected toolbar item, per-tab size, appearance in light/dark, focus return, ⌘W and ⌘Q. Reopen with the status icon hidden. Check ordinary text editing, selection, Tab, undo/cut/copy/paste and non-US keyboard layout.
2. Record an agreed safe shortcut; cancel using Esc, tab, close and focus loss. Try a known occupied key and confirm the previous key still opens the launcher. Confirm menu text tracks the actual key. With the user's agreement, inspect Spotlight's binding, free ⌘Space manually and return; Apparate should retry registration. Restore the user's shortcut preferences afterward. Never edit symbolichotkeys automatically.
3. Toggle launch at login only with explicit supervision. Compare the checkbox against Login Items, including pending approval when available, a refused change and disable. Restore the starting registration. The test harness never performs these changes.
4. Edit valid/invalid prefix, URL and depth; verify saved JSON after Return, tab/close and Esc. Make an unrelated external edit during a draft, then a conflicting edit; confirm preservation/rejection. Break JSON, exercise Show in Finder, repair it and verify controls recover.
5. Pick several agreed fixture directories and cancel once; confirm packages cannot be selected as roots, a duplicate retains depth, and the selected folder remains the same after external reorder. Change .gitignore handling, rebuild and observe count/time plus start/finish. Follow [folder access](access.md) for actual privacy prompts; selecting folders itself must not prompt.

## Coverage and limitations

Hidden content renders cover layout and inline states, not toolbar/window chrome, focus, real registration, native picker presentation or Login Items. No performance qualification is claimed; M6 owns the finished app budgets. The test harness remains compiled into this development build; its removal from distribution remains M7 work.

## Verification history

- [M5 automated verification](../verification/runs/2026-11-18T212428Z-m5.md).

- [M5 post-review table-layout fix](../verification/runs/2026-11-18T212428Z-m5.md#post-review-fix) — compact rows and centred content; native editing checks and light/dark renders passed.
