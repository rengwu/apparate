---
title: Folder access
section: Features
updated: 2026-11-19
---
# Folder access

**FEAT-access.** Let the user explicitly check Desktop, Documents and Downloads before protected-folder discovery. Basis: [M2 access guide](../build/m2-sources-actions-panel.md#6-access-step) and the accepted no-launch-probe contract. M5 supplies [first-run setup](first-run.md) and a conditional retry in [Settings](settings.md).

## Entry points and prerequisites

The Set up Apparate window appears when config is first created, or with `APPARATE_SHOW=setup`. Its **Allow Access…** button starts `FolderAccessController.check`. Only that explicit request performs protected-folder reads in production. The signed bundle includes the three plain folder usage descriptions. `APPARATE_HOME` redirects app persistence; it does not isolate macOS privacy grants.

## Expected outcomes

Probes read one folder at a time off MainActor, keeping the window responsive. Outcomes distinguish Allowed, Denied, Not found and Could not check. The button is disabled during the sequence and repeated requests cannot overlap. Status changes appear beside each folder.

Observations and dates persist atomically to `access.json`, apart from config. Reopening shows them as **Last check** hints. Loading hints never probes or claims that a previous grant is still valid. Persistence failure is reported. No TCC reset or automatic re-prompt is performed.

## Verification recipe

Follow [setup](../verification/setup.md). Core tests use sequential delayed fake probes to exercise mixed statuses, duplicate requests, persistence/reopening, other errors and save failure. Real probe code reads only synthetic temporary fixtures for allowed, missing and non-directory cases. No protected user folder is read.

`python3 Tests/smoke-app.py --show setup --seconds 2 --output /private/tmp/apparate-access-check` renders a hidden fixture content view with Allowed/Denied/Not found states and quits. Remove that output after inspection. This exercises display and fake-check wiring without changing privacy decisions.

## Coverage and limitations

Native prompt behavior, denial/retry and grant survival after rebuilding cannot be inferred from fake probes or code signing. The normally launched signed app and actual user decisions are required. See the separate [supervised run](../verification/runs/2026-11-18T164001Z-m2-supervised.md); these recipes are unvalidated and must pass before M7 release. No file crawl is part of M2.

## Verification history

- [M2 automated verification](../verification/runs/2026-11-18T164000Z-m2.md).

## M3 integration

M3 consumes Allowed observations as a gate for automatic protected-folder reads, including protected children reached from an ancestor root. Denied/not-found/error hints wait for an explicit retry. Completion of the access step retries indexing even when the saved Allowed status was already present.

- [M3 verification](../verification/runs/2026-11-18T181500Z-m3.md).

**2026-11-19 gate update:** Claude moved the pending native checks to the M7 release gate in the [M5 guide](../build/m5-settings-menu-first-run.md). Their recorded outcomes remain unchanged.

## M5 integration

Focus refresh never probes. Closing setup or Settings cancels the remaining sequential checks, while any in-flight probe may finish and persist its observation. The conditional Folders retry appears for configured protected roots with no Allowed hint or a denied/waiting current status. [M5 verification](../verification/runs/2026-11-18T212428Z-m5.md).
