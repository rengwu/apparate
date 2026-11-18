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
- A user-action failure activates the app and then shows a standard alert with the item’s name and reason; the panel stays hidden. Hotkey registration failure is the only other modal error. Config, catalog, access-persistence and usage errors are logged. Only ENOENT/ENOTDIR counts as missing and removes the item. Permission/other failures retain it.
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
