---
title: System Settings items
section: Features
updated: 2026-11-19
---
# System Settings items

**FEAT-settings-items.** Search panes and individual settings using macOS's localized search resources, as specified by the [M2 guide](../build/m2-sources-actions-panel.md#2-settings-catalog) and [deep-link spike](../spikes/2026-11-18-settings-deep-links.md).

## Entry points and prerequisites

`SettingsSource.scan` reads `.appex` metadata in `/System/Library/ExtensionKit/Extensions`. Eligible extensions declare `EXAppExtensionAttributes.SettingsExtensionAttributes.searchTermsFileName`. The app performs discovery off MainActor before publishing the combined catalog.

## Expected outcomes

Each pane and each titled search-term record becomes an item with a typed bundle/anchor target. Comma-separated index terms feed the keyword tier. Duplicate IDs merge keywords deterministically. Malformed records/resources are counted; valid panes and other records remain available.

Localization uses `Bundle.preferredLocalizations(from:forPreferences:)` with an explicit English fallback. Exactly one resource localization is read per pane. Pane display names use localized bundle metadata. Battery and Headphones have fixed user-facing names and the System Settings icon; other panes use their bundle icon. When an extension declares `legacyPrefPaneBundleName`, the loader first checks the extension’s own resource. If it has no matching or English terms file, the loader falls back to `/System/Library/PreferencePanes/<name>/Contents/Resources/`. Several modern extensions still declare retired legacy panes. Display name, icon and action target always belong to the modern extension. Date & Time appears once and targets `com.apple.Date-Time-Settings.extension`; there is no separate legacy scan or hard-coded English pane name.

Opening sends `x-apple.systempreferences:<bundle>?<anchor>` directly, without quitting System Settings. URL acceptance is not evidence that the intended row or sheet opened. The [actions feature](actions.md) owns dispatch and failure reporting.

## Verification recipe

Run the shared [correctness checks](../verification/setup.md). Temporary `.appex` fixtures verify pane items, entries, keywords, regional language matching, English fallback, duplicate merging, malformed records, both overrides and modern Date & Time targets with legacy resources. No System Settings URL is opened.

The read-only app profile records catalog size and parsing time without publishing real titles. The [supervised run](../verification/runs/2026-11-18T164001Z-m2-supervised.md) separately checks direct opening with System Settings both closed and already running; this recipe is unvalidated until a user performs it.

## Coverage and limitations

Resource discovery and typed URLs are automated. macOS may change these undocumented resources and private deep links. Individual navigation behavior, sheets, live locale changes and user-specific pane visibility are not certified by a successful scan. Parsing exceeded the guide’s few-millisecond threshold, so M2 stores a disposable JSON cache in APPARATE_HOME. Its schema version (now 2), macOS build and ordered preferred languages must match. Version 1 is discarded so pre-review legacy targets cannot survive in the cache. Corrupt, duplicate or mismatched records fall back to parsing; cache write failure keeps the parsed catalog usable. Cache round-trip, OS/language/schema invalidation, corruption and write failure are covered by fixtures. The automated run records uncached and cached costs.

## Verification history

- [M2 automated verification](../verification/runs/2026-11-18T164000Z-m2.md).
