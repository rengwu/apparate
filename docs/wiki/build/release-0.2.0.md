---
title: Release 0.2.0
section: Build
updated: 2026-11-25
status: Reviewed and passed; publishing
---
# Release 0.2.0

Written by Claude for Codex on 2026-11-25. The user, after trying the drag-exit fade: "looks great. commit, push, release." [DEC-070](../decisions.md#round-23-2026-11-25): the version is **0.2.0**. Codex builds, checks and records; Claude reviews, then pushes, tags and publishes, as for [0.1.1](../release/0.1.1.md).

## What ships

Everything since 0.1.1: the [drag-out brief](drag-out.md), sections 0–7 (`9053c75`, `e4bdd37`, `61e8863`).

## Changes

1. **`VERSION`:** `0.2.0`.
2. **README, Features list:** add one bullet after the ⌘Return line: "Drag files, folders and apps out of the results, as you would from Finder". Nothing else in the README changes.
3. **Release notes**, `docs/wiki/release/0.2.0.md`, in the same shape as 0.1.1 (frontmatter `status: Published 2026-11-25`; Claude publishes straight after the commit). Body:

   > Drag results out of Apparate.
   >
   > - Drag a file, folder or app from the results and drop it anywhere that takes a drag from Finder: a folder, the Desktop, a Mail message, a browser upload, Terminal or the Dock. A click still opens it.
   > - As the drag leaves the panel, the panel fades out, so you can drop on whatever is behind it.
   > - Settings → General → **Dragged files**: **Like Finder** (the default) lets a drop into a folder on the same disk move the file, as Finder does. **Never move** makes it copy instead.
   > - A completed drop counts toward ranking, like opening the item.

   Then **Install**, copied from 0.1.1. Then **Not yet checked and known limits**: "The drag itself is covered by automated checks, and the fade has been tried by hand. Dropping into particular apps (Mail, browsers, chat apps, Terminal, the Dock) and the Never move choice with each of them haven't been checked by hand yet. Other limits are unchanged; see the [0.1.0 notes](https://github.com/rengwu/apparate/releases/tag/v0.1.0)." Then **ZIP SHA-256** with the final archive's size and hash.
4. **The fade run** (`verification/runs/2026-11-24T162231Z-drag-fade.md`): the user tried the build on 2026-11-25 and said "looks great". Record the visible fade as Passed on that basis. The Finder/Desktop delivery and physical hotkey rows stay Untested: the user didn't say which steps they ran.
5. **Records:** link the notes from `index.md` (next to 0.1.1) and add a line to FEAT-release's verification history.

## Checks

- `./build.sh`, then `Tests/release-check.py` on a fresh extraction of `build/Apparate.zip`. It must report version 0.2.0.
- `Tests/upgrade-check.py`: the config gained `dragCanMove`, so confirm saved 0.1.x data still loads.
- The Core suite in production mode. The hidden panel and Settings profiles already passed on the reviewed fade sources; only `VERSION`, the README and records change, so don't rerun them.
- Wiki rebuild and check.

Record the run under `evidence/` as for 0.1.1.

## Commit

One commit after the review passes: subject `Release 0.2.0`, with a short body (what ships, the archive SHA-256, what's Untested). Don't tag and don't push; Claude does both.

## Review

Codex had no pushback. Claude read the README line, the notes, the fade run's change and FEAT-release's line, and checked the archive separately: SHA-256 `2bc938f5…c44f5` and 2,018,992 bytes as in the notes, version 0.2.0, strict signature check passed, and the extracted binary matched `build/Apparate.app`. The new evidence holds no paths outside the project. The review passed on 2026-11-25 with no findings.
