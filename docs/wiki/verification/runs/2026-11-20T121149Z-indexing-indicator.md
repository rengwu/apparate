---
title: Single indexing indicator
section: Verification
updated: 2026-11-20
result: Untested
status: Section 14 automated checks passed; visible animation and spoken VoiceOver remain untested
---
# Single indexing indicator

[UI section 14](../../build/ui-follow-up.md#14-one-indexing-indicator-on-the-folders-tab) removes the per-folder progress line and places a small native spinner with secondary **Indexing…** beside **Add Folders…**. [Settings](../../features/settings.md) records the behavior; [file index](../../features/file-index.md) records retained root statuses during retries.

## Implementation

The indicator follows the same aggregate indexing state that disables Rebuild. Its slot stays in the horizontal layout while hidden, starting 8 points after Add Folders; Allow Access stays at the trailing edge. The button fixes the action row height. No delayed show, fade, minimum duration or polling is added. The native spinner is small, spinning and indeterminate, with accessibility label **Indexing**. The text is excluded from accessibility to avoid a duplicate announcement. Visible animation starts only on the visible Folders tab and stops on tab change or close. Hidden fixtures render the stopped native glyph without starting animation.

Indexed and indexing folder rows both omit the second line. Their display-status cache is identical, so progress-only updates retain the same native folder controls. Denied, Not found, Unavailable and Waiting for access keep their existing descriptions. FileIndexController previously replaced old actionable statuses with indexing on retry; it now retains them until a new result arrives, avoiding an error-row collapse at the start. A successful recovery can still remove a now-obsolete error description. Aggregate progress remains separate. The Index card is unchanged, including its existing count and indexing text.

## Results

| Scenario | Observed | Result |
| --- | --- | --- |
| Core suites | 134/134 debug and release | Passed |
| Root-status retry | Denied, missing, unavailable and waiting states survive retry; ready roots show progress; repeated failure retains statuses; recovery publishes indexed | Passed |
| Native Settings profiles | Debug and signed release pass all existing checks plus the indicator fixture | Passed |
| Native panel regression | Signed release profile passes; all 184 raw panel renders match section 13 | Passed |
| Indexed ↔ indexing | All folder controls retain identity; folder/card/button/switch/content frames are exactly equal in both directions | Passed |
| Mixed errors | One indexing root alongside denied, missing and unavailable roots retains all descriptions and every measured frame | Passed |
| Waiting for access | Waiting description and frames survive the indexing transition | Passed |
| Both Skip switches | Four native actions, on/off for each switch; fixture callback publishes indexing immediately; Rebuild and indicator agree; frames stay equal | Passed |
| Native indicator | Small spinning indeterminate control, 8-point gap, center Y equal to button, accessibility label and hidden state checked | Passed |
| Visible animation / spoken VoiceOver | No visible window or screen-reader session used | Untested |

[Debug suite](../../evidence/2026-11-20T121149Z-indexing-indicator/debug-tests.log), [release suite](../../evidence/2026-11-20T121149Z-indexing-indicator/release-tests.log), [debug Settings receipt](../../evidence/2026-11-20T121149Z-indexing-indicator/debug-settings/receipt.json), [signed Settings receipt](../../evidence/2026-11-20T121149Z-indexing-indicator/settings/receipt.json), [signed panel receipt](../../evidence/2026-11-20T121149Z-indexing-indicator/panel/receipt.json). The native switch fixture uses the real controls/config writes with a synthetic index-state callback; Core tests independently cover the controller retry and existing skip-policy rebuild behavior. It is not a live user-data crawl.

The first debug compilation failed because four fixture assertions placed throwing frame/view reads inside a nonthrowing assertion autoclosure. Those reads now complete before the assertions. [Initial log](../../evidence/2026-11-20T121149Z-indexing-indicator/debug-build-initial.log) and [successful final debug build](../../evidence/2026-11-20T121149Z-indexing-indicator/debug-build.log) are preserved. Final debug/release suites and profiles had no failures. Existing Command Line Tools linker search-path warnings remain.

## Native frame evidence

`indexing_indicator` in both Settings receipts stores actual frames after layout, in window content coordinates. Equality includes every folder row, folder card, Add Folders, Allow Access, indicator, action row, both Skip controls, Skip card, Rebuild, Index card and content size. Values are compared exactly, not inferred from screenshot similarity.

| Measurement, points | Idle | Indexing |
| --- | ---: | ---: |
| All-ready folder card height | 179 | 179 |
| All-ready folder row heights | 44 each | 44 each |
| All-ready content height | 421 | 421 |
| Mixed folder card height | 206 | 206 |
| Mixed row heights (ready / errors) | 44 / 53 | 44 / 53 |
| Mixed content height | 448 | 448 |
| Add/action row height | 24 | 24 |
| Skip / Index card heights | 89 / 53 | 89 / 53 |
| Indicator origin X / height | 135.5 / 16 | 135.5 / 16 |

The Add button starts at X 20 and is 107.5 points wide; the indicator starts at X 135.5, an 8-point gap. Its center Y equals the button's. Different actionable statuses naturally have different row heights; within each status-preserving idle/indexing pair every frame is unchanged.

## Renders and retention

| State | Light | Dark |
| --- | --- | --- |
| All ready, idle | [Render](../../evidence/2026-11-20T121149Z-indexing-indicator/settings/settings-indexing-idle-light.jpg) | [Render](../../evidence/2026-11-20T121149Z-indexing-indicator/settings/settings-indexing-idle-dark.jpg) |
| Every folder indexing | [Render](../../evidence/2026-11-20T121149Z-indexing-indicator/settings/settings-indexing-all-light.jpg) | [Render](../../evidence/2026-11-20T121149Z-indexing-indicator/settings/settings-indexing-all-dark.jpg) |
| Mixed errors, idle | [Render](../../evidence/2026-11-20T121149Z-indexing-indicator/settings/settings-indexing-mixed-idle-light.jpg) | [Render](../../evidence/2026-11-20T121149Z-indexing-indicator/settings/settings-indexing-mixed-idle-dark.jpg) |
| One indexing, mixed errors | [Render](../../evidence/2026-11-20T121149Z-indexing-indicator/settings/settings-indexing-mixed-light.jpg) | [Render](../../evidence/2026-11-20T121149Z-indexing-indicator/settings/settings-indexing-mixed-dark.jpg) |

All eight new renders were inspected, plus affected existing Folders/error/Skip states. The small spinner and label sit on the Add row with no clipping or overlap; descriptions remain readable in both appearances. The Index card retains its existing progress text by explicit scope.

[Retention](../../evidence/2026-11-20T121149Z-indexing-indicator/retention.json) covers **238 final scenarios**, reusing **222** prior images only after exact raw-image hash matches, including all **184 panel images**. Eight previous Folders images changed; eight indicator examples are new. Two changed images duplicate other local images, leaving **14 local JPEGs**, rendered at one pixel per point, quality 60. Original native images and 54 superseded debug images are archived outside the repository with hashes retained. No crop/content edits. Evidence remains below 1 MB at handoff; previous evidence is intact.

## Build identity and isolation

Base `87d171c72d2f635b4d3f719e1194d2311d25b509`, dirty working tree. Review bundle: `build/review/2026-11-20-indexing-indicator/Apparate.app`, signed executable SHA-256 `ed436bbe06a3f516ef09c3e0a79d17fc5bda08f5457eae8a5c5145d1005ba5f1`. [Build identity](../../evidence/2026-11-20T121149Z-indexing-indicator/build-identity.json), [86-input source manifest](../../evidence/2026-11-20T121149Z-indexing-indicator/source-manifest.json), [assembly recipe](../../evidence/2026-11-20T121149Z-indexing-indicator/assembly.txt), [assembly/signature log](../../evidence/2026-11-20T121149Z-indexing-indicator/assembly.log). Only SettingsWindow, SettingsVerification, FileIndexController and FileIndexTests differ from section 13 among these inputs. Swift 6.4.2, macOS 27.0, arm64; isolated SwiftPM scratch directory `/private/tmp/apparate-ui-build-20261119`.

After functional checks and render review, the authorized build.sh rebuilt `build/Apparate.app`; [normal build log](../../evidence/2026-11-20T121149Z-indexing-indicator/normal-build.log) and [bundle checks](../../evidence/2026-11-20T121149Z-indexing-indicator/bundle-checks.json) record its identity and strict/deep signature. Both bundles contain the source-matching AppIcon and CFBundleIconFile. The normal bundle is not installed or launched. Prior review binaries remain unchanged.

All hidden profiles use explicit isolated binaries, disposable config/index/history, fake global actions and non-presenting windows. Every receipt reports zero stderr and native effects, no visible profile, owned-process exit and temporary-home removal. No installed-app mutation, launch, quit, running-app access, real data/session-folder access or commit. `docs/wiki/evidence/2026-11-20T121149Z-indexing-indicator/integrity.py` verifies input/bundle/image hashes and native receipt assertions.

## Limits and remaining gates

Visible spinner animation, physical switch interaction and spoken VoiceOver remain supervised. Hidden frames and static native renders do not establish on-screen presentation timing. Toolbar/window chrome remains outside content renders. No search-pipeline or memory benchmark was repeated for this status/presentation change. The separate [section 11 memory result](2026-11-20T111919Z-below-icons.md#memory-comparison-completed) remains: 49.14 MiB at preferences fails the 40 MiB target and 47 MiB comparison, while staying below the 60 MiB ceiling. M6's deferred attribution and on-screen work remain open.
