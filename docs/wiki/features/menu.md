---
title: Menu bar
section: Features
updated: 2026-11-19
---
# Menu bar

**FEAT-menu.** The outlined-puff template glyph opens **Open Apparate**, **Settings…**, a separator and **Quit Apparate**. Basis: [M5](../build/m5-settings-menu-first-run.md) and [the final glyph](../design/icon.md).

## Entry points and expected outcomes

The General switch creates or removes the status item immediately. Both bundled template PNG resolutions are used. Open displays the **active** launcher shortcut, including the old shortcut when replacement fails. Settings shows ⌘, and Quit ⌘Q. Open shows the launcher; Settings uses the retained preferences route; Quit terminates the app normally.

Hiding the icon leaves panel ⌘, and ⌘Q, app reopen, and the Settings/setup application menus available. The latter include ordinary Edit commands and ⌘W. The closed menu graph is real `NSMenu`; test mode replaces status-item installation and never changes the visible menu bar or the process's main menu.

## Verification recipe

Run the [M5 hidden check](../verification/setup.md#m5-settings-menu-and-setup). It asserts actual menu order, key equivalents, action routing and hide state, with zero native status items. It also checks the panel's Settings route releases its visible-session activity. Resource hashes and signing are in the [run](../verification/runs/2026-11-18T212428Z-m5.md).

## Supervised recipes — Untested

In the agreed native session, inspect the glyph at 1×/2× in light and dark, open the menu, verify the shortcut display and all three actions. Hide the icon, reach Settings through panel ⌘, and by reopening the app, then restore the preference. Inspect normal menu tracking, keyboard navigation and VoiceOver labels. No native menu is opened by automated verification; appearance remains outside its pass.

## Verification history

- [M5 automated verification](../verification/runs/2026-11-18T212428Z-m5.md).
