---
title: Supervised session
section: Verification
updated: 2026-11-19
status: Waiting for the user
---
# Supervised session

The checks that only work on the real screen, with real keys and real system actions. Automated runs deliberately never do these: they would take your keyboard focus, change system state, or prompt for permissions on your Mac. All of them must pass before the 0.1.0 release (M7).

The detailed recipes stay where they were written: [M2 supervised checks](runs/2026-11-18T164001Z-m2-supervised.md), [panel](../features/panel.md), [settings](../features/settings.md), [menu](../features/menu.md) and [first run](../features/first-run.md). This page puts them in one order that keeps disruption low.

## How it works

- **About 45 minutes**, in four parts. Each part can be done on its own day.
- **You press the keys; Claude prepares and records.** Claude builds the signed app, launches it, tells you each step and what should happen, and writes down what you observe. Screenshots are taken only with your OK, of the Apparate window only.
- **Your real settings are untouched.** The app runs with its own test data folder, and a test shortcut (for example ⌃⌥⌘F12) until the step that is about ⌘Space.
- **Anything with lasting effects asks first:** launch at login, folder permissions, Lock, Sleep, Restart.

## Part 1 · The windows (about 15 minutes, nothing disruptive)

1. **First run.** Launch the test build. The setup window appears once. Check that step 1 (shortcut) and step 2 (folders) read correctly, that Done closes it with steps incomplete, and that it does not come back on the next launch.
2. **Menu bar.** The outlined puff in the menu bar, in light and dark mode. Open the menu: Open Apparate (with the shortcut), Settings…, Quit Apparate.
3. **Panel.** Press the test shortcut from another app. Type, and check the text appears at once. Arrows down to row 50 and back, scroll with the trackpad, ⌘1 and ⌘9, click a row, Esc (clears, then closes). Matched letters bold, folder paths shown.
4. **Settings.** ⌘, from the panel. General, Search and Folders tabs; record a new shortcut, cancel one with Esc; edit a prefix (and an invalid one); switch the search engine; add a folder with the picker, change its depth, remove it.
5. **Hidden icon.** Turn off Show menu bar icon; reach Settings with ⌘, in the panel and by opening the app again; turn it back on.
6. **Launch at login** (asks first). Turn it on, see its real state (including "Approval required" if macOS asks), turn it off.

## Part 2 · Opening things and folder access (about 10 minutes)

1. **Open:** an app you pick, a test file, a test folder; ⌘Return reveals; ⌘C copies the path.
2. **Web:** `?` with spaces, `&`, `+`, `#`, `%`, `/`, an emoji and CJK; the browser gets exactly that query.
3. **System Settings items:** one with System Settings closed, one with it already open; note whether it lands on the item or only the pane.
4. **Failure:** a test file deleted after it was indexed: an alert names it, and the row goes away.
5. **Folder access** (asks first). Allow Access… in setup or in Settings → Folders. Answer the macOS prompts as you like; the statuses must match your answers.
6. **Access after a rebuild.** Claude rebuilds the app; relaunch; check whether macOS asks again. The fixed signing identity is meant to keep the grants.

## Part 3 · Where the panel appears (about 10 minutes)

1. **Spaces and full screen:** call the panel from another Space and from a full-screen app; with two displays, from each.
2. **⌘Space** (optional). If you are ready to switch from Spotlight: Open Keyboard Shortcuts… from setup, turn off Spotlight's shortcut, return, and check that step 1 completes and ⌘Space opens Apparate.
3. **Input method** (if you use one). Compose text: arrows and Return belong to the input method; after committing, Return opens normally.
4. **VoiceOver** (optional). The result list reads title, location, kind and position; selection beyond row 9 is announced and revealed.

## Part 4 · System commands (optional, each on its own)

Show Trash first; it is harmless. Lock Screen, Sleep and Restart only when you choose, with your work saved: Return arms Restart and a second fresh Return confirms it, and arming can be cancelled. Running the real Restart is a separate choice.

## Recording

For each step: what happened, pass or fail, and the build's hashes. No real file names, paths, document names or account details go into the records. A failure gets fixed and rechecked before M7.
