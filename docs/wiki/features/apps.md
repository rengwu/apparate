---
title: Applications
section: Features
updated: 2026-11-19
---
# Applications

**FEAT-apps.** Find installed applications by their displayed names and aliases, following the [M2 guide](../build/m2-sources-actions-panel.md#1-apps).

## Entry points and prerequisites

`AppSource.scan` reads bundle metadata, never loads executables. `CatalogController.start` installs the watch before asynchronous discovery. Production roots are `/Applications`, `/Applications/Utilities`, `/System/Applications`, `/System/Applications/Utilities`, `/System/Library/CoreServices/Applications` and `~/Applications`, plus Finder explicitly. There is no user-added app-folder setting; M3 also discovers apps inside indexed folders ([DEC-041](../decisions.md#round-6-2026-11-19)).

## Expected outcomes

- Scan direct children and one plain subfolder level. Never recurse inside an application; follow application symlinks and deduplicate by resolved path.
- Prefer a localized display name, then bundle name, then filename. Raw filename and internal bundle name are searchable alternates. Targets and icons use the canonical bundle path.
- Publish complete immutable catalogs containing both the prepared search index and typed targets. Scans run off MainActor. Directory-read failure retains the preceding snapshot and reports an error; malformed individual bundles are counted and skipped.
- Watch application roots and external target bundles with folder-level FSEvents; overlapping roots are collapsed. Capture an FSEvents boundary before registering; coalesce events, discard stale scans, and verify after installing watches for newly discovered targets. Dropped/root-change events and watch failures cause a full rescan. Missing roots use non-recursive vnode watches on their nearest existing parent, checking only whether the missing chain changed. Creating a direct sibling does not rescan; descendant-folder churn does not wake this source. An empty newly created app root switches to FSEvents before its first application arrives. The home directory is never an FSEvents root.
- Reuse app metadata across scans when canonical bundle identity, Info.plist, localization resources and language preferences are unchanged. Bundle directory timestamp/xattr touches do not invalidate those entries. Resource stamps include device/inode, mode, size and nanosecond modification/change times; localization directory listings are reused while their stamps match. A valid selected InfoPlist.strings dictionary is the sole localized-name dependency. Missing/malformed selected strings retain conservative checks of all fallback translations, matching the existing reader. Failed reads bypass reuse, and removed bundles leave the cache.
- Reuse the prepared catalog and the settings metadata in memory; settings remain keyed by OS build and preferred languages. Publish only when entries, targets, locations or icon references differ. Watching and verification scans still happen when their paths change, even if no publication is needed. Aggregate diagnostics record event counts/flags and reuse counts only.
- A confirmed missing action target is removed from the current snapshot and triggers a refresh. An ordinary launch failure leaves the item available.

## Verification recipe

Follow [setup](../verification/setup.md). `swift run ApparateCoreTests` creates temporary bundles and checks localization, alternates, nesting, links, deduplication and removal. Controlled loaders test changes during scans, coalescing, failed reads and watch recovery. A missing-root fixture asserts no recursive parent watch, no scans for sibling-cache churn or direct sibling creation, and correct transition when the root appears. The FSEvents scenario edits an external linked bundle, creates another application and removes it, awaiting actual catalog updates. Additional regressions mutate bundle xattrs/timestamps and require actual events, metadata reuse and no publication, then edit Info.plist and require the changed name. Localization edits with restored mtimes, language addition/removal, locale changes, malformed resources, replacements and retargeted aliases invalidate the cache. All fixtures are deleted afterward.

`python3 Tests/smoke-app.py --mode live-readonly --seconds 60` reads installed application metadata and settings resources, keeps the panel hidden and records counts/timings only. Every native effect is replaced by a fake adapter. Do not export real names or paths.

## Coverage and limitations

Automated coverage includes fixture sources, actual fixture-directory FSEvents and live read-only discovery. Native launch acceptance is a separate [supervised check](../verification/runs/2026-11-18T164001Z-m2-supervised.md), currently unvalidated. A successful catalog scan does not prove an application can launch.

## Verification history

- [M2 automated verification](../verification/runs/2026-11-18T164000Z-m2.md).

## M3 integration

M3 also discovers .app packages inside indexed folders (DEC-041). They use the shared bundle metadata reader, rank/open as apps, remain terminal packages, and deduplicate against fixed-source app IDs. No separate user-added app-folder setting is introduced. See [file index](file-index.md).

- [M3 verification](../verification/runs/2026-11-18T181500Z-m3.md).

- [Catalog reuse follow-up](../verification/runs/2026-11-18T191222Z-catalog.md) — event traces, unchanged-publication regression and hidden-app measurements.
