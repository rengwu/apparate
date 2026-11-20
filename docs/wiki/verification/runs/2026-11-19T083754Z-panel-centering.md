---
title: Panel optical centering
section: Verification
updated: 2026-11-19
result: Untested
status: Hidden checks passed; live recheck pending
---
# Panel optical centering

Run `2026-11-19T083754Z-panel-centering` addresses the user's live feedback on [FEAT-panel](../../features/panel.md), including Claude's subsequent footer request. The search field moves down **2 pt**, the magnifier down **1 pt**, and the footer down **3 pt** from the preceding six-fix build. The 41-point strip and all result heights stay unchanged. Native field-editor layout, selection, marked text and command handling remain intact; this changes view placement only. Result-row layout is not changed by this follow-up.

The reference is **cap-height midpoint**, centered at 20 pt from the top of the 40-point search row, and at 14 pt from the bottom of the 28-point footer band. This avoids centering the padded text-field frame. Native field-editor baseline/font metrics establish text placement; independent bitmap measurements check the actual glyphs and magnifier. Overall Untested retains the pending live appearance check and existing IME/screen-composition exclusions.

## Measurements

| Element | Target and observed center | Result |
| --- | --- | --- |
| Search placeholder / typed text | Native cap midpoint **20.363 pt from top**, at heights 41/110/166/334; error +0.363 pt. Rendered placeholder ink center **20.25 pt**, typed `result` **20.00 pt**. | Passed |
| Marked `に` | Native fallback-font cap midpoint **20.137 pt** in both the strip and nine-result panel. Marked highlight/text were inspected in light and dark; native marked-command guards pass. | Passed |
| Magnifier | View center 20 pt; rendered symbol ink center **19.75 pt** in both appearances and all four heights. | Passed |
| Footer | Native cap midpoint **13.875 pt from bottom**, target 14. Rendered capital O in Open is within **0–0.25 pt** of target at one, three and nine rows. The previous native midpoint was 16.875 pt: the measured correction is downward. | Passed |
| Searching… / No results | Native midpoint **61.420 pt from top**, target **61.5 pt** in the status band below the divider. Rendered first capital is within 0.25 pt of target. No adjustment needed. | Passed |
| ⌘1–9 against titles | Actual hint ink centers differ from each corresponding title's capital R by **0–0.25 pt**, in light/dark selected and unselected rows. Existing title/hint ink sits 0.75–1 pt below the geometric row center; they remain aligned with each other. No row change made. | Passed |

The [release receipt](../../evidence/2026-11-19T083754Z-panel-centering/panel/receipt.json) records native font/layout metrics and asserts a maximum 0.5-point cap-center error for search/footer/status. [Pixel measurements](../../evidence/2026-11-19T083754Z-panel-centering/pixel-measure.json) come from [this script](../../evidence/2026-11-19T083754Z-panel-centering/pixel-measure.txt): 2× app-owned bitmaps, 0.15 RGB contrast threshold, fixed glyph regions excluding descenders when measuring capitals. Ink edges are raster-quantized; they are a separate observation from continuous font metrics.

## Verification and identity

The full hidden panel functional profile passed in [debug](../../evidence/2026-11-19T083754Z-panel-centering/debug-panel3.json) and release. It checks native editing/command routing, marked-command guards, fixed-top strip/1/3/9 heights, immediate clear, previous-complete pending presentation, marker decoding, selection/scroll/AX identity and zero redundant window-frame calls for three same-height searches. Both final runs produced zero stderr bytes. Earlier debug receipts retain the search-only measurements and the footer's pre-correction position.

Only `PanelController.swift` and the panel verification harness changed after the preceding UI review. Core correctness, Settings behavior and memory measurements were not rerun for this bounded geometry change; their earlier evidence retains its original fingerprint. The [debug build](../../evidence/2026-11-19T083754Z-panel-centering/debug-build3.log) and [release build](../../evidence/2026-11-19T083754Z-panel-centering/release-build.log) succeeded with the existing Command Line Tools linker search-path warnings.

Base `87d171c72d2f635b4d3f719e1194d2311d25b509`, dirty UI working tree. Release SHA-256 `995515aad116461374208eccbb15d2a42d7a99de67ac0609ea23bd9f1dad4e74`. [Build identity](../../evidence/2026-11-19T083754Z-panel-centering/build-identity.json), [source manifest](../../evidence/2026-11-19T083754Z-panel-centering/source-manifest.json), [assembly recipe](../../evidence/2026-11-19T083754Z-panel-centering/assembly.txt) and [signature check](../../evidence/2026-11-19T083754Z-panel-centering/assembly.log).

SwiftPM used `/private/tmp/apparate-ui-build-20261119`. The new immutable bundle `build/review/2026-11-19-panel-centering/Apparate.app` was assembled from isolated release output and repository resources. `build.sh` was not run; `build/Apparate.app` and Claude's session folder were not accessed. Explicit `--binary`, disposable test homes, prohibited activation, hidden windows and fake effects were used throughout. Receipts confirm no native actions/hotkeys/protected-folder probes and successful owned-process/home cleanup. No commit or push.

## Renders

These are app-owned hidden native content bitmaps, not WindowServer captures. The affected search, footer and status states were visually inspected. A live caret, composed vibrancy, focus behavior and real input-method candidate interaction remain Untested; the marked fixture establishes owned editor behavior only.

| State | Light | Dark |
| --- | --- | --- |
| Placeholder strip | [Light](../../evidence/2026-11-19T083754Z-panel-centering/panel/search-0-light.png) | [Dark](../../evidence/2026-11-19T083754Z-panel-centering/panel/search-0-dark.png) |
| One result + footer | [Light](../../evidence/2026-11-19T083754Z-panel-centering/panel/search-1-light.png) | [Dark](../../evidence/2026-11-19T083754Z-panel-centering/panel/search-1-dark.png) |
| Three results | [Light](../../evidence/2026-11-19T083754Z-panel-centering/panel/search-3-light.png) | [Dark](../../evidence/2026-11-19T083754Z-panel-centering/panel/search-3-dark.png) |
| Nine results | [Light](../../evidence/2026-11-19T083754Z-panel-centering/panel/search-9-light.png) | [Dark](../../evidence/2026-11-19T083754Z-panel-centering/panel/search-9-dark.png) |
| Marked text, strip | [Light](../../evidence/2026-11-19T083754Z-panel-centering/panel/search-marked-strip-light.png) | [Dark](../../evidence/2026-11-19T083754Z-panel-centering/panel/search-marked-strip-dark.png) |
| Marked text, expanded | [Light](../../evidence/2026-11-19T083754Z-panel-centering/panel/search-marked-light.png) | [Dark](../../evidence/2026-11-19T083754Z-panel-centering/panel/search-marked-dark.png) |
| Searching… | [Light](../../evidence/2026-11-19T083754Z-panel-centering/panel/loading-light.jpg) | [Dark](../../evidence/2026-11-19T083754Z-panel-centering/panel/loading-dark.jpg) |
| No results | [Light](../../evidence/2026-11-19T083754Z-panel-centering/panel/no-results-light.jpg) | [Dark](../../evidence/2026-11-19T083754Z-panel-centering/panel/no-results-dark.jpg) |

## Reproduce

```sh
python3 Tests/smoke-app.py --binary build/review/2026-11-19-panel-centering/Apparate.app/Contents/MacOS/Apparate --panel-check functional --output /private/tmp/apparate-centering-recheck
swift - /private/tmp/apparate-centering-recheck < docs/wiki/evidence/2026-11-19T083754Z-panel-centering/pixel-measure.txt
```

Use a fresh output directory. Claude will rebuild the session app for the user's live recheck.
