---
title: Release and updates
section: Features
updated: 2026-11-21
---
# Release and updates

**FEAT-release.** [M7](../build/m7-release.md) prepares Apparate 0.1.0 for distribution as one ad-hoc-signed zip, for macOS 27 or later on Apple Silicon. Publication belongs to Claude after review and the user's publication decision.

## Entry points and expected outcomes

`./build.sh` writes `build/Apparate.app` and `build/Apparate.zip`, then prints the final archive's SHA-256. It forces `APPARATE_BUILD_TESTING=0`, uses its own `.build/production` directory and builds only the app product. The bundle contains the app icon, menu icons, MIT licence and third-party notices. Its fixed identity is `local.apparate`; it is not notarized. The archive contains only the app and its contents, without resource forks or extended attributes. A temporary zip is renamed only after compression succeeds. The script never installs or launches the app.

The README describes download, unzip, moving to Applications and opening, including macOS's Open Anyway route. Setup leaves folder access and Spotlight shortcut changes explicit. Updates replace the app after quitting; configuration, history and the index live outside the bundle. A changed indexing rule may rebuild the cache. See [first run](first-run.md), [config](config.md) and [file index](file-index.md).

## Testing and production split

`APPARATE_BUILD_TESTING=1` enables six app driver files and the `ApparateFixtures` dependency. Shared AppKit source guards hidden capture, fake effects, diagnostic counters and profile dispatch with `APPARATE_TESTING`. Production retains `APPARATE_HOME` for the data-directory override; it has no test/show/performance environment modes. The Python smoke and performance drivers require an explicit testing `--binary` and reject missing or non-testing executables before starting a process. This marker check protects normal usage; it is not a sandbox for arbitrary untrusted binaries.

The separate CoreTests, UpgradeCheck and Observer targets are development tools, not app dependencies or bundled programs. Core remains headless and unchanged from the UI follow-up. Its data-free seams remain:

| Seam | Purpose and production behavior |
| --- | --- |
| Injectable file/path readers, canonicalization, watchers and cache/config persistence | Deterministic isolated verification; normal constructors use native filesystem implementations. The restricted path reader prevents fixture navigation outside its owned root. |
| Action executor, hotkey, login, access and Open With protocols/models | Keep decisions independent of AppKit and let tests substitute effects. Production factories use real native services. |
| `FileIndexStore.failBeforeActivation` / `injectActivationFailure` | Transaction failure injection defaults off; no environment switch enables it. |
| Search coordinator engine, delivery/fence callbacks, trace and optional stage timings | Verify cancellation, result delivery and pipeline phases; optional observers/timing are off unless provided. |
| Snapshot diagnostics and pure frame observation/marker types | Count/index verification and the separate observer's serialization/math; no fixture dataset or shipping profile dispatch. App-side marker drawing and capture are excluded. |

## Verification recipe

Use the exact [M7 setup](../verification/setup.md#m7-release-build-and-hidden-checks). Run Core debug/release with testing enabled, build the production archive, then run `Tests/release-check.py` against a fresh extraction. Separately, `Tests/upgrade-check.py` builds the baseline Core from `9194cfd` in an owned temporary directory, seeds config/index/history and checks them with the candidate production-mode Core harness. Expected: equal saved content/results and no full crawl. Both helpers preserve receipts and remove their owned temporary extraction/home.

Run hidden native panel/Settings profiles and the shared app fixture path against the explicit testing review bundle. Never substitute the production app for these profiles: `APPARATE_HOME` alone does not disable real effects. The release demo is a real matcher query over neutral synthetic app/setting/folder/file items, drawn by the native panel without a test marker.

## Coverage and limitations

The archive/signature and headless store compatibility checks do not establish a launched install or upgrade, quarantine handling, native privacy grants or Login Items behavior. Those and the on-screen measurements remain Untested, waived for 0.1.0 by [DEC-061](../decisions.md#round-13-2026-11-19). Existing Failed memory budgets remain Failed; smaller executable size is not evidence of lower runtime memory. The [release notes](../release/0.1.0.md) list these limits.

The user's [privacy choices](../release/privacy.md) are applied: the specified real screenshots and detailed audit are kept locally and excluded from publication. Remaining fixture names, log paths and commit identity are retained. Claude handles historical screenshot removal before publication.

## Verification history

- [M7 verification](../verification/runs/2026-11-20T141252Z-m7.md): static artifact, production-Core compatibility and hidden functional checks passed; launched/native/on-screen scope remains Untested.
- [0.1.1](../release/0.1.1.md), 2026-11-21: only the icon changed, and the README dropped its demo image. `Tests/release-check.py` passed on the archive (`evidence/2026-11-21T173056Z-release-0.1.1/artifact/`); the check no longer pins version 0.1.0. The hidden app checks were not rerun.
