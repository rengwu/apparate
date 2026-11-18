---
title: Swift matching benchmark
section: Research
updated: 2026-11-18
---
# Swift matching benchmark

**Verified—measured here, 2026-11-18.** A small fzy-like scorer was written and compiled in a temporary directory. This is a research executable, not Apparate product code. It demonstrates the cost of scoring names versus full paths and of adding a character mask. It is not a benchmark of upstream fzy/fzf/nucleo binaries.

## Method

- Shared environment facts: Apple M1 Pro, 16 GB RAM, macOS 27.0, Swift 6.4.2; Command Line Tools, no full Xcode.
- Optimized compilation: `swiftc -O -whole-module-optimization`.
- Corpus: 336 distinct app names from Spotlight plus 13,410 file/folder paths beneath `~/Projects`, excluding `.git`, `node_modules`, `target`, and `.build`. Symlink directories are not traversed. Names/paths only; file contents were not read.
- 13,746 distinct seed strings, shuffled with Python seed 42, then repeated to 200,000 entries. Sizes use the first 1,000, 20,000, or 200,000. Repetition preserves this sample's distribution; it is **not 200,000 distinct real files**.
- Full-path strings averaged 76.03 UTF-8 bytes, maximum 170. Basename variant used identical records with parent paths removed, averaging 18.09 bytes.
- Queries: `v`, `vs`, `vsc`, `s`, `sw`, `swi`, `src`, `read`, `readme`, `app`, `zqxj`. Each is scored independently; no incremental reuse.
- Single thread, two warmups, nine measured rounds per query/mode. Plain/mask order alternates. Reported times are medians. Nine samples are too few for reliable production tail-latency claims.
- Both variants use ordered-subsequence rejection and reused DP rows. Mask adds a precomputed 64-bit byte-presence test. Collisions permit false positives but no false negatives relative to this byte matcher.
- Timed: mask/subsequence checks, DP, counting and a checksum over all matches. Excluded: JSON parsing, directory walk, normalization, record construction, top-K selection/sorting, highlights, icons, IPC, window creation, drawing.
- Correctness checks: `VSC` matches Visual Studio Code and outranks a scattered synthetic match; reversed `csv` does not match; mask/plain match counts and score checksums are equal for every measured pair. Swift `precondition` checks remain enabled under `-O`.
- This was a live desktop, not an isolated thermal/power-controlled lab. ASCII-only case folding and byte-based boundaries are deliberate benchmark limitations.

Corpus SHA-256 (full JSON): `c04fbb38563f0e2f06572565907cd58feca504f8df807780e778aef50ef1d829`. The full private path list is not copied into project documentation.

## Results

Median of the eleven per-query medians, in milliseconds. These aggregate numbers describe this query mix only.

| Candidates | Full path, plain | Full path, mask | Basename, plain | Basename, mask |
| --- | --- | --- | --- | --- |
| 1,000 | 0.221 | 0.216 | 0.022 | 0.011 |
| 20,000 | 4.643 | 4.492 | 0.514 | 0.266 |
| 200,000 | 46.301 | 43.863 | 6.089 | 3.941 |

The 200,000-candidate results show why both string length and selectivity matter:

| Query | Full path plain / mask, ms | Basename plain / mask, ms | Full-path mask rejects | Basename mask rejects |
| --- | --- | --- | --- | --- |
| `v` | 38.067 / 36.036 | 6.880 / 4.244 | 27.6% | 70.1% |
| `vs` | 45.695 / 43.669 | 6.750 / 4.429 | 27.7% | 77.0% |
| `vsc` | 46.301 / 43.863 | 4.604 / 1.335 | 27.8% | 88.1% |
| `s` | 26.293 / 26.538 | 6.785 / 6.312 | 1.0% | 26.3% |
| `sw` | 41.837 / 39.004 | 5.682 / 2.157 | 31.1% | 85.3% |
| `swi` | 52.834 / 49.755 | 5.093 / 1.288 | 31.8% | 88.7% |
| `src` | 69.043 / 69.036 | 6.963 / 4.113 | 1.8% | 75.6% |
| `read` | 82.888 / 80.823 | 7.124 / 3.941 | 19.0% | 82.3% |
| `readme` | 47.467 / 45.792 | 5.144 / 1.702 | 21.9% | 84.2% |
| `app` | 46.453 / 46.133 | 6.089 / 4.123 | 7.5% | 66.5% |
| `zqxj` | 11.360 / 0.474 | 3.733 / 0.201 | 98.8% | 99.6% |

Full paths repeat common directory characters, so their masks reject little for common queries. For `src`, full-path scoring stays around 69 ms with or without the mask. Basename scoring is much shorter and the mask rejects 75.6% of records, reducing that query to 4.11 ms. A rare no-match query benefits greatly, but must not stand in for the ordinary typing workload.

Peak RSS from `/usr/bin/time -l`: 383,123,456 bytes (365.4 MiB) for the full-path harness; 99,991,552 bytes (95.4 MiB) for basename. These peaks include JSON/input strings, growing arrays, an **8-byte Double bonus per character**, and runtime allocation overhead. They are not steady-state app memory, not just the scorer's scratch space, and not a compact index memory estimate. Production should store boundary flags/bonuses compactly and avoid duplicated full paths. Four score rows at the full-path maximum consume only 5,440 bytes.

**Conclusion:** 20k full-path scoring can fit within a frame in this workload, while 200k full-path DP cannot reliably do so. Basename-first search is the defensible default. Keep a separate path-aware mode and candidate narrowing for path queries. The proposed app must still measure top-K work and key-to-presented-frame latency.

## Reproduce

Create a temporary directory outside the project. Save the following blocks as `collect.py` and `bench.swift` there, then run:

```sh
python3 collect.py
swiftc -O -whole-module-optimization -o bench bench.swift
/usr/bin/time -l ./bench candidates.json > results.csv
python3 - <<'PYCODE'
from pathlib import Path
import json
names = json.loads(Path('candidates.json').read_text())
Path('basenames.json').write_text(json.dumps([Path(s).name for s in names], ensure_ascii=False))
PYCODE
/usr/bin/time -l ./bench basenames.json > results-basename.csv
```

The live filesystem changes, so a later collection may produce a different count/hash. Preserve your own corpus when comparing changes. The CSV's `*_p95_ms` columns are nearest-rank estimates from nine samples (therefore the sample maximum), not robust p95 measurements.

### collect.py

```python
from pathlib import Path
import os, random, subprocess, hashlib, json
root = Path.home() / 'Projects'
prune = {'.git', 'node_modules', 'target', '.build'}
paths = []
for parent, dirs, files in os.walk(root, followlinks=False):
    dirs[:] = sorted(d for d in dirs if d not in prune)
    paths += ['~/Projects/' + str((Path(parent)/n).relative_to(root)) for n in dirs+sorted(files)]
apps = subprocess.check_output(['mdfind', '-0', 'kMDItemContentType == "com.apple.application-bundle"']).decode().split('\0')
apps = sorted(set(Path(p).stem for p in apps if p))
base = sorted(set(apps + paths))
random.Random(42).shuffle(base)
corpus = (base * ((200000 + len(base)-1)//len(base)))[:200000]
# JSON avoids newline/tab ambiguity in real filenames.
data = json.dumps(corpus, ensure_ascii=False).encode()
Path(__file__).with_name('candidates.json').write_bytes(data)
print(json.dumps({'apps':len(apps),'paths':len(paths),'unique_base':len(base),'N':len(corpus),'mean_utf8_bytes':sum(len(x.encode()) for x in corpus)/len(corpus),'max_utf8_bytes':max(len(x.encode()) for x in corpus),'sha256':hashlib.sha256(data).hexdigest()}))
```

### bench.swift

The DP recurrence and bonus categories follow the [fzy source](https://github.com/jhawthorn/fzy/blob/34b88869d022e861da4846c4463aea3ddfb3ff30/src/match.c), implemented here as an intentionally small Swift experiment. It does not reproduce every fzy option or Unicode behaviour.

```swift
import Foundation
import Dispatch

struct Candidate { let offset: Int; let count: Int; let mask: UInt64 }
@inline(__always) func lower(_ b: UInt8) -> UInt8 { b >= 65 && b <= 90 ? b + 32 : b }
@inline(__always) func bit(_ b: UInt8) -> UInt64 { 1 << UInt64(b & 63) }
var bytes = [UInt8](), bonuses = [Double](), candidates = [Candidate]()
let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let names = try JSONDecoder().decode([String].self, from: input)
for name in names {
    let raw = Array(name.utf8), offset = bytes.count
    var mask: UInt64 = 0
    for j in raw.indices {
        let b = lower(raw[j]), previous: UInt8 = j == 0 ? 47 : raw[j-1]
        bytes.append(b); mask |= bit(b)
        let bonus: Double
        if previous == 47 { bonus = 0.9 }
        else if previous == 32 || previous == 45 || previous == 95 { bonus = 0.8 }
        else if previous >= 97 && previous <= 122 && raw[j] >= 65 && raw[j] <= 90 { bonus = 0.7 }
        else if previous == 46 { bonus = 0.6 }
        else { bonus = 0 }
        bonuses.append(bonus)
    }
    candidates.append(Candidate(offset: offset, count: raw.count, mask: mask))
}
let width = max(1, candidates.map(\.count).max()!)
// Score only; reuse four rows, no allocation or match-position traceback per candidate.
let rows = UnsafeMutablePointer<Double>.allocate(capacity: width * 4)
rows.initialize(repeating: 0, count: width * 4)
defer { rows.deinitialize(count: width * 4); rows.deallocate() }
let neg = -Double.infinity
@inline(__always) func score(_ text: UnsafePointer<UInt8>, _ bonus: UnsafePointer<Double>,
                            _ n: Int, _ query: [UInt8]) -> Double {
    let m = query.count
    if m == 0 || m > n { return neg }
    var q = 0
    for j in 0..<n {
        if text[j] == query[q] { q += 1; if q == m { break } }
    }
    if q != m { return neg } // Exact ordered-subsequence prefilter in BOTH modes.
    if m == n { return 1_000_000 }
    var pd = rows, pm = rows + width, cd = rows + width * 2, cm = rows + width * 3
    for i in 0..<m {
        var best = neg
        let gap = i == m - 1 ? -0.005 : -0.01
        for j in 0..<n {
            var d = neg
            if text[j] == query[i] {
                if i == 0 { d = Double(j) * -0.005 + bonus[j] }
                else if j > 0 { d = max(pm[j-1] + bonus[j], pd[j-1] + 1.0) }
            }
            cd[j] = d; best = max(d, best + gap); cm[j] = best
        }
        swap(&pd, &cd); swap(&pm, &cm)
    }
    return pm[n-1]
}
struct Result { let elapsed: Double; let checksum: Double; let matches: Int; let rejected: Int }
@inline(never) func run(_ count: Int, _ query: [UInt8], _ useMask: Bool) -> Result {
    var mask: UInt64 = 0
    for b in query { mask |= bit(b) }
    let start = DispatchTime.now().uptimeNanoseconds
    var checksum = 0.0, matches = 0, rejected = 0
    bytes.withUnsafeBufferPointer { bp in
        bonuses.withUnsafeBufferPointer { sp in
            for i in 0..<count {
                let c = candidates[i]
                if useMask && (c.mask & mask) != mask { rejected += 1; continue }
                let value = score(bp.baseAddress! + c.offset, sp.baseAddress! + c.offset, c.count, query)
                if value.isFinite { checksum += value; matches += 1 }
            }
        }
    }
    return Result(elapsed: Double(DispatchTime.now().uptimeNanoseconds - start)/1e6,
                  checksum: checksum, matches: matches, rejected: rejected)
}
// Correctness checks are outside the timer.
func testScore(_ name: String, _ query: String) -> Double {
    let raw = Array(name.utf8), text = raw.map(lower)
    let bonus = raw.indices.map { j -> Double in
        let p: UInt8 = j == 0 ? 47 : raw[j-1]
        if p == 47 { return 0.9 }
        if p == 32 || p == 45 || p == 95 { return 0.8 }
        if p >= 97 && p <= 122 && raw[j] >= 65 && raw[j] <= 90 { return 0.7 }
        return p == 46 ? 0.6 : 0
    }
    return text.withUnsafeBufferPointer { t in bonus.withUnsafeBufferPointer { b in
        score(t.baseAddress!, b.baseAddress!, text.count, Array(query.utf8).map(lower))
    }}
}
precondition(testScore("Visual Studio Code", "VSC").isFinite)
precondition(testScore("Visual Studio Code", "VSC") > testScore("avbsxc", "vsc"))
precondition(!testScore("Visual Studio Code", "csv").isFinite)
print("N,query,plain_ms,mask_ms,plain_p95_ms,mask_p95_ms,matches,mask_rejected_pct")
let queries = ["v", "vs", "vsc", "s", "sw", "swi", "src", "read", "readme", "app", "zqxj"]
var sink = 0.0
for n in [1000, 20000, 200000] {
    for query in queries {
        let q = Array(query.utf8).map(lower)
        var times = [[Double](), [Double]()]
        var last = [Result]()
        for round in 0..<11 {
            var pair = [Result?](repeating:nil, count:2)
            for mode in (round % 2 == 0 ? [0,1] : [1,0]) {
                let result = run(n, q, mode == 1); pair[mode] = result
                if round >= 2 { times[mode].append(result.elapsed) }
                sink += result.checksum
            }
            precondition(pair[0]!.matches == pair[1]!.matches)
            precondition(pair[0]!.checksum == pair[1]!.checksum)
            last = pair.map { $0! }
        }
        times[0].sort(); times[1].sort()
        print(String(format: "%d,%@,%.3f,%.3f,%.3f,%.3f,%d,%.1f", n, query,
                     times[0][4], times[1][4], times[0][8], times[1][8], last[0].matches,
                     100.0 * Double(last[1].rejected)/Double(n)))
    }
}
fputs("checksum=\(sink)\n", stderr)
```

See [fuzzy matching](fuzzy-matching.md) for the proposed production ranking and Unicode requirements, and the [report](report.md) for budgets and architecture.
