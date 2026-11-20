---
title: Tab completes the selected result
section: Verification
updated: 2026-11-19
result: Untested
status: Hidden behavior passed; physical keyboard and IME untested
---
# Tab completes the selected result

Section 7 / DEC-056 extends Tab completion to the selected current result in every search. Both corrections in the [guide](../../build/ui-follow-up.md) are implemented: files use a home-abbreviated path, and app/setting/command names keep their scope prefix. See [FEAT-panel](../../features/panel.md) and the [repeatable recipe](../setup.md#completing-the-selected-result).

## Behavior

Folders replace the query with their home-abbreviated path and a trailing `/`, then list that folder; root stays `/`. Files replace it with their home-abbreviated path. Filesystem paths drop the scope prefix. App, setting and command completions use the displayed name and retain any active scope prefix. Thus `.disp` becomes `.Displays`.

Only the selected accepted row may complete. Hidden, pending, composing, missing-selection, web and identical-text states do nothing. The native delegate also rejects completion if its editor text has not yet reconciled with the model query. Tab and Shift-Tab reaching the delegate always remain in the field; Shift-Tab never completes. The input method gets its normal first opportunity. Replacement uses the native editor, breaks text undo coalescing around the action and leaves the caret at the UTF-16 end.

## Results

| Scenario | Expected and observed | Result |
| --- | --- | --- |
| Core debug/release | 110/110 in each, including kind/scope, root/outside-home paths, current selection, pending generations, composition, hide and no-op cases | Passed |
| Selected folder | `quinecm` selects the second row, `quinecms-demo-site`; Tab becomes `~/Projects/quinecms-demo-site/` and lists README.md | Passed |
| Scoped folder/file | Prefix dropped; folder contents shown and Unicode file path home-abbreviated without losing the emoji, accent or CJK text | Passed |
| Scoped names | `@fixt`, `.disp`, `!loc` retain their respective prefixes with complete displayed names | Passed |
| Native history | For each of six cases, undo restores the original typed query and redo restores completion, with matching results | Passed |
| Native no-op routing | Identical, Shift-Tab, empty, web, pending, unreconciled editor, marked Tab/backtab leave text, selection, revision and history unchanged | Passed |
| Focus and actions | Same owned editor, caret at the end after replacement; zero completion actions or real filesystem reads | Passed |
| Signed panel/Settings regression profiles | Both Passed; zero stderr/native effects and owned-process/home cleanup | Passed |
| Light/dark hidden renders | Selected folder and resulting contents, Unicode file and scoped names inspected; text and highlights remain readable | Passed |
| Physical keyboard, native event history grouping and real IME | No on-screen window authorized; injected commands cannot establish these | Untested |

[Debug tests](../../evidence/2026-11-19T121020Z-tab-completion/debug-tests.log), [release tests](../../evidence/2026-11-19T121020Z-tab-completion/release-tests.log), [debug native receipt](../../evidence/2026-11-19T121020Z-tab-completion/debug-panel/receipt.json), [signed panel receipt](../../evidence/2026-11-19T121020Z-tab-completion/panel/receipt.json), [signed Settings receipt](../../evidence/2026-11-19T121020Z-tab-completion/settings/receipt.json).

The first Core attempt recorded 109 Passed and one Failed because its supposedly distinct query `row o` still fuzzy-matched both rows. Retaining the previously selected Row Two was correct. Changing the fixture query to `row on` makes the expected Row One unambiguous; both final suites pass. The [initial attempt](../../evidence/2026-11-19T121020Z-tab-completion/attempt-debug-tests.log) remains recorded.

The hidden history check clears fixture input history before each completion, then sends actual `insertTab:`, `undo:` and `redo:` commands through the owned AppKit editor. It proves this isolated native history action and asynchronous query reconciliation. It does **not** prove how physical typing and Tab are grouped by real keyboard events. Real input-method candidate handling, focus transfer and composed presentation retain their Untested status.

## Review images

Before/after images come from the final signed release. The scoped-folder after image is byte-identical to the ordinary-folder after image and links to the retained copy.

| Completion | Before | After |
| --- | --- | --- |
| `quinecm → ~/Projects/quinecms-demo-site/` | [light](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-folder-before-light.jpg) / [dark](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-folder-before-dark.jpg) | [light](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-folder-after-light.jpg) / [dark](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-folder-after-dark.jpg) |
| `'quinecm → ~/Projects/quinecms-demo-site/` | [light](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-scoped-folder-before-light.jpg) / [dark](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-scoped-folder-before-dark.jpg) | [light](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-folder-after-light.jpg) / [dark](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-folder-after-dark.jpg) |
| `'東京 → ~/A👩🏽‍💻é東京.md` | [light](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-file-before-light.jpg) / [dark](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-file-before-dark.jpg) | [light](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-file-after-light.jpg) / [dark](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-file-after-dark.jpg) |
| `@fixt → @Fixture Editor` | [light](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-app-before-light.jpg) / [dark](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-app-before-dark.jpg) | [light](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-app-after-light.jpg) / [dark](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-app-after-dark.jpg) |
| `.disp → .Displays` | [light](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-setting-before-light.jpg) / [dark](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-setting-before-dark.jpg) | [light](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-setting-after-light.jpg) / [dark](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-setting-after-dark.jpg) |
| `!loc → !Lock Screen` | [light](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-command-before-light.jpg) / [dark](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-command-before-dark.jpg) | [light](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-command-after-light.jpg) / [dark](../../evidence/2026-11-19T121020Z-tab-completion/panel/completion-command-after-dark.jpg) |

The complete evidence is 3.05 MB (2.91 MiB). Its 180 final scenarios use 150 unique JPEGs at one pixel per point, quality 70; 30 identical copies map to retained files. [Retention](../../evidence/2026-11-19T121020Z-tab-completion/retention.json) records original hashes/dimensions and every output mapping. Debug images remain outside the repository; only their receipt is needed here. Hidden bitmaps do not establish WindowServer composition.

## Identity and isolation

Base `87d171c72d2f635b4d3f719e1194d2311d25b509`, dirty UI tree. New immutable bundle `build/review/2026-11-19-tab-completion/Apparate.app`, identifier `local.apparate.review`, signed release SHA-256 `437084b119977f27da3a2d1bad2922d6df5ebcbcd5613faf5fcc679bb4f761fd`. macOS 27.0 build 26A5368g, Apple Swift 6.4.2, arm64. [Identity](../../evidence/2026-11-19T121020Z-tab-completion/build-identity.json), [80-input manifest](../../evidence/2026-11-19T121020Z-tab-completion/source-manifest.json), [debug build](../../evidence/2026-11-19T121020Z-tab-completion/debug-build-final.log), [release build](../../evidence/2026-11-19T121020Z-tab-completion/release-build.log), [assembly](../../evidence/2026-11-19T121020Z-tab-completion/assembly.txt), [signature verification](../../evidence/2026-11-19T121020Z-tab-completion/assembly.log), [commands](../../evidence/2026-11-19T121020Z-tab-completion/commands.txt). Existing Command Line Tools search-path warnings remain.

SwiftPM used `/private/tmp/apparate-ui-build-20261119`. All app drivers passed the explicit isolated binary and used disposable homes, hidden windows, fixture files/readers and fake effects. Builds/tests ran sequentially. No build.sh invocation, running-app/data/session access, visible window, activation, native global effect, protected-folder probe, screen capture, commit or push.

This change executes on Tab and adds no index storage or ordinary-search matching work. CPU/memory/pipeline measurements were not repeated. The [section 6 measurements](2026-11-19T115135Z-dot-names.md) retain their original fingerprint and budget failures; attributing the 200k preferences increase remains queued for M6, as requested by Claude.
