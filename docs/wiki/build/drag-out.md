---
title: Drag results out
section: Build
updated: 2026-11-24
status: Review passed, supervised drops pending
---
# Drag results out

Written by Claude for Codex on 2026-11-24, the first brief under jstack's `orchestrate` workflow. Same process: pushback first, then build ([how guides are used](index.md#how-a-guide-is-used)).

## Request

The user, with a screenshot of the panel listing PDF results for a name query: "it's be nice if i can mouse drag and drop files to anywhere, as if i'm dragging it from finder". The screenshot isn't kept, because it shows real file names and folders.

## Decisions that apply

| Decision | What it means here |
| --- | --- |
| The request above | A result row that is a file, folder or app can be dragged out of the panel and dropped anywhere that accepts a Finder drag. |
| [DEC-013](../decisions.md#round-2-2026-11-18) | AppKit only. |
| [DEC-052](../decisions.md#round-13-2026-11-19) | The panel grows to fit its results; drag targets follow the rows that are shown. |
| [DEC-057](../decisions.md#round-13-2026-11-19) | Open With rows are apps; they follow the same rule as any other row. |
| [Rules for every milestone](index.md#rules-for-every-milestone) | Lean, plain UI, no packages, headless core, private data out of records. |

Two product calls are Claude's proposals and have not been put to the user yet. They are marked **(proposal)** below. The user may change them; build them as written unless told otherwise.

## 0. Housekeeping

- Fix `docs/wiki/index.md` line 45: the UI follow-up review is no longer pending (sections 1–14 were reviewed and committed in `9194cfd`). The on-screen resize proof is still open; keep saying so.
- Commit the `.gitignore` line `/.agents/jstack/orchestrate/` with this brief.

## 1. Which rows drag

A row drags when its item has a file URL: `entry.target.fileURL != nil`. That is the same condition that puts "⌘↩ Reveal in Finder" in the footer today, so apps, folders and files drag, and System Settings items, commands and web searches don't. No other special cases, Open With rows included.

## 2. Click and drag on the same row

Today `ResultsView.mouseDown` opens the row at once, so there is no room to start a drag. Change it to how Finder and Spotlight handle a press:

1. **Press** selects the pressed row (through `onSelect`, so the highlight and accessibility selection move) and opens nothing.
2. **Release without dragging** opens the row whose ID was captured at the press, through the existing `onActivate` path. Activation stays ID-based, so the pending-results rule in [FEAT-panel](../features/panel.md) (a removed result never opens a replacement) still holds. Restart arming by click keeps working because it goes through the same path.
3. **Moving while pressed** past the system drag threshold starts a drag, but only on a row from section 1. On any other row, the movement is ignored and the release opens the row as a click.

Scroll-wheel, keyboard, ⌘1–9 and accessibility press are unchanged.

## 3. The drag itself

- **Pasteboard:** the item's file URL, written as an `NSURL` pasteboard writer (`public.file-url`). Nothing else: no extra types, no promised files.
- **Operations:** outside the app, offer `.copy`, `.move`, `.link` and `.generic`, the way Finder does, and let the destination choose. A drop into a Finder folder on the same disk moves the file, and ⌥ copies, exactly as when dragging from Finder. **(proposal)** Inside the app, offer nothing; the panel is not a drop target. Don't offer `.delete`: Apparate never copies, moves or deletes a file itself. The destination does the work, and the file index notices the change as it already does.
- **Image:** the row's icon at its drawn size and position, so it lifts out of the row. No title label.
- **Not a use:** a drag doesn't record usage or change ranking. Only opens do.

## 4. The panel during a drag **(proposal)**

The panel sits in the middle of the screen, over whatever the user may want to drop on. So:

- While the pointer is still over the panel, the panel stays.
- As soon as the drag leaves the panel's frame, the panel hides through the same path as losing focus (`hide()`, then `onHidden`). It doesn't come back for the rest of that drag.
- A drag released over the panel, before it ever left, ends with no operation and leaves the panel as it was: same query, the pressed row selected.
- The drag must survive the panel hiding mid-drag: once `hide()` empties the model and rows, the session's callbacks can't index into `contents` or assume the window is visible.

## Checks

Hidden checks, added to the existing panel verification on the non-presenting panel. Keep the drag decisions in small functions the harness can call (whether a row drags, its pasteboard item, the operation mask, whether a screen point hides the panel), because a real dragging session can't run hidden.

1. A click (press and release, no movement) opens the right row by ID for a file, a folder, an app, a settings item and a command, including after scrolling and after a resize. Change the existing `activate(point:)` callers to go through press and release, so they cover the new path.
2. A press alone selects the row and opens nothing.
3. A press, a move smaller than the drag threshold and a release open the row.
4. A file, a folder and an app row each give exactly one pasteboard item, equal to the item's file URL. A settings, command and web row give none, and a press-move-release on them opens the row.
5. The operation mask is copy, move, link and generic outside the app, and empty inside it.
6. A drag point outside the panel frame hides the panel once and calls `onHidden` once. Points inside don't. A drag ended inside leaves the query, selection and rows unchanged.
7. Ending a drag after the panel hid and the rows emptied doesn't crash or touch stale rows.
8. Full test suite, release build, `./build.sh`, then `node docs/wiki/_build.mjs` and `node docs/wiki/_build.mjs --check`.

On-screen checks, for the user once the review passes. Record them as Untested in the run until then:

- Drag a PDF into a Finder folder on the same disk (moves), with ⌥ (copies), and onto the Desktop behind where the panel was.
- Drag a file into a Mail message, a browser upload field and a chat app; drag a file into Terminal (inserts the path).
- Drag an app to the Dock and a folder to the Finder sidebar.
- Release a drag back over the panel: it stays. A plain click still opens.

## Records

- Update [FEAT-panel](../features/panel.md): the Click row of its key table and a short drag section, plus the on-screen checks above in its supervised list.
- Record the run in `verification/runs/` with jstack's `verify-change` (`~/Projects/jstack/skills/verify-change/SKILL.md`), naming which checks are hidden, which are Untested, and the operation Finder chose in any drag you could observe.

## Off limits

- Dropping anything onto Apparate.
- Dragging more than one row at once.
- New settings, footer text or menu items for dragging.
- File operations performed by Apparate.
- AppKit or pasteboard code in `ApparateCore`.

## Commit

One commit after the review passes: subject `Panel: drag results out`, then a short body listing what changed and how it was checked. Never push.

## Review

Codex had no pushback. Round 1 found two issues, both fixed and rechecked ([post-review fix](../verification/runs/2026-11-24T074838Z-drag-out.md#post-review-fix)):

1. Losing key focus during a drag no longer dismissed the panel, which could leave it floating and unfocused after a drag released over it. Losing focus now dismisses it as always.
2. A row whose icon was still loading dragged a generic document symbol. It now uses the item's Finder icon.

Claude reran the hidden panel profile on the fixed review build; the drag checks passed. The review passed on 2026-11-24. The on-screen drops in [FEAT-panel's supervised recipes](../features/panel.md#supervised-recipes-untested) (8–10) are still Untested, and so are the two proposals the user hasn't confirmed: hiding the panel once the drag leaves it, and Finder's move-on-same-disk behaviour.
