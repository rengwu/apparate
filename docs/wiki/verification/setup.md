---
title: Verification setup
section: Verification
updated: 2026-11-19
---
# Verification setup

Run from the Apparate project root on macOS 27 arm64 with Swift 6.4.2 Command Line Tools, Python 3 and Node.js 22+. There are no downloaded packages or runtime services. The executable Core harness is used because XCTest and Swift Testing are unavailable in this Command Line Tools installation.

## Build and identity

```sh
swift --version
sw_vers
./build.sh
codesign --verify --deep --strict build/Apparate.app
codesign -d -r- build/Apparate.app
```

Expected: identifier `local.apparate`, version `0.1.0`, minimum system `27.0`, arm64 only, `LSUIElement` true, designated requirement `identifier "local.apparate"`. The bundle includes the three folder-purpose strings and fzy notice. `build.sh` removes the old bundle after successful compilation and before assembly. It signs/verifies but never launches or installs the app.

Read-only git status/diff/log are authorized in this project. M3’s commit waits for independent review. The ignore oracle may initialize Git only inside its disposable fixture directories; no project git mutation is part of verification. Each run's input manifest identifies its package, build, source and test files. The current M3 manifest is `docs/wiki/evidence/2026-11-18T181500Z-m3/post-review/source-manifest.json`. Check it before relying on that run:

```sh
python3 - <<'PY'
import hashlib, json
from pathlib import Path
manifest = json.loads(Path('docs/wiki/evidence/2026-11-18T181500Z-m3/post-review/source-manifest.json').read_text())
changed = [name for name, expected in manifest.items()
           if not Path(name).is_file() or hashlib.sha256(Path(name).read_bytes()).hexdigest() != expected]
assert not changed, 'Inputs differ: ' + ', '.join(changed)
print('Source manifest matches')
PY
```

M1 and M2 records remain immutable history; their reviewed trees are committed separately. Their fingerprints do not describe M3. Never overwrite their evidence with current results.

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

Default mode is `fixtures`; `--show panel|setup` is allowed only in that mode. Visible checks last two seconds by default, render the app's own view to PNG without Screen Recording permission, and quit. The panel check asserts unchanged actual rows/footer/empty label across three pending edits, and can execute one fake open after capture. The setup check supplies fake Allowed/Denied/Not found outcomes. A bitmap may differ from the screen's composited vibrancy; inspect it without claiming physical input or on-screen latency coverage.

`live-readonly` reads application metadata and system settings resources. With `--file-source projects`, it also indexes Projects read-only; Desktop/Documents/Downloads remain prohibited. `--file-source fixture` creates a temporary tree, and `--fixture-app` adds a synthetic app bundle. The app validates test roots before installing any adapters. It keeps windows hidden; native effects remain fake. Its receipt exports counts, timings and memory/CPU, never real item names/paths. `--runs 2` relaunches the app using the same isolated cache and requires the second launch’s first load to be a cache hit; earlier receipts appear under `previous_runs`. A disposable settings cache lives inside the test APPARATE_HOME and is removed with it.

Readiness requires the first complete attempt from both local catalogs, no reported errors and a receipt from the owned process. The driver validates fake registration/action counts, no native effects, optional image existence and nonempty live catalogs. It waits at most the requested duration plus 65 seconds, stops only its owned process if necessary, and removes only its created APPARATE_HOME. `--output` retains the sanitized receipt and optional PNG; remove only those chosen outputs after inspection or retain them as evidence. The production data folder is never used.

## Measurements

Final app measurements run without concurrent builds/tests. The 60-second hidden profile begins CPU accounting at the first complete catalog; CPU is process user+system time divided by elapsed monotonic time, expressed as a percentage of one core. Physical memory is `TASK_VM_INFO.phys_footprint`, not peak allocation. Record catalog publication/scan counts to identify unexpected activity. Record first app/settings scan time and the subsequent verifying scan separately; a fresh cache miss includes parsing and cache writing, a hit includes file read/decode. Do not label a hit as a fresh parse.

The visible fixture profile injects the same callback entry used by the hotkey, measures `makeKeyAndOrderFront` returning, then completion of the next implicit nonanimated Core Animation transaction. Completion is a **commit proxy**, not an exact commit/presentation timestamp. The timing does not include global-key delivery and is not an end-to-end budget pass. M6 owns the on-screen harness.

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

The driver owns its temporary root and database. It validates file counts, discovered app counts and the appropriate fake open adapter. On a second process, the file snapshot must load from SQLite. Reports export only counts, timings, flags and memory. Raw databases and user names are never copied into evidence. Paths to outputs can be supplied with `--output`; visible checks must remain fixture-only.

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
