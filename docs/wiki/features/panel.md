---
title: Launcher panel
section: Features
updated: 2026-11-19
---
# Launcher panel

**FEAT-panel.** A fixed, keyboard-first launcher with inline matches, nine visible rows and all 50 results reachable. Basis: [M4 guide and accepted amendments](../build/m4-launcher-panel.md#pushback-and-answers), DEC-023/024 and DEC-016/019. [M4 verification](../verification/runs/2026-11-18T200340Z-m4.md) records the implementation, renderer comparison and remaining supervised checks.

## Entry points and prerequisites

`PanelController` owns a retained nonactivating `NSPanel`, constructed and rendered once at launch without showing or taking focus. Production uses Carbon with `kEventHotKeyExclusive`. `HotKeyRegistration` installs a replacement before removing the old key; failed replacement keeps the working key and reports an error. An unchanged keycode/modifier pair does nothing.

The production default is Command-Space. Every unattended app launch must use [the isolated driver](../verification/setup.md#isolated-app-profiles), which pre-seeds a temporary config and uses fake effects, registration and protected-folder probes. All automated profiles now prohibit activation before window construction and render without ordering a window. `--render` replaces the old visible meaning of `--show`; the latter remains an alias.

## Expected outcomes

The panel is 640 × 334 points: 41 points for search including its divider, 264 for nine 28-point rows and two 6-point insets, and 29 for the footer including its divider. Search uses 16-point text. Rows use 20-point icons, a 9-point gap, 13-point titles with semibold matched graphemes, inline dim locations and right-aligned 11-point ⌘1–9 hints. Selection uses the system accent color with 6-point corners. Locations truncate in the middle; if too little useful space remains, the location and em dash disappear before the title truncates at its tail. App/file/folder locations are full home-abbreviated parent paths derived from stored targets, without disk reads. Settings retain their pane label.

The panel follows system appearance and uses popover vibrancy; Reduce Transparency selects a plain system background. Search syntax is single-line and is not rewritten by automatic quote/dash replacement, spelling correction, text replacement or Writing Tools. Native file icons load off the matching path and are cached; fixture runs use generic cached symbols and never resolve fixture paths through Workspace.

A user-initiated, latency-critical activity is held only while the panel is showing and released on hide; hidden startup warm-up does not hold it. The search field disables completion and prose editing services.

Text appears immediately. Complete result sets arrive asynchronously; no production main-thread wait is added. Query revisions invalidate old work synchronously. Usage is read once per showing and reused for every edit, config change and source update; editing does not read SQLite. A successful primary open refreshes usage on the next showing, or explicitly if the user already reopened it. Selection follows its ID across results, falling back to the first row. Pending edits retain the previous presentation. Scrolling still updates the displayed viewport and its numbered shortcuts while a query is pending.

| Input/state | Outcome |
| --- | --- |
| ↑ / ↓ | Move through all results, without wrapping; scroll only far enough to reveal selection. |
| Wheel | Scroll whole rows, clamped to the result count; update hints and click targets. |
| Return / ⌘Return / ⌘C | Open / reveal / copy the selected filesystem path. During a pending query, queue the selected-row operation for that revision. |
| Click / ⌘1–9 | Activate the displayed item's ID. If pending, it must survive in the new results; never substitute the item now occupying its old ordinal. |
| Edit / navigation / scroll / composition / hide / source or config change | Cancel queued actions and Restart arming. |
| Restart | First Return, click or ⌘N arms it. Only a fresh nonrepeat Return confirms. The row says “Press Return again”; the footer says “↩ Confirm Restart   esc Cancel”. |
| Esc | Input method first; otherwise disarm Restart without clearing the query, then clear text, then close. |
| ⌘Q | Quit, including while text is marked. |
| Empty query | Immediately clear rows, selection and footer. |
| Nonempty query before initial catalog readiness | “Searching…” while the local query is pending; no premature web fallback. Completed explicit web queries bypass local readiness and show their action footer. |
| No local matches | Unprefixed queries get web fallback; scoped queries show “No results”. |
| New showing | Empty query, no selection and viewport at the top. |

While text is marked, the input method owns Return, arrows and Esc. It cannot trigger an action or arm Restart. Real input-method candidate interaction remains a supervised check.

The result container exposes all up-to-50 accessibility rows, a separate visible subset, full title/location/kind/position, selected state and a press action. Elements keep identity by item ID. Selecting an offscreen element brings it into view; press validates its current ID. Selection-change notifications are posted only when the selection changes and the real panel is visible. Hidden checks use a notification counter and inspect the owned tree, without synthesizing VoiceOver speech.

## Automated verification recipe

Run the full Core harness and signed build in [setup](../verification/setup.md). Then:

```sh
python3 Tests/smoke-app.py --panel-check functional --output /private/tmp/apparate-m4-functional
python3 Tests/smoke-app.py --panel-check measure --count 20000 --output /private/tmp/apparate-m4-20k
python3 Tests/smoke-app.py --panel-check measure --count 200000 --output /private/tmp/apparate-m4-200k
```

The functional profile injects text directly into its hidden owned field editor, checks native command routing/marked-text guards, row geometry, scrolling, ID-based activation, Restart/Esc/quit, pending presentation and accessibility identity. Inspect light/dark PNGs for every state and the long-title, long-location, combined and Unicode fixtures. All actions are recorded by fakes. Receipts must report zero native effects, zero protected-folder probes, no visible/key/main window, and no active app. The measurement profile uses the real M3 compact index with deterministic synthetic input and separate ordinary-update and explicit-raster phases. It includes overlapping input and preserves every completed, superseded and timed-out event.

## Supervised recipes — Untested

These require the user's explicit supervised slot. They are not part of the automated driver; the [pending M2 native checks](../verification/runs/2026-11-18T164001Z-m2-supervised.md) still apply before M7 release. Use an agreed safe config and synthetic fixture folder, restore the user's config afterward, and do not approve real Restart/Lock/Sleep merely to test panel presentation.

1. **Hotkey, focus and first show:** with another app focused, launch the agreed build, press the configured global hotkey, type a fixture query, and verify that the search field receives text. Record the first real show after launch separately from later shows. Esc clears, then closes; focus returns to the previous app. A click in another app closes the panel. M6's presentation harness must qualify actual latency; a stopwatch or hidden bitmap does not.
2. **Spaces, full-screen and monitors:** from each agreed Space and a full-screen app, invoke the launcher. Repeat with keyboard focus on each display. Verify it appears on the expected screen, does not switch Spaces, is centered in that screen's visible frame, and keeps its fixed size.
3. **Appearance:** inspect light/dark mode, the user's accent color, Reduce Transparency, Retina/non-Retina or mixed-scale displays if available. Check corners, symbol/file icons, contrast, separators, truncation and full paths. Compare vibrancy and plain background only in an explicitly agreed supervised build; hidden captures do not measure WindowServer composition.
4. **Keyboard and mouse:** reach row 50 with arrows, scroll back by wheel, invoke ⌘1 and ⌘9, and click after scrolling. Confirm hints identify the visible rows. Type quickly while a query is pending and activate a known ID; a removed result must not open a replacement. Use fixture files and the M2 action recipes for actual opens/reveal/copy.
5. **IME:** enable the user's chosen input method. Enter marked text and navigate its candidates with arrows/Return/Esc; no result opens or moves behind it. Commit text and verify normal navigation resumes. Confirm ⌘Q can quit during composition, then relaunch only within the supervised slot.
6. **VoiceOver:** enable VoiceOver with the user. Navigate the result container and verify full labels, kind, position and selected state. Move beyond row 9, activate a fixture file, and verify the selected row is revealed. Check that ordinary selection changes are announced once and unrelated rerenders do not create repeated announcements.
7. **Restart presentation:** arm Restart with Return, click and ⌘N separately. Verify repeat keys/clicks/number shortcuts do not confirm. Esc must first disarm while retaining the query. Stop at cancellation; actual acceptance remains the separately authorized M2 destructive-action recipe.

## Coverage and limitations

Hidden activation guards, model/command behavior, layout, owned accessibility state and fixture render inspection are automated evidence. They do not establish real global-key delivery, focus transfer, screen presentation, composited vibrancy, Spaces or spoken VoiceOver behavior. The M4 performance record reports these separately as Untested; it does not claim the DEC-008 end-to-end budgets have passed.

The [post-review investigation](../verification/runs/2026-11-18T200340Z-m4.md#post-review-fixes) measures input, worker queue/search, main delivery, acceptance and view stages. Both delivery modes preserve generation guards. The requested hidden-proxy targets remain missed; activity and delivery-hop comparisons do not establish App Nap as the cause.

## Verification history

- [M2 automated verification](../verification/runs/2026-11-18T164000Z-m2.md).
- [M3 integration](../verification/runs/2026-11-18T181500Z-m3.md): initial local-source readiness, compact files and typed discovered-app targets.
- [M4 verification](../verification/runs/2026-11-18T200340Z-m4.md): final panel, renderer comparison, native fixture checks and supervised recipes.

**2026-11-19 gate update:** Claude moved the pending native checks to the M7 release gate in the [M5 guide](../build/m5-settings-menu-first-run.md). Their recorded outcomes remain unchanged.

## M5 Settings route

⌘, hides the launcher, releases its foreground activity and opens the retained [Settings window](settings.md). The hidden native fixture checks this route; global key delivery and focus remain supervised. [M5 verification](../verification/runs/2026-11-18T212428Z-m5.md).
