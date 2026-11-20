---
title: Opening and commands
section: Features
updated: 2026-11-19
---
# Opening and commands

**FEAT-actions.** Act on the selected result using the typed target from its catalog snapshot, following the [M2 guide](../build/m2-sources-actions-panel.md#3-opening-and-actions). IDs and labels are never parsed to reconstruct targets.

## Entry points and prerequisites

`LauncherSession.onAction` hides the panel before `ActionDispatcher.perform`. Production uses `NativeActionExecutor`; the test profile uses a fake executor. Return opens, Command-Return reveals a filesystem target, and Command-C copies its POSIX path.

## Expected outcomes

- Applications use asynchronous `NSWorkspace.openApplication`. Files/folders, web searches and settings use `NSWorkspace.open`; its Bool means acceptance, not successful browser navigation or settings selection.
- Web replacement percent-encodes a single query value, including spaces, ampersands, plus signs, fragments, percent signs, slashes, emoji and CJK. The template must be HTTP(S) with a host and one placeholder.
- Reveal and Copy path apply only to app/file/folder targets. Only a successful primary open records usage. A history-save failure is reported separately and does not turn an accepted open into a failed action.
- A user-action failure activates the app and then shows a standard alert with the item’s name and reason; the panel stays hidden. Open With discovery errors and hotkey registration failures also use this alert path. Config, catalog, access-persistence and usage errors are logged. Only ENOENT/ENOTDIR counts as missing and removes the item. Permission/other failures retain it.
- Commands are Lock Screen (alias Lock), Sleep, Restart and Show Trash (alias Trash). Lock dynamically resolves the optional private `SACLockScreenImmediate` symbol; Sleep uses `IOPMSleepSystem`; Restart sends the system-process restart Apple event; Show Trash opens the user's Trash folder. Missing APIs or returned errors are reported.
- Restart requires two fresh Returns tied to the same selected item and result generation. Typing, selection movement, new results, composition, Esc and hiding disarm it. Key repeat never confirms it. Click and ⌘1–9 may arm Restart but cannot confirm it; Esc first disarms while preserving the query.

## Verification recipe

Run `swift run ApparateCoreTests` using [setup](../verification/setup.md). Fake adapters assert exact typed calls, every command, exact URL bytes, path operations, usage after success, missing versus failed items and history errors. Temporary filesystem fixtures check existence; tests do not change the clipboard or invoke native commands.

After the signed build, `python3 Tests/smoke-app.py --show panel --query term --action-open` renders synthetic results without presenting or taking focus, invokes a fake open and quits. The receipt must report one fake action and no native effects.

## Coverage and limitations

Native mechanisms are compiled and checked against local SDK declarations/export metadata. Lock has a private ABI; successful return cannot prove that the screen locked. Reveal has no success result. None of the real opens or system commands have been run unattended. Their [supervised recipes](../verification/runs/2026-11-18T164001Z-m2-supervised.md) remain unvalidated. DEC-050 excludes real Lock, Sleep and Restart from the session; they remain Untested and must be disclosed in release notes. Restart arming/cancellation and settings navigation remain eligible session checks. The historical recipes do not authorize excluded actions.

## Verification history

- [M2 automated verification](../verification/runs/2026-11-18T164000Z-m2.md).

## M3 integration

M3 file presence checks use the link entry itself: an existing dangling link remains available for Copy path/Reveal, and a failed open does not falsely evict it as a deleted path. Apps discovered inside indexed folders use the application-open adapter.

- [M3 verification](../verification/runs/2026-11-18T181500Z-m3.md).

- [M4 panel verification](../verification/runs/2026-11-18T200340Z-m4.md) — displayed-ID activation, pending generation guards, Restart input priorities and native fake-action routing.


## Open With

The panel dispatches the original file/folder target plus the chosen application URL and optional resolved content-type identifier. Presence checks run away from the UI thread; a missing chosen app fails without evicting the original item. Native opening uses asynchronous `NSWorkspace.open(_:withApplicationAt:configuration:)`. Acceptance hides the panel and records the original item's use; it is not proof that the receiving app rendered the document. Selecting, filtering, a missing item or a failed open records neither usage nor preference.

Usage and the chosen app are committed in one SQLite transaction after success. The additive schema-3 migration preserves file/index and existing usage data, adding a bounded `open_with` table. Up to 128 content types remember an application URL; the oldest successful choice is evicted. Folders use `public.folder`. Unresolved types can still open and record item usage, but store no type preference. No extension-based key is invented. History-write failure follows the existing nonfatal history-error route. The ordinary successful-open counter remains capped at 2,000 items and decays as before.

Automated checks use fake Workspace lookup/resolution and opening adapters, real temporary SQLite databases and actual hidden editor/panel routing. Native Workspace discovery, launch acceptance, receiving-app behavior and actual keyboard/IME delivery remain supervised/Untested.


[Open With verification](../verification/runs/2026-11-19T123000Z-open-with.md) — DEC-057 shortcut, app groups, Back, success-only history and hidden native checks.
