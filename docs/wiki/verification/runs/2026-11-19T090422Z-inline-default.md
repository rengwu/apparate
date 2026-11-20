---
title: Inline location default verification
section: Verification
updated: 2026-11-19
result: Untested
status: Default verified; live review pending
---
# Inline location default verification

DEC-053 round 15 changes the default to **Inline**. New configs and existing configs without `resultLocation` now use `inline`; explicitly saved `inline`, `right` and `below` values remain intact. Controller/drawing fallback defaults agree, and General initially selects Inline. The config schema stays version 1. Current [config](../../features/config.md), [Settings](../../features/settings.md) and [panel](../../features/panel.md) records are updated; preceding run evidence retains its original Right-default fingerprint.

## Checks

- Full Core: **91/91 debug and 91/91 release**, including missing-key defaults, explicit-value round trips and stale-write handling. [Debug](../../evidence/2026-11-19T090422Z-inline-default/debug-tests.log), [release](../../evidence/2026-11-19T090422Z-inline-default/release-tests.log).
- Native Settings and panel profiles **Passed** on the signed release, zero stderr. The Settings check asserts initial segment 0; saved/external Right and Below choices still work. [Settings receipt](../../evidence/2026-11-19T090422Z-inline-default/settings/receipt.json), [panel receipt](../../evidence/2026-11-19T090422Z-inline-default/panel/receipt.json).
- Initial General and default-panel hidden renders inspected in light/dark: [General light](../../evidence/2026-11-19T090422Z-inline-default/settings/settings-general-light.jpg), [General dark](../../evidence/2026-11-19T090422Z-inline-default/settings/settings-general-dark.jpg), [panel light](../../evidence/2026-11-19T090422Z-inline-default/panel/size-3-light.jpg), [panel dark](../../evidence/2026-11-19T090422Z-inline-default/panel/size-3-dark.jpg).

Memory and observer measurements were not repeated for this default-only change. The previous 46.05 MiB memory result belongs to the [prior fingerprint](2026-11-19T085025Z-row-location.md). Live appearance, screen delivery and spoken VoiceOver retain their Untested status; hidden renders do not establish them.

## Identity and isolation

Base `87d171c72d2f635b4d3f719e1194d2311d25b509`, dirty UI tree. Release SHA-256 `d5b224f6427f19dd8fdd6160018d2827d97a4ccd34dab6afd04affb387b9b073`. New immutable review bundle: `build/review/2026-11-19-inline-default/Apparate.app`. [Build identity](../../evidence/2026-11-19T090422Z-inline-default/build-identity.json), [source manifest](../../evidence/2026-11-19T090422Z-inline-default/source-manifest.json), [debug build](../../evidence/2026-11-19T090422Z-inline-default/debug-build.log), [release build](../../evidence/2026-11-19T090422Z-inline-default/release-build.log), [assembly recipe](../../evidence/2026-11-19T090422Z-inline-default/assembly.txt), [signature check](../../evidence/2026-11-19T090422Z-inline-default/assembly.log). Builds succeeded with the existing Command Line Tools search-path warnings.

SwiftPM used the separate `/private/tmp/apparate-ui-build-20261119` path. Every app check passed an explicit `--binary` and used temporary homes, hidden windows, prohibited activation and fake effects. Receipts confirm zero native actions/hotkeys/protected-folder probes and completed cleanup. No build.sh, access to the running app, real user data or Claude's session folder, visible window, commit or push.
