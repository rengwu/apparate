---
title: Settings deep-link spike
section: Spikes
updated: 2026-11-18
status: Complete
---
# Settings deep-link spike

Run by Claude on 2026-11-18, after the user asked to move the next steps forward. Codex reviewed it the same day; its corrections are applied below.

## Question

Apparate lists System Settings items from the system's `.searchTerms` files (see the [UI design spike](2026-11-18-ui-design.md)). Each item has a pane (an extension bundle ID) and an anchor key. Does this URL take the user to the item?

```text
x-apple.systempreferences:<extension bundle ID>?<anchor key>
```

The [research alignment](../research/alignment.md) left this unverified.

## Answer

For most of the items tested, yes. When System Settings was not running, every link opened the right pane. When it was already showing a sheet, later links were ignored.

Results with System Settings not running beforehand:

| Result | Items | Examples |
| --- | --- | --- |
| Named control shown after navigation (sheet, subpage, tab or scroll) | 32 of 57 | Input Sources sheet (the anchor also used for Keyboard layouts), Text replacements, DNS servers (Wi‑Fi Details, DNS tab), Camera, FileVault, Night Shift, Hot Corners, Zoom |
| Right sheet or subpage opened; named control not shown | 4 | Shortcuts (opened on its last-used category), Caps Lock switching, Power Nap, Voice (Read & Speak) |
| Pane opened; named control already visible without navigation | 11 | Firewall, Login options, Time zone, AirPlay Receiver |
| Pane opened; named control not reached | 10 | Screen Time (`path=` anchors), Hostname, Login Items → Extensions, Default web browser, Bluetooth keyboard setup, Dictation (only its heading visible), Touch Bar (this Mac has none) |
| Nothing opened | 0 | |

Of the 16 Keyboard anchors, 11 showed the named control. One of those is `InputSources`. The catalog uses that anchor for "Keyboard layouts", the user's example in [REQ-004](../requirements.md), and it opened the Input Sources sheet.

These are Claude's judgements from screenshots. One anchor can cover several catalog titles, and a sheet may show some of them but not others. The results do not extend to the 490 anchors that were not tested.

## System Settings already open

The main test force-quit System Settings before each link. Real use often finds it open, so three sequences were also tried with it left running:

- **No sheet showing:** later links reached Sound input, Zoom, FileVault and the Input Sources sheet. How quickly it navigated was not measured, because the driver's wait condition was already true for the old window.
- **Input Sources sheet showing:** all 6 later links were ignored, and the window stayed on that sheet. Only this one sheet was tested.
- **Polite quit, then open:** `NSRunningApplication.terminate()` was followed by the Night Shift link, which opened correctly in this one sequence.
  - In the [recorded output](../attachments/2026-11-18-settings-deep-links/quitfirst-output.txt), System Settings was gone 0.08 s after the request, and a window appeared about 2.2 s after the start.
  - `terminate()` is a request, not a guarantee. It could also interrupt something the user was doing in System Settings.

Cold opens took 0.89–1.85 s from the link to a titled window.

So Apparate needed a policy for when System Settings is already running. Claude and Codex differed on it:

- **Quit first (Claude):** if System Settings is running, quit it, then open the link. It lands more reliably, costs about 2 s, and may interrupt the user.
- **Open directly (Codex):** open the link as is. It is fast, and the user is never interrupted. If a sheet blocks the link, nothing happens, so Apparate offers an explicit "close and reopen System Settings" action.

The user chose to open directly, without the extra action ([DEC-029](../decisions.md#round-4-2026-11-18)).

No reliable way to detect an open sheet without extra permissions was found.

## Method

- macOS 27.0, English, on the user's Mac.
- 57 anchors from 19 panes:
  - every Keyboard anchor;
  - 1–6 anchors from each other pane, including Privacy & Security, Displays, Desktop & Dock, Network, Sound, Battery, Screen Time, Sharing and Accessibility.
- For each pane, the pane URL without an anchor was captured first as a baseline.
- Main test, for each link:
  - force-quit System Settings (`forceTerminate()`);
  - open the URL;
  - wait until a System Settings window has any title, then 2.2 s more;
  - capture the window with `screencapture -l`.
- The wait does not check that the requested destination appeared. The 2.2 s settle time covers that.
- Classification: Claude compared each capture with its baseline by eye. A pixel diff was used only to spot captures that did not change. The classes were tightened after Codex's review.
- Sources, SHA-256:
  - [driver](../attachments/2026-11-18-settings-deep-links/drive.swift.txt) `650363a5…eac0`;
  - [quit-first test](../attachments/2026-11-18-settings-deep-links/quitfirst.swift.txt) `b9ee6c8f…b9`.

## Evidence

The Apple Account name and picture, and the user name in Users & Groups, are covered in grey. The captures also show some apps installed on this Mac. The system switched to Dark appearance partway through the run; this did not affect navigation.

- [Per-item results (CSV)](../attachments/2026-11-18-settings-deep-links/results.csv)

Keyboard (the first image is the baseline):

![Keyboard anchors 00–05](../attachments/2026-11-18-settings-deep-links/sheet-s00.jpg)

![Keyboard anchors 06–11](../attachments/2026-11-18-settings-deep-links/sheet-s01.jpg)

![Keyboard anchors 12–16 and the Privacy & Security baseline](../attachments/2026-11-18-settings-deep-links/sheet-s02.jpg)

Other panes:

![Privacy & Security](../attachments/2026-11-18-settings-deep-links/sheet-s03.jpg)

![Displays and Desktop & Dock](../attachments/2026-11-18-settings-deep-links/sheet-s04.jpg)

![Desktop & Dock and Menu Bar](../attachments/2026-11-18-settings-deep-links/sheet-s05.jpg)

![Menu Bar, Network and Sound](../attachments/2026-11-18-settings-deep-links/sheet-s06.jpg)

![Sound and Lock Screen](../attachments/2026-11-18-settings-deep-links/sheet-s07.jpg)

![Battery and Screen Time](../attachments/2026-11-18-settings-deep-links/sheet-s08.jpg)

![Sharing, Users & Groups and Wallpaper](../attachments/2026-11-18-settings-deep-links/sheet-s09.jpg)

![Wallpaper, Spotlight, Language & Region and Login Items](../attachments/2026-11-18-settings-deep-links/sheet-s10.jpg)

![Login Items and Accessibility](../attachments/2026-11-18-settings-deep-links/sheet-s11.jpg)

![Date & Time and AirDrop & Continuity](../attachments/2026-11-18-settings-deep-links/sheet-s12.jpg)

System Settings already open:

![An open sheet blocks later links](../attachments/2026-11-18-settings-deep-links/sheet-warm.jpg)

![Without a sheet, later links work](../attachments/2026-11-18-settings-deep-links/sheet-warm2.jpg)

![Quit first, then open](../attachments/2026-11-18-settings-deep-links/sheet-quitfirst.jpg)

## Consequences for the build

- Open each settings item with its pane and anchor from `.searchTerms`.
- If the URL fails to open, report the error. A successful open call does not prove navigation happened.
- Screen Time's `path=` anchors did not navigate. Keep them, since they still open Screen Time.
- Settings rows show which pane they open, so a partial result is not a surprise.
- When System Settings is already running, open the link directly ([DEC-029](../decisions.md#round-4-2026-11-18)).

## Limits

- One Mac, one macOS build, English only.
- 57 of the 547 anchors were tested. Accessibility alone has 342, and 4 of them were tested.
- "Shown" is Claude's judgement from screenshots, not read from the interface.
- The already-open behaviour was tried in 3 short sequences with one kind of sheet.
- The anchors for the legacy Date & Time pane (`DateAndTime.prefPane`) were not tested separately.
