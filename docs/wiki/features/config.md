---
title: Config
section: Features
updated: 2026-11-20
---
# Config

**FEAT-config.** Keep settings editable and persistent while a malformed external edit leaves the last valid settings active. The schema and behavior follow the [M1 guide](../build/m1-foundation.md#3-config) and [DEC-003](../decisions.md#round-1-2026-11-18).

## Entry points and prerequisites

The app resolves `APPARATE_HOME` when nonempty, otherwise its Application Support folder, and creates `ConfigStore(directory:)`. Development runs must supply an isolated temporary `APPARATE_HOME`. The store owns `config.json`, offers `current`, `errors`, `save` and `onChange`, and runs on MainActor. `ConfigStore.decode` validates supplied JSON without filesystem access. [Settings](settings.md) applies validated, field-level updates against fresh disk state.

## Expected outcomes

- Missing `config.json` creates version-1 defaults. Missing keys receive defaults; unknown keys are ignored. Explicit null and wrong value types are invalid. Launch-at-login state is not in this file.
- The whole document is accepted or rejected. Broken JSON or a type error produces one error; structurally valid documents collect all value errors. A failure preserves the last valid config (defaults at first launch) and never overwrites the bad file. `save` also refuses to overwrite an existing broken or newer-version file.
- Prefixes must be unique single symbols for known scopes, with no letters, digits, whitespace/control characters, `/` or `~`. Folder paths must be absolute after tilde expansion, lexically distinct, with depth 1–30. Validation does not check whether a folder exists. Search URLs require exactly one `{query}`, an HTTP(S) scheme and a nonempty host after sample substitution.
- Saving is atomic, sorted and pretty-printed. File and directory vnode sources catch in-place writes, atomic replacement and deletion. Replacement rearms the file watch. Deleting the file recreates defaults. There is no polling.
- An unchanged valid reload does not notify again. Fixing an invalid file clears errors and notifies even when its config equals the last valid value. Own saves produce no reload loop. The app logs config errors and retains the latest config error for the M5 settings view, clearing it after valid recovery. Background config/catalog/usage errors do not show modal alerts.

The optional version-1 key `resultLocation` accepts `"inline"`, `"right"` or `"below"`; omission defaults to `"inline"`. Unknown choices, null and wrong types reject the document and keep the last valid config. Settings uses the same expected-value transaction as other saved preferences.

Defaults include Command-Space, a visible menu-bar icon, Projects, Desktop, Documents and Downloads at depth 10, followed by `~` and `/` at depth 1, `.gitignore` handling and hidden-file skipping enabled, and the DuckDuckGo URL template. M2 applies the hotkey, scopes and web template; M3 applies folder settings and M5 adds the menu-bar control. Test profiles replace native effects with fakes.

## Verification recipe

Use [setup](../verification/setup.md), then `swift run ApparateCoreTests`. Config scenarios create a fresh directory, inspect the actual file, save and reopen it, supply invalid documents, and perform real in-place writes, atomic replacements and deletion. The watcher tests await observable notifications rather than calling reload for those events. They also restore the same valid settings after an error and check that own saves settle without repeated notifications.

After `./build.sh`, run `python3 Tests/smoke-app.py`. The M2 driver pre-seeds an alternate shortcut in a fresh `APPARATE_HOME`, installs fake effects and waits for a complete fixture catalog. It validates the receipt, quits the owned process and removes its folder. Default mode shows no window. Core tests still verify default config creation without installing a global shortcut.

## Coverage and limits

Covered: first launch, defaults, semantic/type errors, future version, last-valid preservation, atomic serialization, real vnode notifications and recovery. M5 adds transactional settings/UI and injected write-failure checks; real folder-permission write failures remain outside that coverage. The smoke helper verifies startup/config integration; optional fixture windows do not prove physical input or native effects.

## Verification history

- [M1 build verification](../verification/runs/2026-11-18T154000Z-m1.md) — exact build, observed outcomes and evidence; Claude's review passed and the packaging fix is verified in the post-review note.

- [M2 automated verification](../verification/runs/2026-11-18T164000Z-m2.md) — config applied to the session and safely replaced hotkey; M1 correctness groups retained.

## M3 integration

M3 applies folder/depth/ignore changes to file indexing; removing a root hides its solely owned results immediately and invalidates older load/crawl work. Explicitly configured home roots are supported; missing roots never widen into recursive home watches.

- [M3 verification](../verification/runs/2026-11-18T181500Z-m3.md).

## M5 integration

Settings commits text on Return/end editing, switches immediately, and preserves unrelated external changes. A same-field conflict is rejected; a broken file is never overwritten. Hotkey registration, persistence and rollback are coordinated through the same save boundary. [M5 verification](../verification/runs/2026-11-18T212428Z-m5.md).

- [Result-location setting verification](../verification/runs/2026-11-19T085025Z-row-location.md) — backward-compatible default, round trips, rejected choices, field conflicts and injected write failure.

- [Inline-default follow-up](../verification/runs/2026-11-19T090422Z-inline-default.md) — DEC-053 round 15 changes the missing-key/new-config default to Inline; explicit saved choices remain intact.

DEC-054 adds the shallow home/root defaults only when the folder list is omitted or newly created. An existing explicit list, including an empty list, is unchanged. [Path/folder verification](../verification/runs/2026-11-19T095817Z-path-folders.md).


## Open With key

Optional version-1 `openWithKey` uses `{ "keyCode": 36, "modifiers": 512, "display": "⇧↩" }` by default. The modifier bit mask follows the existing Carbon representation, though this key is handled locally by the panel. A modifier is required; Shift-only printable keys, invalid key/mask values, the launcher key, panel navigation/actions and native editing conflicts are rejected. Both keys are checked together, including external edits and attempted launcher changes. The existing whole-document rejection and expected-value save behavior apply. See [Settings](settings.md#open-with-shortcut).


[Open With verification](../verification/runs/2026-11-19T123000Z-open-with.md) — DEC-057 shortcut, app groups, Back, success-only history and hidden native checks.


## Skip hidden files

Optional version-1 `skipHiddenFiles` is Boolean and defaults to `true`, including configs written before DEC-059 that omit it. Null, strings and numbers reject the document. The Folders switch uses the displayed value as its expected value when saving; unrelated external edits survive, same-field conflicts are rejected, and broken config stays untouched. Changing this setting changes the file-rule signature and rebuilds the index once. See [file indexing](file-index.md#skip-hidden-files) and [verification](../verification/runs/2026-11-20T113654Z-skip-hidden.md).
