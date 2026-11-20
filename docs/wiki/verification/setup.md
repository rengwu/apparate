---
title: Verification setup
section: Verification
updated: 2026-11-19
---
# Verification setup

Run from the Apparate project root on macOS 27 arm64 with Swift 6.4.2 Command Line Tools, Python 3 and Node.js 22+. There are no downloaded packages or runtime services. The executable Core harness is used because XCTest and Swift Testing are unavailable in this Command Line Tools installation.

## During the supervised session

Do not run `build.sh`, replace or launch `build/Apparate.app`, or touch Claude's session home while that app is in use. The UI follow-up uses `swift build --scratch-path /private/tmp/apparate-ui-build-20261119` (debug/release), with an independently assembled bundle under `build/review/2026-11-19-ui/Apparate.app`. The smoke and performance drivers accept `--binary <explicit executable>`; always pass that review executable in this session. Its resources come from the repository, never from the running bundle. Bundle assembly, identities, final commands and receipts are recorded in the [UI run](runs/2026-11-19T064952Z-ui.md). All profiles remain hidden with isolated temporary homes and fake global effects.

## Build and identity

```sh
swift --version
sw_vers
./build.sh
codesign --verify --deep --strict build/Apparate.app
codesign -d -r- build/Apparate.app
```

Expected: identifier `local.apparate`, version `0.1.0`, minimum system `27.0`, arm64 only, `LSUIElement` true, designated requirement `identifier "local.apparate"`. The bundle includes the three folder-purpose strings and fzy notice. `build.sh` removes the old bundle after successful compilation and before assembly. It signs/verifies but never launches or installs the app.

Read-only git status/diff/log are authorized in this project. M3 was reviewed and committed as `ef9f683`; its catalog follow-up was separately authorized for implementation and commit. The ignore oracle may initialize Git only inside its disposable fixture directories; no project git mutation is part of verification. Each run's input manifest identifies its package, build, source and test files. The catalog follow-up manifest is `docs/wiki/evidence/2026-11-18T191222Z-catalog/source-manifest.json`. Check it before relying on that run:

```sh
python3 - <<'PY'
import hashlib, json
from pathlib import Path
manifest = json.loads(Path('docs/wiki/evidence/2026-11-18T191222Z-catalog/source-manifest.json').read_text())
changed = [name for name, expected in manifest.items()
           if not Path(name).is_file() or hashlib.sha256(Path(name).read_bytes()).hexdigest() != expected]
assert not changed, 'Inputs differ: ' + ', '.join(changed)
print('Source manifest matches')
PY
```

M1 and M2 records remain immutable history; their reviewed trees are committed separately. Their fingerprints do not describe M3; M3 fingerprints likewise do not describe the catalog follow-up. Never overwrite their evidence with current results.

## Core correctness

```sh
swift run ApparateCoreTests
swift build -c release --product ApparateCoreTests
apparate_bin="$(swift build -c release --show-bin-path)"
"$apparate_bin/ApparateCoreTests"
```

The harness prints each group and a final count, and exits nonzero on failure. `APPARATE_TEST_FILTER=FSEvents` optionally selects groups containing that text for diagnosis; the final run must leave the filter unset. Fixtures use UUID temporary directories and synthetic bundle/config/search data, removed after each check. The default suite has no user-folder crawl, global shortcut registration, native open, clipboard access or system command. Its ignore oracle uses real Git in isolated fixture repositories; it never invokes Git in the project.

M1 coverage remains: matching/ranking/Unicode, config validation and actual vnode replacement events, usage persistence, and coordinated generation races. M2 adds app/settings fixtures, cache invalidation, real fixture-directory FSEvents, typed fake actions, exact URLs, selection/queued actions/Restart/composition, hotkey replacement and sequential access observations. Post-review cases also check one usage read per showing, modern Date & Time targets, invalidation of the old cache and no recursive parent watches or sibling-churn scans. Controlled continuations force asynchronous reads/scans to finish out of order; event tests await observable state.

## Isolated app profiles

**Use the driver for every unattended app run.** APPARATE_HOME by itself isolates persistence, not hotkeys, opens or privacy grants. The driver seeds an alternate shortcut before launch and sets APPARATE_TEST_MODE. The app validates that profile before creating adapters and uses fake actions, a fake global registrar and fake protected-folder probes. Invalid test setup quits before those effects can be installed. Native behavior belongs to the separate [supervised run](runs/2026-11-18T164001Z-m2-supervised.md).

```sh
python3 Tests/smoke-app.py
python3 Tests/smoke-app.py --show panel --query term --action-open --output /private/tmp/apparate-panel-check
python3 Tests/smoke-app.py --show setup --output /private/tmp/apparate-setup-check
python3 Tests/smoke-app.py --mode live-readonly --runs 2 --seconds 2 --output /private/tmp/apparate-cache-check
python3 Tests/smoke-app.py --mode live-readonly --seconds 60 --output /private/tmp/apparate-idle-check
```

Default mode is `fixtures`; `--render panel|setup` (with `--show` retained as an alias) is allowed only in that mode. Every automated profile now uses prohibited activation before creating a non-presenting window. Render checks never order a window, become key/main or activate the app; they render the owned view to PNG (panel) or JPEG (setup) without Screen Recording permission and quit. The panel check asserts unchanged actual rows/footer/empty label across three pending edits, and can execute one fake open after capture. The setup check supplies fake Allowed/Denied/Not found outcomes. A bitmap may differ from the screen's composited vibrancy; inspect it without claiming physical input or on-screen latency coverage.

`live-readonly` reads application metadata and system settings resources. With `--file-source projects`, it also indexes Projects read-only; Desktop/Documents/Downloads remain prohibited. `--file-source fixture` creates a temporary tree, and `--fixture-app` adds a synthetic app bundle. The app validates test roots before installing any adapters. It keeps windows hidden; native effects remain fake. Its receipt exports counts, timings and memory/CPU, never real item names/paths. `--runs 2` relaunches the app using the same isolated cache and requires the second launch’s first load to be a cache hit; earlier receipts appear under `previous_runs`. A disposable settings cache lives inside the test APPARATE_HOME and is removed with it.

Readiness requires the first complete attempt from both local catalogs, no reported errors and a receipt from the owned process. The driver validates fake registration/action counts, no native effects, optional image existence and nonempty live catalogs. It waits at most the requested duration plus 65 seconds, stops only its owned process if necessary, and removes only its created APPARATE_HOME. `--output` retains the sanitized receipt and optional image; remove only those chosen outputs after inspection or retain them as evidence. The production data folder is never used.

## Measurements

Final app measurements run without concurrent builds/tests. The 60-second hidden profile begins CPU accounting at the first complete catalog; CPU is process user+system time divided by elapsed monotonic time, expressed as a percentage of one core. Physical memory is `TASK_VM_INFO.phys_footprint`, not peak allocation. Record catalog publication/scan counts to identify unexpected activity. Record first app/settings scan time and the subsequent verifying scan separately; a fresh cache miss includes parsing and cache writing, a hit includes file read/decode. Do not label a hit as a fresh parse.

M4 replaces visible diagnostics with a dedicated hidden path. Earlier M2/M3 showing/transaction timings are historical and must not be relabeled as current presentation measurements. Current checks never call `makeKeyAndOrderFront`, activate the app or force `CATransaction.flush`. M6 and the supervised slot own actual display/global-key latency.

The unchanged M1 Core benchmark remains available:

```sh
apparate_bin="$(swift build -c release --show-bin-path)"
"$apparate_bin/ApparateCoreTests" --benchmark 20000 --rounds 3 > /private/tmp/apparate-20k.json
"$apparate_bin/ApparateCoreTests" --benchmark 200000 --rounds 3 > /private/tmp/apparate-200k.json
```

Its seeded synthetic corpus, query lists, checksums and timing boundary are described in the [M1 run](runs/2026-11-18T154000Z-m1.md#release-measurements). M2 does not change matching/ranking, so its correctness tests are retained without repeating those performance claims.

## Records and cleanup

Runs live in `verification/runs/`, evidence in `evidence/<run-id>/`. Preserve the bundle, reviewed inputs and evidence. Sanitized logs omit account/project-root prefixes. No TCC reset, user-app termination or cleanup of user files is part of verification.

```sh
node "$JSTACK/skills/verify-change/scripts/check-reports.mjs" docs/wiki
node docs/wiki/_build.mjs
node docs/wiki/_build.mjs --check
```

Set `JSTACK` to the reader's jstack checkout. These commands validate document structure, not product behavior.


## M3 files and persistence

```sh
python3 Tests/smoke-app.py --file-source fixture
python3 Tests/smoke-app.py --file-source fixture --show panel --query fixture-ledger --action-open
python3 Tests/smoke-app.py --file-source fixture --fixture-app --show panel --query 'Fixture Editor' --action-open
python3 Tests/smoke-app.py --mode live-readonly --file-source projects --runs 2
```

The driver owns its temporary root and database. It validates file counts, discovered app counts and the appropriate fake open adapter. On a second process, the file snapshot must load from SQLite. Reports export only counts, timings, flags and memory. Raw databases and user names are never copied into evidence. Paths to outputs can be supplied with `--output`; render checks remain fixture-only and non-presenting.

```sh
swift build -c release --product ApparateCoreTests
apparate_bin="$(swift build -c release --show-bin-path)"
"$apparate_bin/ApparateCoreTests" --file-benchmark synthetic > /private/tmp/apparate-m3-synthetic.json
"$apparate_bin/ApparateCoreTests" --file-benchmark projects > /private/tmp/apparate-m3-projects.json
"$apparate_bin/ApparateCoreTests" --file-idle > /private/tmp/apparate-m3-idle.json
```

Run these serially without other build/test/profile jobs. The synthetic reader supplies exactly 200,000 initial entries without creating that many disk files. Both modes persist and reload the actual SQLite representation. First crawl includes preparation; database read/decode and loaded-snapshot preparation are reported separately. Search parses queries before timing and includes top-50 selection/highlights, excluding UI/coordinator delivery. The synthetic mode retains old/updated snapshots, searches during a rebuild, exercises slot reuse, and samples footprint every 10 ms. The sampled peak is a lower bound, not an allocator trace.

The Projects mode reads metadata and ignore/app resources only; no user project is modified. The idle mode uses a real temporary directory, waits for initial readiness and settling, then observes 64 quiet seconds. Its mutation latency starts immediately before a fixture write and ends when the controller snapshot contains the entry (10 ms observation resolution). The test process and temporary directories are removed on completion.

For the M3 search-speed review, also run `"$apparate_bin/ApparateCoreTests" --file-comparison`. This reuses M1's generator and complete query lists. The first 240 app/settings names are treated as files, and 7,203 structural directories are included in both representations, for 207,203 identical entries. The actual crawler prepares the file snapshot; `SearchIndex` prepares the flat reference from the same child-batch-before-descent order. Every timed prefix first verifies complete row equality outside timing. Three measurements alternate engine order. The output includes the matched corpus hash, per-query samples and whether file-name p95 is within twice the flat reference. Run the unchanged `--benchmark 200000 --rounds 3` alongside it as the original mixed M1 baseline; do not label its different corpus as the matched comparison. These comparison processes retain both representations and are not memory measurements; use `--file-benchmark synthetic` for load/rebuild footprint.

## Catalog metadata churn

Use the full Core suite above, or `APPARATE_TEST_FILTER='catalog metadata churn' swift run ApparateCoreTests` to isolate the real event regression. It creates one owned bundle, applies xattr-only, timestamp-only and combined touches, waits for actual rescans and asserts zero metadata reads/publications. A later Info.plist edit must publish the new name. The `CATALOG_TOUCH_TRACE` line retains aggregate counts/flags only. Cleanup removes the fixture and stops its watcher.

For the signed application, run these serially, without a concurrent build, test or profile job:

```sh
python3 Tests/smoke-app.py --file-source fixture --fixture-app --seconds 2
python3 Tests/smoke-app.py --mode live-readonly --seconds 2 --runs 2
python3 Tests/smoke-app.py --mode live-readonly --seconds 60
```

These runs remain hidden; do not add `--show`. The driver seeds a disposable config, installs fake effects/hotkey/access adapters and deletes its temporary home after process exit. Live runs read only the fixed app/settings sources; these commands do not index user folders. Receipts include an observation-window event histogram, reuse/read/publication counters and CPU/footprint. Startup is excluded from the long observation by the existing one-second delay. No app names or event paths are recorded. See the [catalog follow-up run](runs/2026-11-18T191222Z-catalog.md) for interpretation limits.


## M4 panel checks and comparison

Run the signed app only through the driver, serially with no other build, test or profile job:

```sh
python3 Tests/smoke-app.py --panel-check functional --output /private/tmp/apparate-m4-functional
python3 Tests/smoke-app.py --panel-check measure --count 20000 --output /private/tmp/apparate-m4-20k
python3 Tests/smoke-app.py --panel-check measure --count 200000 --output /private/tmp/apparate-m4-200k
python3 Tests/smoke-app.py --panel-check measure --count 20000 --opaque --output /private/tmp/apparate-m4-opaque
python3 Tests/smoke-app.py --panel-check measure --count 20000 --no-warmup --output /private/tmp/apparate-m4-cold
python3 Tests/smoke-app.py --panel-check measure --count 20000 --wait-ms 4 --output /private/tmp/apparate-m4-wait
```

These modes require fixtures, one owned process, no ordinary `--render`/action options and no real file source. They build 20,000 or 200,000 entries through the production `FileCrawler`/`FileIndexSnapshot` using the unchanged M3 deterministic reader, plus nine synthetic catalog entries. This UI experiment does not open SQLite or enumerate a user folder. Symbols substitute for filesystem icons equally in all variants. The driver terminates only its owned child and removes its own temporary config/home. `--output` retains receipts, images and any failure record. The maximum process wait for these modes is 180 seconds; a timeout is a failure, not a discarded sample.

Each measurement process constructs a dark-appearance panel, optionally warms its empty frame once, then performs 30 hidden reset/layout/bitmap cycles. It records the first cycle separately and statistics for the remaining 29. Warm-up-off always means a separate fresh process. Footprints are endpoint `phys_footprint` readings after the index, after 30 cycles, and after typing; they are not peak memory measurements.

The post-review driver prepares the field editor once before timing (setup cost is reported separately) and reuses it, inserting only the changed suffix. Typing uses the owned native field editor at scheduled 40 ms cadence without waiting for each query. One phase records view-state completion without explicitly rasterizing. A separate matched phase explicitly rasterizes every typed letter and completed result; those captures themselves delay the main thread and must not be interpreted as natural presentation latency. A final 1 ms phase forces overlapping requests. Every event retains its deadline, delivery, text callback, worker timestamps, accepted revision, view-update cost, available raster timestamps, result hash and completed/superseded/timeout status. Missing intermediate results are never silently removed from the record. An untimed full-results oracle covers every query, including superseded ones. Corpus and expected-result hashes must agree across configurations.

`--delivery task|dispatch` compares the worker-to-main hop; `--no-activity` disables the per-showing user-initiated/latency-critical activity for comparison. Production keeps Task delivery and holds the activity until hide. Per-stage timing and worker CPU time are diagnostic-only observations. The public archive keeps compact receipts and one CSV event set; a fresh driver run still writes full records.

`--wait-ms 4` is a bounded test-only worker-readiness experiment. It waits at most four milliseconds on the main thread; it does not pump events, deliver the result synchronously or force a transaction. Production uses zero wait. `--opaque` removes the visual-effect view from the hierarchy; ordinary production keeps vibrancy unless Reduce Transparency is set. These hidden experiments cannot establish whether a wait removes visible flicker or what composited vibrancy costs.

The final product contains one renderer. The [M4 comparison source archive](../evidence/2026-11-18T200340Z-m4/comparison/sources.json) contains historical source overrides, including both candidates, shared behavior and the comparison driver. To reproduce the old two-renderer experiment, copy the post-review M4 sources into a separate disposable checkout, apply every entry in that path-to-source JSON over it, verify every file against its [manifest](../evidence/2026-11-18T200340Z-m4/comparison/source-manifest.json), build with `./build.sh`, and run the [archived serial runner](../evidence/2026-11-18T200340Z-m4/comparison/runner.py.txt) with an empty output directory. It alternates drawn/table order for three process pairs at each count. Do not overwrite the current working tree or original evidence. The [M4 run](runs/2026-11-18T200340Z-m4.md) states which measurements qualify which conclusions.

The [panel feature](../features/panel.md#supervised-recipes-untested) contains the explicit user-supervised focus, first-real-show, Spaces/full-screen, display-scale, input-method, VoiceOver and appearance recipes. They remain Untested until performed.

## M5 Settings, menu and setup

Build first with `./build.sh`. All commands below use a preseeded temporary home and are run serially. No native status item, main-menu installation, login registration/unregistration, System Settings launch, symbolichotkeys write, protected-folder read, visible window or activation is allowed in these automated profiles.

```sh
python3 Tests/smoke-app.py --settings-check --output /private/tmp/apparate-m5-settings
python3 Tests/smoke-app.py --render setup --output /private/tmp/apparate-m5-setup
python3 Tests/smoke-app.py --file-source fixture --fixture-app --render panel --query 'Fixture Editor' --action-open --output /private/tmp/apparate-m5-integration
python3 Tests/smoke-app.py --panel-check functional --output /private/tmp/apparate-m5-panel
```

`--settings-check` is a dedicated fixture profile: no file crawler, an empty initial root list and fake registration/login/access/picker/effect adapters. It constructs the actual toolbar, controls and closed menu graph. Native field editors receive direct Return/Esc and replacement text; no global input or menu tracking is synthesized. Preferences windows refuse presentation, key/main status and activation. The normal integration graph separately asserts hidden settings/setup/panel and zero native status items. Test profiles never construct NativeLoginService or the native protected-folder probe.

Inspect the twelve light/dark/state JPEG content renders and the receipt. Expected: Passed, no errors, focus guards checked, zero native actions/registrations/login changes/status items/probes/symbolichotkeys writes. The driver removes its own temporary home on both success and failure; `--output` is deliberately retained for inspection. Before a release, run the separate supervised recipes in [Settings](../features/settings.md#supervised-recipes-untested), [Menu bar](../features/menu.md#supervised-recipes-untested) and [First run](../features/first-run.md#supervised-recipes-untested), together with the earlier native checks. Test profiles remain development-only code until their M7 packaging exclusion.

The [M5 run](runs/2026-11-18T212428Z-m5.md) links its source/binary manifest, receipts, compact retained failures and renders. Its automated pass does not replace any native check or the open M6 latency gate.


## M6 hidden performance

Use `Tests/performance.py` with the signed app from `./build.sh`. It creates a temporary home, seeds an alternate fake shortcut before launch, runs with prohibited activation and non-presenting windows, and cleans up its owned process and files. No protected-folder read, global event, login change, status item or Screen Recording request is permitted. Output directories must be new so failed attempts remain intact.

```sh
./build.sh
python3 Tests/performance.py pipeline --count 200000 --output <new-evidence-directory>
python3 Tests/performance.py latency --count 20000 --output <new-evidence-directory>
python3 Tests/performance.py latency --count 20000 --probes --output <new-evidence-directory>
python3 Tests/performance.py latency --count 20000 --probes --bare --output <new-evidence-directory>
python3 Tests/performance.py latency --count 20000 --probes --delivery dispatch --output <new-evidence-directory>
python3 Tests/performance.py full --count 200000 --output <new-evidence-directory>
python3 Tests/performance.py full --projects --output <new-evidence-directory>
```

The matched pipeline uses the same compact snapshot, parsed query, empty usage snapshot and top-50 limit. Hashing and the independent reference run outside timing; the stage probe is a separate invocation. Native input uses a strict independent timer, 120 fixed 40 ms inputs plus 40 separately labelled 1 ms stress inputs. Every scheduled event remains in CSV, including superseded or timed-out events. It never waits for a result before scheduling another input. Five native marker raster checks run after timing; no raster or forced transaction is in the timing path. Repeat each native workload twice at each size; reverse control order for the second pass. Completed-only percentiles are conditional, not budget passes.

`full` first creates an actual 20,000/200,000-entry temporary filesystem corpus, builds the persisted SQLite index in a preparation process, then starts a fresh measured process with the full AppDelegate graph. The generator is outside the app and retains no in-app corpus. Real app/settings catalogs, config/file/catalog watchers, retained preferences/setup, and real usage/index stores remain; global effects are fake and usage history is empty. Projects is read-only; receipts contain counts only. Readiness is bounded before timing. Footprint is recorded after load, 120 inputs, hidden preference layout, and rebuild. The requested 25 ms sampled peak is a lower bound with actual gap statistics. The sampler is stopped before at least 64 quiet seconds, without polling or latency activity. Report the first interval even if busy, then repeat it once. Metric failure is unavailable/Failed, never zero. A Passed receipt validates the harness and isolation, not the provisional budgets.

Observer and decoder checks do not use Screen Recording:

```sh
swift run -c release ApparateObserver --self-test
python3 Tests/observe-performance.py --self-test
```

The external observer's explicit capture mode targets only an exact PID/window ID whose bundle is Apparate, uses a desktop-independent window filter, preflights its actual launch identity without prompting, bounds duration and saves metadata/markers only. Its separate offline correlator checks run/show/revision/digest and input deadlines; stale, duplicate, out-of-order or absent frames cannot become a completed-only pass. Live scale/content-rectangle calibration and vibrancy composition remain unverified. A desktop-independent window may not prove the live backdrop; bring the alternative to Claude before changing capture scope.

**DEC-049:** do not run capture or present the panel until Claude sends an explicit “on-screen window open” after the user says they are away. The visible callback driver and its own key-window watchdog must be connected and validated in that stage; another application's frontmost status does not prove a nonactivating panel lost the key window. Then pair capture-on/off timings, inspect actual refresh/frame gaps, use fresh processes for cold shows and run the agreed opaque/vibrancy pair. Physical-key delivery remains a separate supervised observation. Hidden results cannot close these gates.

## Direct paths and shallow-root verification

Section 5’s Core checks use injected readers or temporary fixture homes/root trees; never use `/`, `~` or protected user folders for automated browsing. The native panel functional profile supplies a synthetic filesystem and drives Tab, undo, marked-text guards, error states and fake filesystem actions. Production test profiles restrict direct path reads to their own disposable APPARATE_HOME.

Run the isolated release `ApparateCoreTests --shallow-idle` for a 64-second watcher observation while its own separate child process churns a deeper fixture subtree. The writer’s CPU is excluded. Expect zero watcher batches, scans, updates and publications, then an immediate-child change must become searchable. Process wakeups still include the harness’s two waits; they are reported separately from filesystem events. No build or other test may run concurrently with a measurement. Full-app hidden idle remains a separate regression check.


## Dot-entry measurements

For DEC-055, use `Tests/performance.py --binary <isolated-review-executable> full --count 20000 --dot-entries --output <new-evidence-directory>`, repeat at 200000, and run `pipeline --count 200000 --dot-entries` with the same explicit binary. The 500-project corpus creates six dot entries per project, 50 ignored `.env` files and 1,500 child sentinels inside terminal dot directories. Expected retained counts are the requested total, including 2,950 dot entries; only 501 directories are listed. A small Core fixture checks the ignore switch and refuses any sentinel-directory enumeration. These are deterministic synthetic corpora, not a measured sample of the user's files.

The pipeline retains the original 20-query set and adds ten dot-name/path/control queries, six repetitions in each timing order. Receipts split the original and added query sets and check production/reference hashes. Use a separate plain-corpus run for comparison with a prior binary; document that its corpus differs from the dot-inclusive run. Full graph memory includes load, typing, preferences, rebuild endpoint and sampled rebuild peak. The sampled peak is a lower bound; a valid harness receipt does not imply the memory budgets passed. Keep every measurement sequential, with no concurrent builds/tests, and preserve original fingerprints.


## Completing the selected result

For DEC-056, run the full debug/release Core suites and `python3 Tests/smoke-app.py --binary <isolated-review-executable> --panel-check functional --output <new-evidence-directory>`. The `result_completion` receipt exercises ordinary/scoped folder selections, a Unicode file, app, setting and command; before/after light/dark renders show the resulting query and rows. Folder completion must list the selected folder's contents, files abbreviate home, and names preserve scope prefixes.

The owned hidden native editor receives actual `insertTab:`, `insertBacktab:`, `undo:` and `redo:` commands. Tests assert the same editor, caret at the end, no activation, and exact text/results restoration. Fixture input history is cleared before each completion to isolate that native undo action; this does not prove physical key-event grouping. No-op cases cover identical text, no selection, web, pending results, unreconciled editor text and marked text. Physical keyboard, actual input-method handling and presentation remain supervised/Untested. Use synthetic readers only, and keep the running app and real data isolated as above.


## Open With checks

For DEC-057, run both complete Core suites, then `python3 Tests/smoke-app.py --binary <isolated-review-executable> --panel-check functional --output <new-panel-directory>` and the corresponding `--settings-check` profile in a separate new directory. Every app command must pass the explicit isolated binary during the supervised session. All lookup/open effects use injected fakes. Core covers the same worker orchestration with fake Workspace and app metadata readers, canonical/lexical access gates, ordering, missing remembered apps, stale generations, Back, config conflicts and schema-2 migration/reopen/eviction while preserving usage/file data.

The native panel sends constructed key events only to its owned hidden NSPanel (`sendEvent`), which tests the local default/custom trigger route; it does not synthesize global input. It then drives native text/command routing, checks list order/labels, literal Unicode filtering, Back, mode no-ops, numbered/Return/click actions, folders, empty apps and marked triggers. Settings records the key through its real recorder handler and asserts no extra global registration. Inspect final light/dark list/filter/empty/General/error/recording JPEGs and retain identity/receipts before cleanup. Actual physical keys, input methods, macOS handler discovery and real file opening are Untested until a supervised slot; no such slot is authorized by this recipe.


## Right Arrow folder completion

For DEC-058, run both complete Core suites and the signed hidden `--panel-check functional` profile with an explicit isolated `--binary`. The `right_folder_completion` receipt checks ordinary/scoped/direct-path/Unicode folders, native undo/redo and the same field editor with a caret at the UTF-16 end. An owned Right key event carrying normal function/numeric-pad flags exercises the panel-to-editor route; other cases use native command selectors. No global input is injected.

Fallthrough checks compare actual caret ranges for middle-of-text movement, selection collapse, Shift/Option/Command-Right, file/app/setting/command/web rows, pending/no-selection/editor-model mismatch and Open With. Marked text checks that the delegate returns control without changing composition; a real IME is not exercised. Completion history is isolated by clearing fixture input history before each action, so physical key-event grouping remains untested. Final light/dark before/after renders use synthetic readers only. Keep the running app/data isolated and retain the new binary/manifest/receipt independently of the section-8 run.

## Login availability and app icon

For UI section 10, run the full debug/release Core suites and hidden Settings profile with an explicit isolated binary. The fixture starts at ServiceManagement's `.notFound` status and shares the native adapter's pure mapping, without constructing a real login service. Toggle the native switch on/off and refuse a second registration from not found. Assert the observed state, switch enabled/on state and visible inline error; also retain approval-pending cancellation and unsupported-run coverage. No real registration or Login Items change is part of this recipe.

Assemble a fresh signed review bundle with `Resources/AppIcon.icns` copied into `Contents/Resources` and `CFBundleIconFile` set to `AppIcon`. Verify the bundled icon hash matches the source and run `codesign --verify --deep --strict`. The section-10 mailbox explicitly authorizes `./build.sh` after checks pass because the running app is now a separate copy under `/Applications`; that copy and real data remain untouched. Record and verify the resulting build bundle without launching it. Finder/Dock appearance and actual login behavior remain supervised checks.

## Below-layout icon checks

Section 11 adds `larger_below_icons` to the hidden panel profile. An owned vector fixture passes through the production rasterizer to produce 40/64-pixel PNGs. A controlled asynchronous loader tests a loaded small icon switching to a cold large request, late small results after a switch to Below, late large results after a switch away, and warm switches through every layout. Check row images immediately and after callbacks, native point sizes, pixel dimensions, and size-separated cache reuse. No Workspace icon lookup occurs in this functional profile.

Inspect Below mixed app/file/folder/setting/command rows at 1/3/9 results, plus a web row, in light/dark. Verify 32-point frames, x = 50 aligned text, unchanged vertical text/hints and 122/202/442 panel heights. Existing layout checks retain long-title/location truncation, selection, hit testing, numbered actions, pending reflow and accessibility geometry. Compare the new raw Inline/Right images against the preceding run's original hashes.

The performance driver accepts `--result-location below` and records it in the identity; the app records the active layout and point/raster sizes. Use `full --count 20000 --dot-entries --result-location below` with an explicit isolated binary for comparison against section 6. This profile reads installed-app/settings metadata and uses native file icons, while actions/global effects remain fake and file/config/index data stay in its disposable home. Respect any active restriction on reading installed apps before using this profile. Keep measurements sequential, with no concurrent builds or tests, and distinguish prior historical values from a matched comparison.


## Skip hidden files checks

For DEC-059, run full debug/release Core suites with the isolated scratch executable. `hidden:` scenarios cover default-on/missing-key and bad-value config, expected-value conflicts/write refusal, skipped dot metadata/apps, Finder-hidden non-dot entries, overlapping explicit dot roots, failed-listing policy changes, persistence, create/rename/rule edits, rule-5 migration and exactly one rebuild per toggle. A real FSEvents fixture checks ordinary children and `.gitignore` changes inside an explicit dot root. Direct-path fixtures retain the original final-name-dot filter with either switch value.

Use the hidden Settings profile with an explicit review executable. Its `skip_hidden_files` receipt checks the native on/off action, persisted value, stale displayed-value conflict, external refresh, same-card placement and accessibility label; broken config must disable the switch. Inspect light/dark on/off Folders images, including scroll and validation regressions. The existing panel profile retains section-6 dot-name behavior with the fixture config explicitly off.

The performance driver now explicitly writes `skipHiddenFiles: false` and records it in the run identity, so established dot-inclusive corpus counts remain comparable. Run `pipeline --count 200000 --dot-entries` sequentially with prior and candidate isolated binaries and compare every query/repetition digest. This synthetic pipeline does not read installed-app catalogs; it does not qualify full-app memory. The section-11 read-only installed-app restriction has been clarified and its matched full-profile comparison completed; installed-app mutation/launch/quit remains prohibited.


## Tight path alignment checks

DEC-060 uses `tight paths:` Core groups for usage crossover (0/1/2/5/20 opens), interior/trailing gaps, free leading ancestors, shared cap across both gap kinds, repeated/fuzzy alignment alternatives and top-50 cutoff. The 160-case independent oracle enumerates all ancestor alignments and computes actual interior/trailing gaps, instead of using the production first-match formula. Compact and regular complete rows must agree.

Run the signed hidden panel functional profile. `tight_path_ranking` records two `apparate/build` rows with one and five deeper-folder opens, text scores/usage/highlights and light/dark images. All readers/icons are fixtures. Existing direct-path, completion, layout and Settings checks remain.

Run `pipeline --count 200000 --dot-entries` sequentially with explicit prior/candidate binaries. Compare every non-path digest byte-for-byte and report per-query path pipeline p95, including section 6's preserved same-corpus CSV. Path scores may intentionally differ, so do not require cross-version path digests to remain equal. Each production/reference comparison must still pass. Note the twelve samples per individual query, historical fingerprint/catalog differences where applicable, and the absence of an end-to-end presentation measurement.

## Single indexing indicator checks

For UI section 14, run both complete Core suites and the hidden Settings profile with an explicit isolated executable. The Core retry fixture covers retained denied/missing/unavailable/waiting states, aggregate progress, repeated failure and successful recovery. Native `indexing_indicator` checks the spinner style, size and accessibility label; no per-row indexing text; the 8-point gap and vertical centering; and exact content-coordinate frame equality for folder rows, action buttons, both following cards and the window content. Compare indexed/all-indexing, mixed-error idle/indexing and waiting idle/indexing pairs; progressing ready roots must retain their existing controls.

Toggle each native Skip switch on and off, with the fixture config callback publishing indexing immediately. Check the same frames and Rebuild state after each action. Retain light/dark idle, all-indexing, mixed idle and mixed indexing images. The hidden spinner uses its stopped native glyph; the harness never presents a window or starts visible animation. Animation and spoken VoiceOver require the supervised session. Run the existing signed panel profile as a regression check, then assemble/verify the authorized local build without launching it.
