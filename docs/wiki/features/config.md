---
title: Config
section: Features
updated: 2026-11-19
---
# Config

**FEAT-config.** Keep settings editable and persistent while a malformed external edit leaves the last valid settings active. The schema and behavior follow the [M1 guide](../build/m1-foundation.md#3-config) and [DEC-003](../decisions.md#round-1-2026-11-18).

## Entry points and prerequisites

The app resolves `APPARATE_HOME` when nonempty, otherwise its Application Support folder, and creates `ConfigStore(directory:)`. Development runs must supply an isolated temporary `APPARATE_HOME`. The store owns `config.json`, offers `current`, `errors`, `save` and `onChange`, and runs on MainActor. `ConfigStore.decode` validates supplied JSON without filesystem access. The eventual settings window is not built yet.

## Expected outcomes

- Missing `config.json` creates version-1 defaults. Missing keys receive defaults; unknown keys are ignored. Explicit null and wrong value types are invalid. Launch-at-login state is not in this file.
- The whole document is accepted or rejected. Broken JSON or a type error produces one error; structurally valid documents collect all value errors. A failure preserves the last valid config (defaults at first launch) and never overwrites the bad file. `save` also refuses to overwrite an existing broken or newer-version file.
- Prefixes must be unique single symbols for known scopes, with no letters, digits, whitespace/control characters, `/` or `~`. Folder paths must be absolute after tilde expansion, lexically distinct, with depth 1–30. Validation does not check whether a folder exists. Search URLs require exactly one `{query}`, an HTTP(S) scheme and a nonempty host after sample substitution.
- Saving is atomic, sorted and pretty-printed. File and directory vnode sources catch in-place writes, atomic replacement and deletion. Replacement rearms the file watch. Deleting the file recreates defaults. There is no polling.
- An unchanged valid reload does not notify again. Fixing an invalid file clears errors and notifies even when its config equals the last valid value. Own saves produce no reload loop. The app logs config errors and retains the latest config error for the future M5 settings view, clearing it after valid recovery. Background config/catalog/usage errors do not show modal alerts.

Defaults include Command-Space, a visible menu-bar icon, four home-relative roots at depth 10, `.gitignore` handling enabled, and the DuckDuckGo URL template. M2 applies the hotkey, scopes and web template; menu-bar controls and the filesystem crawl arrive later. Test profiles replace native effects with fakes.

## Verification recipe

Use [setup](../verification/setup.md), then `swift run ApparateCoreTests`. Config scenarios create a fresh directory, inspect the actual file, save and reopen it, supply invalid documents, and perform real in-place writes, atomic replacements and deletion. The watcher tests await observable notifications rather than calling reload for those events. They also restore the same valid settings after an error and check that own saves settle without repeated notifications.

After `./build.sh`, run `python3 Tests/smoke-app.py`. The M2 driver pre-seeds an alternate shortcut in a fresh `APPARATE_HOME`, installs fake effects and waits for a complete fixture catalog. It validates the receipt, quits the owned process and removes its folder. Default mode shows no window. Core tests still verify default config creation without installing a global shortcut.

## Coverage and limits

Covered: first launch, defaults, semantic/type errors, future version, last-valid preservation, atomic serialization, real vnode notifications and recovery. Uncovered in M1: the future settings UI and write failures caused by real user folder permissions. The smoke helper verifies startup/config integration; optional fixture windows do not prove physical input or native effects.

## Verification history

- [M1 build verification](../verification/runs/2026-11-18T154000Z-m1.md) — exact build, observed outcomes and evidence; Claude's review passed and the packaging fix is verified in the post-review note.

- [M2 automated verification](../verification/runs/2026-11-18T164000Z-m2.md) — config applied to the session and safely replaced hotkey; M1 correctness groups retained.
