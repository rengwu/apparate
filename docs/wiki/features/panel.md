---
title: Launcher panel
section: Features
updated: 2026-11-24
---
# Launcher panel

**FEAT-panel.** A keyboard-first launcher with inline matches and up to nine visible rows and all 50 results reachable. Basis: [M4 guide and accepted amendments](../build/m4-launcher-panel.md#pushback-and-answers), DEC-023/024 and DEC-016/019. [M4 verification](../verification/runs/2026-11-18T200340Z-m4.md) records the implementation, renderer comparison and remaining supervised checks.

## Entry points and prerequisites

`PanelController` owns a retained nonactivating `NSPanel`, constructed and rendered once at launch without showing or taking focus. Production uses Carbon with `kEventHotKeyExclusive`. `HotKeyRegistration` installs a replacement before removing the old key; failed replacement keeps the working key and reports an error. An unchanged keycode/modifier pair does nothing.

The production default is Command-Space. Every unattended app launch must use [the isolated driver](../verification/setup.md#isolated-app-profiles), which pre-seeds a temporary config and uses fake effects, registration and protected-folder probes. All automated profiles now prohibit activation before window construction and render without ordering a window. `--render` replaces the old visible meaning of `--show`; the latter remains an alias.

## Expected outcomes

The [UI follow-up](../build/ui-follow-up.md) (DEC-052) keeps the panel 640 points wide and opens a 41-point search strip without a divider. Results expand downward around a fixed top edge. Inline and Right use 28-point rows: 110 points for one row, 166 for three, and 334 for nine. Below uses 40-point rows: 122, 202 and 442 points. Searching and scoped no-results use one status row at 82 points without an action footer; a web result gets the normal footer. Clearing returns immediately to the strip. Accepted row layout and a necessary window resize share a nonanimated transaction; unchanged geometry skips setFrame entirely, but proof of no blank/clipped intermediate screen frame remains part of M6. Search uses 16-point text. Rows use 20-point icons, a 9-point gap, 13-point titles with semibold matched graphemes, dim locations and right-aligned 11-point ⌘1–9 hints. Selection uses the system accent color with 6-point corners. Location in results (DEC-053) offers Inline (default), Right and Below in Settings → General. Inline uses a 10-point gap and 12-point text; Right uses 12-point text aligned 9 points before the hint, at least 16 points from the title. Both give the title priority, middle-truncate location text and drop it when less than 32 points remain; titles tail-truncate only after the location is gone. Below puts an 11-point location under the title and centers command titles when the location is empty. No em dash is inserted. App/file/folder locations are full home-abbreviated parent paths derived from stored targets, without disk reads. Settings retain their pane label.

The panel follows system appearance and uses popover vibrancy; Reduce Transparency selects a plain system background. Search syntax is single-line and is not rewritten by automatic quote/dash replacement, spelling correction, text replacement or Writing Tools. Native file icons load off the matching path and are cached; fixture runs use generic cached symbols and never resolve fixture paths through Workspace.

A user-initiated, latency-critical activity is held only while the panel is showing and released on hide; hidden startup warm-up does not hold it. The search field disables completion and prose editing services.

Text appears immediately. Complete result sets arrive asynchronously; no production main-thread wait is added. Query revisions invalidate old work synchronously. Usage is read once per showing and reused for every edit, config change and source update; editing does not read SQLite. A successful primary open or completed drop refreshes usage on the next showing, or explicitly if the user already reopened it. Selection follows its ID across results, falling back to the first row. Pending edits retain the previous complete presentation and its height. A location-layout change reflows that complete presentation immediately, without changing the query revision, selection, viewport, composition or pending action. Other config changes retain their restart behavior. Before any complete presentation, a nonempty pending query shows Searching…. Scrolling still updates the displayed viewport and its numbered shortcuts while a query is pending.

| Input/state | Outcome |
| --- | --- |
| ↑ / ↓ | Move through all results, without wrapping; scroll only far enough to reveal selection. |
| Wheel | Scroll whole rows, clamped to the result count; update hints and click targets. |
| → | Complete a current accepted folder when the caret is at the UTF-16 end, with no selection or marked text. Uses the same home-abbreviated path and native undo as Tab. All other states and modified arrows retain AppKit editing behavior; no completion in Open With. |
| Tab / ⇧Tab | Tab completes the current accepted selection in any search: folder → home-abbreviated path plus `/`; file → home-abbreviated path; app, setting or command → displayed name with its scope prefix kept. Paths drop the prefix. Web, identical text, pending results, no selection, unreconciled editor text and marked text do nothing. Shift-Tab does nothing. Both stay in the field; a completion places the caret at the end and native undo/redo updates the field and results. |
| Open With key (default ⇧Return) | On a current accepted file/folder, enter Open With; pending, marked, repeat and other-kind triggers do nothing. |
| Return / ⌘Return / ⌘C | Open / reveal / copy the selected filesystem path. During a pending query, queue the selected-row operation for that revision. |
| Click | Press selects the row. Release opens the pressed ID unless a drag started. During a pending search, selection stays fixed and release queues the pressed ID, which must survive in the new results. While text is marked, both selection and activation stay suppressed. |
| ⌘1–9 | Activate the ID of the corresponding visible row. A pending open requires that ID to survive in the new results. |
| Edit / navigation / scroll / composition / hide / source or config change | Cancel queued actions and Restart arming. |
| Restart | First Return, click or ⌘N arms it. Only a fresh nonrepeat Return confirms. The row says “Press Return again”; the footer says “↩ Confirm Restart   esc Cancel”. |
| Esc | Input method first; otherwise disarm Restart without clearing the query, then clear text, then close. |
| ⌘Q | Quit, including while text is marked. |
| Empty query | Immediately clear rows, selection and footer. |
| Nonempty query before initial catalog readiness | “Searching…” while the local query is pending; no premature web fallback. Completed explicit web queries bypass local readiness and show their action footer. |
| No local matches | Unprefixed queries get web fallback; scoped queries show “No results”. |
| New showing | Empty query, no selection and viewport at the top. |

While text is marked, the input method owns Return, arrows, Esc and Tab. Any Tab or Shift-Tab command that reaches the panel delegate is consumed without changing the text or focus. It cannot trigger an action or arm Restart. Real input-method candidate interaction is Untested and excluded from the session by DEC-050; release notes must retain that limitation.

The result container exposes all up-to-50 accessibility rows, a separate visible subset, full title/location/kind/position, selected state and a press action. Elements keep identity by item ID. Selecting an offscreen element brings it into view; press validates its current ID. Selection-change notifications are posted only when the selection changes and the real panel is visible. Hidden checks use a notification counter and inspect the owned tree, without synthesizing VoiceOver speech.

## Drag results out

Move a pressed file, folder or app past the system drag distance to lift its icon. An Open With row supplies the chosen app’s file URL. Settings, commands and web rows open on release even when the pointer moves.

Apparate supplies one file URL. **Like Finder**, the default, offers the destination copy, move, link and generic operations. **Never move** offers only copy and link. The General setting applies immediately. A drag within Apparate offers no operation. Releasing the drag inside the panel before the pointer crosses its edge preserves the query and selection. Once the pointer leaves the panel, the panel hides and the destination handles the drop. A completed drop counts as one use of the dragged row for ranking, including an app dragged from Open With. That app gains plain usage while the original file type keeps its remembered handler. Cancelling records nothing. The ID captured at drag start survives dismissal. [Round 22 decisions](../decisions.md#round-22-2026-11-24).

## Open With

DEC-057 adds a panel-local Open With key, default ⇧Return and configurable in Settings → General. It applies to current accepted file/folder rows. The field clears to `Open notes.md with…` and the list contains the last chosen app for that content type, the current default, then other apps macOS claims can open the item in A–Z order. Last used wins the label when it is also default. A valid remembered app remains first even when it is not a claimed handler. Deleted remembered apps are omitted.

Typing filters those groups with the usual name matcher and brings in other catalog apps after the claimed group. Text is literal app-name input: no scope prefix, path parsing or web fallback. URLs deduplicate the groups; at most 50 results are shown, all reachable with the existing row navigation. Only remembered/default rows have location labels. Discovery and matching run on workers and obsolete generations cannot publish. Lookup honors saved protected-folder observations before file/type metadata, with canonical path checks; it adds no watcher, permission probe or file-content read.

Return, click and ⌘1–9 open the original item with the chosen app and hide the panel. See [actions](actions.md) for failure and history rules. Esc goes directly Back even with a nonempty app filter, restoring the previous query, selection and viewport. If sources/config/access changed, the restored query is revalidated and selection survives by ID when possible. New edits/navigation cancel deferred position restoration. Tab/backtab, ⌘Return and ⌘C are consumed no-ops in this mode. Composition gets Esc first; the configured trigger during composition does nothing. Quit and Settings remain available. Hiding or a new showing discards the mode. Empty discovery shows No applications; discovery errors use the existing user-action alert route.

## Automated verification recipe

Run the full Core harness and signed build in [setup](../verification/setup.md). Then:

```sh
python3 Tests/smoke-app.py --panel-check functional --output /private/tmp/apparate-m4-functional
python3 Tests/smoke-app.py --panel-check measure --count 20000 --output /private/tmp/apparate-m4-20k
python3 Tests/smoke-app.py --panel-check measure --count 200000 --output /private/tmp/apparate-m4-200k
```

The functional profile injects text directly into its hidden owned field editor, checks native command routing/marked-text guards, row geometry, scrolling, ID-based activation, Restart/Esc/quit, pending presentation and accessibility identity. Inspect light/dark JPEGs for every state and the long-title, long-location, combined and Unicode fixtures. All actions are recorded by fakes. Receipts must report zero native effects, zero protected-folder probes, no visible/key/main window, and no active app. The measurement profile uses the real M3 compact index with deterministic synthetic input and separate ordinary-update and explicit-raster phases. It includes overlapping input and preserves every completed, superseded and timed-out event.

## Supervised recipes — Untested

These require the user’s explicit supervised slot. DEC-050 excludes real IME, VoiceOver, Lock, Sleep and Restart from that session; they remain Untested and must appear in release notes. Other [pending M2 native checks](../verification/runs/2026-11-18T164001Z-m2-supervised.md) remain Untested and are waived for 0.1.0 by [DEC-061](../decisions.md#round-13-2026-11-19). Use an agreed safe config and synthetic fixture folder, restore the user's config afterward, and do not approve real Restart/Lock/Sleep merely to test panel presentation.

1. **Hotkey, focus and first show:** with another app focused, launch the agreed build, press the configured global hotkey, type a fixture query, and verify that the search field receives text. Record the first real show after launch separately from later shows. Esc clears, then closes; focus returns to the previous app. A click in another app closes the panel. M6's presentation harness must qualify actual latency; a stopwatch or hidden bitmap does not.
2. **Spaces, full-screen and monitors:** from each agreed Space and a full-screen app, invoke the launcher. Repeat with keyboard focus on each display. Verify it appears on the expected screen, does not switch Spaces, keeps the search strip at the previous full-size panel’s top position, and grows downward without moving the field.
3. **Appearance:** inspect light/dark mode, the user's accent color, Reduce Transparency, Retina/non-Retina or mixed-scale displays if available. Check corners, symbol/file icons, contrast, separators, truncation and full paths. Compare vibrancy and plain background only in an explicitly authorized on-screen window under DEC-049; hidden captures do not measure WindowServer composition.
4. **Keyboard and mouse:** reach row 50 with arrows, scroll back by wheel, invoke ⌘1 and ⌘9, and click after scrolling. Confirm hints identify the visible rows. Type quickly while a query is pending and activate a known ID; a removed result must not open a replacement. Use fixture files and the M2 action recipes for actual opens/reveal/copy.
5. **IME — excluded by DEC-050; Untested, future recipe only:** enable the user's chosen input method. Enter marked text and navigate its candidates with arrows/Return/Esc; no result opens or moves behind it. Commit text and verify normal navigation resumes. Confirm ⌘Q can quit during composition, then relaunch only within the supervised slot.
6. **VoiceOver — excluded by DEC-050; Untested, future recipe only:** enable VoiceOver with the user. Navigate the result container and verify full labels, kind, position and selected state. Move beyond row 9, activate a fixture file, and verify the selected row is revealed. Check that ordinary selection changes are announced once and unrelated rerenders do not create repeated announcements.
7. **Restart presentation:** arm Restart with Return, click and ⌘N separately. Verify repeat keys/clicks/number shortcuts do not confirm. Esc must first disarm while retaining the query. Stop at cancellation; actual acceptance is excluded by DEC-050 and remains Untested.
8. **Finder and Desktop.** Use a disposable PDF and a same-disk Finder folder. Verify the default drop moves the file and an Option-drop copies it. Drop on the Desktop behind the panel’s original position and record the actual operation.
9. **Other destinations.** Drag a disposable file into a Mail draft, a browser upload field, a chat draft and Terminal. Check the attachment, selected file or inserted path. Drag an app onto the Dock and a folder onto the Finder sidebar. Remove the test shortcuts afterward.
10. **Release inside.** Start a drag and release over the panel without crossing its edge. Verify the query and selection persist. A subsequent plain click opens the pressed item.

11. **Never move.** Drag a disposable file into a same-disk Finder folder and verify the source remains. Repeat with ⌘⌥ and verify an alias. Check that Mail, a browser upload field, Terminal and the Dock still accept a supported item. Record any refusal.
12. **Drop usage.** With comparable results in a fixture folder, drop the same file successfully twice, then search again. Compare its ranking with two successful opens from the same starting history.

## Coverage and limitations

Hidden activation guards, model/command behavior, layout, owned accessibility state and fixture render inspection are automated evidence. They do not establish real global-key delivery, focus transfer, screen presentation, composited vibrancy, Spaces or spoken VoiceOver behavior. The M4 performance record reports these separately as Untested; it does not claim the DEC-008 end-to-end budgets have passed.

The [post-review investigation](../verification/runs/2026-11-18T200340Z-m4.md#post-review-fixes) measures input, worker queue/search, main delivery, acceptance and view stages. Both delivery modes preserve generation guards. The requested hidden-proxy targets remain missed; activity and delivery-hop comparisons do not establish App Nap as the cause.

## Verification history

- [Drag policy and completed-drop usage](../verification/runs/2026-11-24T093455Z-drag-policy.md).

- [Drag results out](../verification/runs/2026-11-24T074838Z-drag-out.md) covers press, release, file URLs, operation masks and panel dismissal.

- [M2 automated verification](../verification/runs/2026-11-18T164000Z-m2.md).
- [M3 integration](../verification/runs/2026-11-18T181500Z-m3.md): initial local-source readiness, compact files and typed discovered-app targets.
- [M4 verification](../verification/runs/2026-11-18T200340Z-m4.md): final panel, renderer comparison, native fixture checks and supervised recipes.

**2026-11-19 gate update:** Claude moved the pending native checks to the M7 release gate in the [M5 guide](../build/m5-settings-menu-first-run.md). Their recorded outcomes remain unchanged.

## M5 Settings route

⌘, hides the launcher, releases its foreground activity and opens the retained [Settings window](settings.md). The hidden native fixture checks this route; global key delivery and focus remain supervised. [M5 verification](../verification/runs/2026-11-18T212428Z-m5.md).


## M6 hidden instrumentation

[Hidden-stage verification](../verification/runs/2026-11-18T225138Z-m6.md) uses independently scheduled owned field-editor inputs and preserves all event outcomes. Its run/show/revision/result-digest marker is drawn in the result view’s own draw path, with full invalidation, and is absent in normal operation. Native bitmap round trips cover empty, repeated, web and no-result states after timing. The external observer and bounded decoder are self-tested without capture. On-screen integration and calibration remain Untested; visible runs require DEC-049’s explicit open window. NSSearchField, its public service-disable flags, input methods and accessibility remain intact.

- [UI follow-up verification](../verification/runs/2026-11-19T064952Z-ui.md) — strip/1/3/9 geometry, preserved pending height, immediate clear, and compact same-draw marker decoded from owned bitmaps. Observer records each frame’s content geometry and scale; live resizing/composition remains Untested under DEC-049.

- [Six UI review fixes](../verification/runs/2026-11-19T070456Z-ui-review.md) — centered titles, in-card Spotlight action, compact centered prefixes, integrated native depth stepper, no redundant panel frame calls and aligned magnifier; hidden checks/renders passed, live appearance pending.

- [Live centering follow-up](../verification/runs/2026-11-19T083754Z-panel-centering.md) — search text and magnifier centered in the 40-point search row, footer text centered in its 28-point band; placeholder, typed and marked text measured in hidden native renders.

- [Result-location setting verification](../verification/runs/2026-11-19T085025Z-row-location.md) — all three render layouts, 28/40-point geometry, live and pending reflow, stable AX identity, clicks and numbered actions after resize/scroll.

- [Inline-default follow-up](../verification/runs/2026-11-19T090422Z-inline-default.md) — DEC-053 round 15 changes the missing-key/new-config default to Inline; explicit saved choices remain intact.

[Section 5 verification](../verification/runs/2026-11-19T095817Z-path-folders.md) adds leading-path navigation before catalog readiness, plain error/access messages, hidden native Tab/undo and filesystem action routing, with light/dark path-state renders. Physical keyboard/IME delivery and direct-path latency remain separate from hidden checks.


[Section 6 verification](../verification/runs/2026-11-19T115135Z-dot-names.md) adds native hidden checks and light/dark renders for indexed dot names, ordinary-query exclusion, Settings-prefix compatibility, internal dot paths and direct navigation. Folder symbols and usual name highlighting apply to these rows.


[Section 7 verification](../verification/runs/2026-11-19T121020Z-tab-completion.md) checks completion from ordinary and scoped results, selected-folder navigation, Unicode file paths, prefix preservation, consumed no-ops and native undo/redo. Hidden commands do not establish physical key-event history grouping or real input-method behavior.


[Open With verification](../verification/runs/2026-11-19T123000Z-open-with.md) — DEC-057 shortcut, app groups, Back, success-only history and hidden native checks.


[Section 9 verification](../verification/runs/2026-11-20T010038Z-right-folder.md) checks plain Right folder completion, scoped/direct paths, Unicode caret offsets, native undo/redo and actual caret/selection changes in fallthrough cases. The footer is unchanged. Physical keyboard/IME delivery and real-event undo grouping remain Untested.


## Below-layout icon size

Below rows use a 32-point icon at x = 9, centered with four points above and below in the 40-point row. Titles and locations start at x = 50; their vertical positions and the hint column stay unchanged. Rows without a location use the same icon column and vertically centered title. Inline and Right retain 20-point icons and x = 38 text.

The icon loader keys both cached images and pending file requests by size. File/app/setting artwork is rasterized away from the main thread at 64 pixels for Below and 40 pixels for Inline/Right; only PNG bytes cross executors. Symbols retain vector rendering at the requested size. A size change immediately clears the row's old image and requests the new size, including while results are pending. Late callbacks may populate their size-specific cache but cannot install an image of the wrong size. A cold switch can briefly omit an icon while it loads; it never stretches the smaller cached image into the larger frame. The shared cache keeps its existing 128-entry count limit.

[Section 11 verification](../verification/runs/2026-11-20T111919Z-below-icons.md) records size-switch races, raster dimensions, mixed row renders and unchanged Inline/Right hashes. The completed 20k Below comparison measures 49.14 MiB after preferences: above the 40 MiB target and 47 MiB comparison, below the 60 MiB ceiling; the report distinguishes matched-prior and historical differences.
