---
title: Launcher panel
section: Features
updated: 2026-11-19
---
# Launcher panel

**FEAT-panel.** Show a reusable keyboard-first launcher, with plain M2 rows and reliable selection/action state. Basis: [M2 panel guide](../build/m2-sources-actions-panel.md#5-first-panel), DEC-023 geometry and the accepted generation/IME amendments.

## Entry points and prerequisites

`PanelController` owns a retained nonactivating `NSPanel`, built at launch. Production hotkeys use Carbon with `kEventHotKeyExclusive`. `HotKeyRegistration` installs a new key before removing the old one; failed replacement keeps the working key and reports an error. Unchanged keycode/modifier pairs do nothing.

The production config defaults to Command-Space. Automated app runs must instead use [the isolated test driver](../verification/setup.md), which pre-seeds an alternate key and replaces the global registrar with a fake. `APPARATE_SHOW=panel` is available for deliberate checks; visible test profiles require synthetic rows.

## Expected outcomes

The floating panel is 640 × 334 points, with a search field, nine 28-point row slots and a footer. It joins Spaces/full-screen apps, shows without animation, and hides on Esc or losing key status. Rows show icon, title and location. Icons are requested away from the text-matching path, resolved in background work and bounded by a small cache. M4 supplies final row styling and number shortcuts.

Text appears immediately; complete search results arrive asynchronously. A revision is invalidated synchronously. Usage is read once when the panel shows, then reused in memory for every keystroke; no SQLite read is triggered by editing, config changes or source updates. After an accepted primary open finishes recording history, the next showing reads fresh data; an already reopened panel refreshes explicitly. Selection follows its ID across results, falling back to the first row. Return, Command-Return and Command-C pressed while results are pending wait for that generation, never act on old rows. Another edit, source/config change, navigation or hiding cancels the queued action. Initial catalog readiness preserves a queued Return and prevents premature web fallback. Pending queries retain the previous rows, footer and empty-state label. “Searching…” appears only while the first catalog is unavailable.

Arrows move selection; the footer advertises applicable actions. Restart confirmation belongs to the selected ID and generation. While the field has marked text, the input method owns Return/arrows: there is no selection movement, action or arming. Native field-editor behavior still needs a real IME check.

## Verification recipe

Run the Core harness using [setup](../verification/setup.md). Model tests exercise selection changes, generation replacement, queued operations, repeat keys, composition and Restart cancellation. Controlled usage reads from separate showings resolve out of order to prove stale-read rejection, and several edits in one showing assert exactly one read. A fake registrar checks conflicts, unchanged keys, replacement order and cleanup.

`python3 Tests/smoke-app.py --show panel --query term --seconds 2 --output /private/tmp/apparate-panel-check` briefly displays fixture results, saves a view bitmap and diagnostics, then quits. The driver also enters three pending queries synchronously and asserts that the actual table, footer and empty label remain unchanged before the worker can deliver. Inspect the PNG. Repeat with an empty query, `.unmatched` and `?a+b` for empty/no-results/web states. Remove only the check's output directory afterward. Rendering the app-owned view requests no Screen Recording permission, but may not reproduce composited vibrancy.

## Coverage and limitations

The automated run checks native AppKit layout with fixture rows and an injected hotkey callback, not an actual globally delivered key. Timing ends at `makeKeyAndOrderFront` returning and at implicit nonanimated transaction completion (a commit proxy). Neither proves on-screen presentation latency; M6 supplies that harness. Real hotkey/IME/focus/Spaces checks are [supervised and unvalidated](../verification/runs/2026-11-18T164001Z-m2-supervised.md).

## Verification history

- [M2 automated verification](../verification/runs/2026-11-18T164000Z-m2.md).

## M3 integration

M3 waits for the first complete local-source attempt, including explicit failure/waiting outcomes, before resolving a pending local query; a cached file snapshot satisfies readiness before replay. Explicit web queries bypass local readiness. File and discovered-app rows carry typed targets from the captured search data.

- [M3 verification](../verification/runs/2026-11-18T181500Z-m3.md).
