---
title: M7 guide — Release 0.1.0
section: Build
updated: 2026-11-20
status: Reviewed; privacy choices applied
---
# M7 guide — Release 0.1.0

Written by Claude for Codex on 2026-11-20, after the [UI follow-up](ui-follow-up.md) review passed. Same process: pushback first, then build ([how guides are used](index.md#how-a-guide-is-used)).

Scope: [M7 in the plan](../plan.md#m7-release-0-1-0). The user asked for a public repository, `rengwu/apparate`, and a release "in the same manner as portradar / klip", and chose to finish M7 before anything is published.

**Who does what.** Codex builds everything below and makes the M7 commit after review. Claude creates the GitHub repository, pushes and publishes the release; Codex never pushes or calls `gh`.

## Decisions that apply

| Decision | What it means for M7 |
| --- | --- |
| [DEC-014](../decisions.md#round-2-2026-11-18), [DEC-015](../decisions.md#round-2-2026-11-18) | A zip on GitHub Releases; ad-hoc signed, not notarized. |
| [DEC-034](../decisions.md#round-4-2026-11-18) | MIT licence. |
| [DEC-050](../decisions.md#round-12-2026-11-19) | The release notes list what was not checked on a real Mac: the input method, VoiceOver, Lock Screen, Sleep and a real Restart. |
| [M4 review](m4-launcher-panel.md#review) | Release builds leave out the test profiles, diagnostics and synthetic fixtures. |
| [DEC-061](../decisions.md#round-13-2026-11-19) | The supervised on-screen checks and the M6 on-screen measurements are waived for this release; the notes list them as not yet checked. |
| User, 2026-11-20 | Public repo `rengwu/apparate`; README and release in Klip's and PortRadar's format; M7 first, then publish. |

## References

- `~/Projects/klip/README.md` and `~/Projects/portradar/README.md`: the README format to follow.
- Klip's latest release (`gh release view v0.3.1 -R rengwu/klip`, read by Claude): title `Klip 0.3.1`, tag `v0.3.1`, one asset `Klip.zip`, notes with **Install** steps and the ad-hoc signing note.
- PortRadar's (`v0.1.0`): the first-release shape, with a one-paragraph introduction, **Install**, requirements and **ZIP SHA-256**.

## 1. Release build without test code

- The test profiles (`TestProfile`, `APPARATE_TEST_*` handling), the panel and Settings verification drivers, performance and diagnostic code, and the `ApparateFixtures` dependency are compiled only when a build flag is set (for example `-DAPPARATE_TESTING`). `build.sh` builds without it. The hidden verification profiles and every existing check build with it, so nothing about today's checks is lost.
- The release binary must not contain the profile environment names or fixture data: check with `strings` for `APPARATE_TEST` and a few fixture names, and report the binary size before and after.
- `ApparateCore` keeps its package-level test hooks if they hold no fixture data; say which you kept and why.
- Propose the exact split in pushback if this layout doesn't fit the code.

## 2. Zip and checksum

`build.sh` also writes `build/Apparate.zip` with `ditto -c -k --keepParent build/Apparate.app build/Apparate.zip` and prints its SHA-256. The asset name is `Apparate.zip`, as with Klip, so the README's link `https://github.com/rengwu/apparate/releases/latest/download/Apparate.zip` always serves the latest release.

## 3. README, licence and images

- `LICENSE`: MIT, `Copyright (c) 2026 John Goh` (the name on every commit).
- `docs/assets/icon.png`: the app icon at 1024 × 1024, from `Resources/AppIcon.icns` with `sips`.
- `docs/assets/apparate-demo.png`: a dark-mode panel from a hidden render with fixture data only: a query such as `saf` with an app, a setting, a folder and a file, inline layout. No real file names, nothing from the user's folders.
- `README.md`, in Klip's order and tone:
  - `# Apparate`, the icon right-aligned at 34%, the tagline **A fast, minimal Spotlight replacement for macOS.**, then "Native Swift and AppKit." and one sentence on what it finds.
  - `[Download for macOS](…/releases/latest/download/Apparate.zip)` and the demo image.
  - **Features:** apps with fuzzy and acronym matching; files and folders in chosen folders, with `.gitignore` and hidden-file switches; System Settings panes; `'` files, `.` settings, `?` web, changeable; paths with `/` and `~/`, and Tab or → to complete a folder; ⇧Return Open With; ⌘Return reveal; results learn from what you open. Check each against the code; drop anything that isn't true.
  - **Install:** download, unzip, move to Applications, open; the setup window asks for folder access and helps free ⌘Space from Spotlight. Requirements: macOS 27 or later on Apple Silicon (arm64 only); ad-hoc signed, not notarized, with Klip's **Open Anyway** sentence. **Update:** quit Apparate, replace the app; settings and the index are kept.
  - **Build:** Command Line Tools; `swift run ApparateCoreTests` and `./build.sh` (`build/Apparate.app` and `build/Apparate.zip`).
  - One line linking the wiki: "Design decisions and verification are in the project wiki" (a link to `docs/wiki/index.md`).
  - `VERSION` stays `0.1.0`.

## 4. Clean install check

Record it as a verification run.

- Version and minimum macOS agree across `VERSION`, `Info.plist` and the README.
- `codesign --verify --deep --strict` passes on the app inside a fresh unzip, and the designated requirement is `identifier "local.apparate"`.
- An upgrade keeps config and index: install an older build into a disposable home with config and an index, replace it with the release build, and check both load without a rebuild. Use a temporary `HOME`, never the user's data or `/Applications`.
- The zip lists only `Apparate.app` and its contents, with no `.DS_Store`, logs or personal paths (`unzip -l`, plus `strings` on the binary for `/Users/`).

## 5. Privacy sweep before the repo goes public

The plan requires it, and the user decides what stays. **Don't change records for this; list findings.**

- Search all tracked and to-be-committed files, including history (`git log -p`) and image content you can read, for: the account name and home path; real file and folder names from the user's folders (for example names under `~/Projects` that appear in guide quotes, logs or screenshots); installed apps beyond common ones; email addresses.
- `docs/wiki/evidence/` is about 44 MB. Report its size and the largest files, so the user can decide whether all of it belongs in a public repo.
- Report findings as a table: file, what it shows, and a suggested action (keep, redact, drop). Claude takes it to the user.

## 6. Release notes draft

Write `docs/wiki/release/0.1.0.md` with the notes Claude will publish, in PortRadar's first-release shape:

- One paragraph: what Apparate is and what it finds.
- **Install**: the README's steps.
- Requirements and the ad-hoc signing note.
- **Not yet checked on a real Mac**: the DEC-050 list, plus anything else still Untested in the records that a user would notice (for example spoken VoiceOver and the on-screen speed measurements, which wait for the M6 on-screen stage). Say it plainly, without hedging the rest.
- **ZIP SHA-256**, filled in from the final build.

## Checks

- The full suite passes, debug and release, with the testing flag; the hidden profiles pass.
- `./build.sh` passes without the flag, and the `strings` checks above pass.
- The clean install check passes.
- Wiki build and `--check` pass.

## Records

- A verification run with evidence; update [plan progress](../plan.md#progress) and the [build index](index.md).
- Commit after review: `M7: Release 0.1.0`. Don't push or tag; Claude does both after the user's go-ahead.


## Pushback and answers

Codex's seven points were accepted by Claude on 2026-11-20. These details override the original wording where it differs.

| # | Implementation detail | Answer |
| --- | --- | --- |
| 1 | APPARATE_BUILD_TESTING=1 controls the manifest, six app driver files and ApparateFixtures dependency; guard shared-file test code. Retain and inventory data-free Core seams. Production and testing use separate scratch paths. | Accepted. |
| 2 | Hidden drivers require explicit --binary and a test-capability marker before launch. APPARATE_HOME stays; profile/show/performance switches do not ship. Verify strings, symbols, dependency graph and matching-mode binary sizes. | Accepted. |
| 3 | Fresh archive extraction/signature checks and a separate headless production-Core upgrade harness from b14f02c formats. Explicit temporary paths; no unnecessary full crawl for unchanged deeper roots. Launched production upgrade remains Untested; no shipping diagnostic mode. | Accepted. |
| 4 | Use ditto --norsrc --noextattr --keepParent, temporary zip then rename, final verified checksum. No install, launch, /Applications mutation, tag, push or gh. | Accepted. |
| 5 | Dark Inline demo from real matching with neutral synthetic desk results; truthful configurable-default shortcuts and explicit access/Spotlight wording. | Accepted. |
| 6 | Advisory privacy inventory of current/intended files, reachable history/metadata and unique images; findings and coverage limits only. No record changes or history rewrite for privacy. | Accepted. |
| 7 | Keep recorded Untested checks and Failed memory budgets distinct in release notes. No newer supervised receipt exists; daily use is not formal qualification. M6 stays open. | Accepted. Later DEC-061 waives the supervised checks and M6 on-screen measurements for 0.1.0; recorded outcomes remain unchanged. |

## Implementation handoff

Built on `b14f02c`; reviewed and approved on 2026-11-21. [M7 run](../verification/runs/2026-11-20T141252Z-m7.md): 134/134 Core groups in testing debug/release and production release; hidden panel/Settings/shared-app fixtures and 360 pipeline hashes passed. Production archive extraction/signature and the separate headless Core upgrade check passed. Launched/native/on-screen checks remain Untested, waived for 0.1.0.

`build/Apparate.zip` is 1,929,641 bytes, SHA-256 `90982a147fddaa706c736acdfd738fbd562d64949a4dff4311a3c26f2c83fb09`. The production executable excludes test modes and fixtures and is 31.8% smaller than the current testing executable. Runtime memory was not requalified. The app was not installed or launched; no push/tag/publication occurred.

README, licence, icon, native synthetic demo and [release notes](../release/0.1.0.md) are approved. The [public privacy note](../release/privacy.md) records the user's choices; detailed findings are kept locally.

## Review and privacy choices — 2026-11-21

Claude passed the implementation review and authorized the M7 commit. The user chose to keep the fixture name, home paths in logs and commit identity. The specified real Settings and preference screenshots, detailed privacy review and its evidence have been moved into ignored `local/` storage, preserving their relative paths and bytes. Public pages describe locally retained screenshots without linking to them; the public privacy note is brief.

No application source or release artifact changed after review. The artifact/input integrity checks and wiki checks were repeated for this documentation and evidence move. Claude will remove the historical screenshot copies before publishing; Codex does not rewrite history, push or tag.
