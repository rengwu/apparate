---
title: Verification setup
section: Verification
updated: 2026-11-18
---
# Verification setup

Run these commands from the Apparate project root. M1 needs macOS 27 on arm64, Swift 6.4.2 Command Line Tools, Python 3 for the app-stub smoke helper, and Node.js 22+ for the wiki. No package downloads, account, network service or full Xcode installation are needed. The tests use an executable harness because XCTest and Swift Testing are unavailable in the checked Command Line Tools environment.

## Build and identity

```sh
swift --version
sw_vers
./build.sh
codesign --verify --deep --strict build/Apparate.app
codesign -d -r- build/Apparate.app
```

The bundle must identify as `local.apparate`, version `0.1.0`, minimum system `27.0`, arm64 only, with `LSUIElement` true and designated requirement `identifier "local.apparate"`. `build.sh` validates VERSION, builds release arm64, removes the old bundle before assembly, includes the fzy notice, signs ad hoc and verifies the bundle. It does not install or launch it.

There is no git revision for the initial M1 handoff. The [run](runs/2026-11-18T154000Z-m1.md) links a SHA-256 manifest of every package, build, source and test input. Verify it before treating the recorded outcome as evidence for a checkout:

```sh
python3 - <<'PY'
import hashlib, json
from pathlib import Path
manifest = json.loads(Path('docs/wiki/evidence/2026-11-18T154000Z-m1/post-review-source-manifest.json').read_text())
changed = [name for name, expected in manifest.items()
           if not Path(name).is_file() or hashlib.sha256(Path(name).read_bytes()).hexdigest() != expected]
assert not changed, 'Inputs differ: ' + ', '.join(changed)
print('Source manifest matches')
PY
```

## Correctness and isolation

```sh
swift run ApparateCoreTests
swift build -c release --product ApparateCoreTests
apparate_bin="$(swift build -c release --show-bin-path)"
"$apparate_bin/ApparateCoreTests"
python3 Tests/smoke-app.py
```

The harness prints `PASS`/`FAIL` for each group, a final count, and exits nonzero on failure. Fixtures include only synthetic paths and public app names. Every persistence scenario creates a UUID temporary directory and removes it after checking results. It never discovers apps, crawls folders, opens URLs, invokes system actions or reads real launcher data.

The smoke helper starts only the built bundle executable, with its own temporary `APPARATE_HOME`. Readiness means the process remains alive and version-1 `config.json` appears there. It checks defaults, file contents and the created-file list; it stops only its own process and removes only its own directory. It prints a small JSON receipt without temporary paths or account names. No UI is implemented in this stub. Never run the app against its default data folder for M1 verification.

The config-watch scenario uses real file operations and awaits the store's observed state for up to three seconds. It checks in-place writes, atomic saves, rearming, deletion/recreation, invalid-file recovery and notification settling. The generation tests hold the worker or owner with explicit semaphores/fences; they do not depend on a lucky typing delay.

## Release measurements

Run after the release build, without concurrent build/test jobs. Each size gets a fresh process:

```sh
apparate_bin="$(swift build -c release --show-bin-path)"
"$apparate_bin/ApparateCoreTests" --benchmark 20000 --rounds 3 > /private/tmp/apparate-m1-20k.json
"$apparate_bin/ApparateCoreTests" --benchmark 200000 --rounds 3 > /private/tmp/apparate-m1-200k.json
```

Benchmark corpus version 1 uses seed `4170706172617465` (hex), 120 synthetic apps, 120 synthetic settings and a mix of folders/files under 900 synthetic project names. Names include ASCII, accents, expansions, CJK and emoji. Directory chains repeat; names and IDs remain unique. The JSON includes the corpus SHA-256, full query lists and every timed keystroke. It times complete top-50 selection and displayed-character highlights; result checksums are consumed after timing. It excludes `ParsedQuery` construction, coordinator queue delay, discovery, actions and UI. Internal query folding and matching are included. There are five warmup searches and three repetitions per typed prefix.

Path samples start when the first slash is typed, including trailing slash, common short segments, repeated separators and no-hit paths. Names and paths are summarized separately with median, p95 and maximum. `preparation_ms` is SearchIndex construction only; fixture generation is separate. `phys_footprint` is reported at process baseline, immediately after construction, and after searching. It is process physical footprint, not a Swift allocation count or peak-memory measurement.

Keep the complete JSON in the run's evidence directory, together with sanitized build/test output and a source manifest. Do not claim an end-to-end latency pass from these core-only measurements.

## Records and cleanup

The current run lives under `verification/runs/`; linked evidence is under `evidence/<run-id>/`. The test and smoke helpers clean their temporary data automatically. Preserve the bundle, sources and evidence for review. No state-changing git command is part of this procedure; commit only after the independent milestone review and repository authorization.

After editing wiki pages or evidence:

```sh
node "$JSTACK/skills/verify-change/scripts/check-reports.mjs" docs/wiki
node docs/wiki/_build.mjs
node docs/wiki/_build.mjs --check
```

Set `JSTACK` to the reader's own jstack checkout for the metadata checker; it is local tooling, not a product dependency. Wiki checks establish document structure, not product correctness.
