---
title: Claude matching benchmark
section: Research
updated: 2026-11-18
---
# Claude matching benchmark

Measured on 2026-11-18 on this machine: Apple M1 Pro (10 cores), 16 GB, macOS 27.0, Swift 6.4.2, `swiftc -O`. Part of [Claude's research report](report.md).

## Method

- **Candidates:** 336 app names (from `mdfind` for application bundles), 688 System Settings item titles (from `.searchTerms`), and 22,089 real file and folder names from a pruned walk of the home folder (Library, hidden folders, `node_modules`, `.git`, `target`, `.build`, `DerivedData`, `.venv`, `__pycache__` and `.app` bundles skipped). For 200k, file names are repeated with a numeric suffix.
- **Storage:** all candidates folded once into one flat byte buffer, with a per-byte boundary class and a 64-bit character bitmask per candidate. Nothing is allocated per keystroke except the hit list.
- **Scorer:** fzy's dynamic-programming scorer (consecutive bonus 1.0; word start 0.8; camel hump 0.7; after dot 0.6; small gap penalties). A greedy subsequence check runs first.
- **Queries:** every prefix of `vsc`, `visual`, `keyboard la`, `readme`, `apparate`, `pjapp`, `sysset`, `dl`, as if typed. Each keystroke runs 7 times; the best run is kept. The time includes selecting the top 50 results.
- **Variants:** with and without the bitmask prefilter; 1 thread or all 10 cores (`DispatchQueue.concurrentPerform`); "incremental" re-searches only the previous keystroke's hits.

## Results

Bounded top-50 selection, re-run after review with a checksum over the selected IDs (so the selection cannot be optimised away). "Slowest" is the maximum over keystrokes of each keystroke's best of 7 runs. It is not an observed worst case or p95.

| Candidates | Variant | Mean per keystroke | Slowest keystroke |
| --- | --- | --- | --- |
| 1,024 | bitmask, 1 thread | 0.014 ms | 0.060 ms |
| 20,000 | no prefilter, 1 thread | 0.325 ms | 0.572 ms |
| 20,000 | bitmask, 1 thread | 0.125 ms | 0.487 ms |
| 20,000 | bitmask, 10 threads | 0.077 ms | 0.165 ms |
| 200,000 | no prefilter, 1 thread | 3.481 ms | 6.167 ms |
| 200,000 | bitmask, 1 thread | 1.303 ms | 5.216 ms |
| 200,000 | bitmask, 10 threads | 0.293 ms | 0.992 ms |
| 200,000 | bitmask + incremental, 1 thread | 0.954 ms | 4.793 ms |

The run before the checksum gave the same figures within noise. "Incremental" re-searches the complete hit set of the previous keystroke, never only the visible top K.

The first version fully sorted every hit. A one-letter query matches most candidates, so its worst keystroke at 200k was 12.5 ms (1 thread). Bounded top-K selection cut that to about 5.2 ms. Building the 200k corpus took 44 ms.

Conclusions:

- A frame is 8.3 ms at 120 Hz. Everything at 20k candidates fits in a fraction of a frame on one thread. At 200k, splitting across cores keeps the worst keystroke near 1 ms.
- Only names were scored. Codex's benchmark measured full paths at 200k at about 44 ms median (up to 81 ms), so matching must be name-first, with a separate path mode. The two benchmarks use different corpora, queries and statistics, so their numbers should not be merged into one table.
- The bitmask prefilter roughly halves the cost. Incremental narrowing helps less than expected once the prefilter exists.
- Never fully sort hits; select the top K.

## Ranking observations

Top results at 20k candidates, raw fzy score only (no kind tiers, no usage history):

| Query | Top results |
| --- | --- |
| `vsc` | Visual Studio Code (app), variable_star.c (file), Move screen image (setting) |
| `keyboard la` | Keyboard layouts (setting) |
| `sysset` | System Settings (app), Lock System Settings (setting) |
| `term` | termios (file), termius (file), **Terminal (app) third** |
| `safa` | Safari (app), schemafault.test (file) |

Acronym and word-start matching works with fzy's bonuses alone. The `term` case shows that a raw string score is not enough. Results need tiers (exact/alias, prefix, word-start, fuzzy), a kind priority (apps before files by default), and usage history.

## Idle memory of a minimal shell

A hidden AppKit agent app (`NSPanel` with `.nonactivatingPanel`, an `NSTextField`, an `NSTableView`) holding all 23,112 names in memory: **18 MB `phys_footprint`, 0.0% CPU** (`footprint -p`). Raycast reports ~200–300 MB for v1 and ~350–450 MB for v2 using the same metric ([Raycast blog](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast)). Icons, the settings UI and the file index will add to the 18 MB.

## Source

Build with `swiftc -O bench.swift -o bench`, run with `./bench apps.txt settings.txt files.txt` (one name per line).

```swift
// Per-keystroke fuzzy matching benchmark for Apparate research.
// fzy-style DP scorer over pre-folded byte buffers, with optional
// character-bitmask prefilter, incremental narrowing, and multi-core split.
// Build: swiftc -O bench.swift -o bench   Run: ./bench apps.txt settings.txt files.txt
import Foundation
import Dispatch

// ---------- Candidate storage (flat, built once per index change) ----------
struct Corpus {
    var lower: [UInt8] = []      // folded bytes, all candidates back to back
    var cls: [UInt8] = []        // per-byte boundary class for bonuses
    var start: [Int32] = []      // offset of candidate i
    var len: [UInt16] = []
    var mask: [UInt64] = []      // which of a-z0-9 etc. occur
    var names: [String] = []
    var kind: [UInt8] = []       // 0 app, 1 setting, 2 file
    var count: Int { start.count }

    mutating func add(_ s: String, kind k: UInt8) {
        let raw = Array(s.utf8.prefix(255))
        start.append(Int32(lower.count)); len.append(UInt16(raw.count))
        var m: UInt64 = 0
        var prev: UInt8 = 0x2F // treat start as after slash
        for b in raw {
            let l = (b >= 65 && b <= 90) ? b + 32 : b
            lower.append(l)
            // classes: 1 after separator ("word"), 2 camel hump, 3 after dot, 0 none
            var c: UInt8 = 0
            if prev == 0x2F || prev == 0x20 || prev == 0x2D || prev == 0x5F { c = 1 }
            else if prev == 0x2E { c = 3 }
            else if (b >= 65 && b <= 90) && (prev >= 97 && prev <= 122) { c = 2 }
            cls.append(c)
            m |= bit(l)
            prev = b
        }
        mask.append(m); names.append(s); kind.append(k)
    }
}

@inline(__always) func bit(_ b: UInt8) -> UInt64 {
    if b >= 97 && b <= 122 { return 1 << UInt64(b - 97) }
    if b >= 48 && b <= 57 { return 1 << UInt64(26 + b - 48) }
    return 1 << 63
}

// ---------- fzy scoring constants ----------
let gapLeading: Float = -0.005, gapTrailing: Float = -0.005, gapInner: Float = -0.01
let matchConsecutive: Float = 1.0
let bonusFor: [Float] = [0, 0.8, 0.7, 0.6]   // none, word, camel, dot

// Scratch buffers per worker to avoid allocation per candidate.
final class Scratch {
    var D = [Float](repeating: 0, count: 256 * 32)
    var M = [Float](repeating: 0, count: 256 * 32)
}

@inline(__always)
func isSubsequence(_ q: UnsafeBufferPointer<UInt8>, _ t: UnsafeBufferPointer<UInt8>) -> Bool {
    var j = 0
    for c in q {
        while j < t.count && t[j] != c { j += 1 }
        if j == t.count { return false }
        j += 1
    }
    return true
}

func score(_ q: UnsafeBufferPointer<UInt8>, _ t: UnsafeBufferPointer<UInt8>, _ cls: UnsafeBufferPointer<UInt8>, _ s: Scratch) -> Float {
    let n = q.count, m = t.count
    if n == m { return Float.infinity }        // exact (subsequence of equal length)
    if m > 255 || n > 32 { return -Float.infinity }
    return s.D.withUnsafeMutableBufferPointer { D in
        s.M.withUnsafeMutableBufferPointer { M in
            for i in 0..<n {
                var prevScore = -Float.infinity
                let gap = (i == n - 1) ? gapTrailing : gapInner
                for j in 0..<m {
                    let idx = i * 256 + j
                    if q[i] == t[j] {
                        var sc = -Float.infinity
                        let bonus = bonusFor[Int(cls[j])]
                        if i == 0 {
                            sc = Float(j) * gapLeading + bonus
                        } else if j > 0 {
                            let pm = M[(i - 1) * 256 + j - 1], pd = D[(i - 1) * 256 + j - 1]
                            sc = max(pm + bonus, pd + matchConsecutive)
                        }
                        D[idx] = sc
                        prevScore = max(sc, prevScore + gap)
                        M[idx] = prevScore
                    } else {
                        D[idx] = -Float.infinity
                        prevScore = prevScore + gap
                        M[idx] = prevScore
                    }
                }
            }
            return M[(n - 1) * 256 + m - 1]
        }
    }
}

struct Hit { var idx: Int32; var score: Float }

// Search a list of candidate indices; returns all hits (subsequence matches) with scores.
func search(_ c: Corpus, query: [UInt8], within: [Int32]?, prefilter: Bool, threads: Int) -> [Hit] {
    var qm: UInt64 = 0
    for b in query { qm |= bit(b) }
    let total = within?.count ?? c.count
    let chunks = max(1, threads)
    var parts = [[Hit]](repeating: [], count: chunks)
    c.lower.withUnsafeBufferPointer { L in
        c.cls.withUnsafeBufferPointer { C in
            query.withUnsafeBufferPointer { Q in
                parts.withUnsafeMutableBufferPointer { P in
                    DispatchQueue.concurrentPerform(iterations: chunks) { k in
                        let s = Scratch()
                        var out: [Hit] = []
                        let lo = total * k / chunks, hi = total * (k + 1) / chunks
                        for x in lo..<hi {
                            let i = within.map { Int($0[x]) } ?? x
                            if prefilter && (c.mask[i] & qm) != qm { continue }
                            let st = Int(c.start[i]), ln = Int(c.len[i])
                            let T = UnsafeBufferPointer(rebasing: L[st..<st + ln])
                            if !isSubsequence(Q, T) { continue }
                            let sc = score(Q, T, UnsafeBufferPointer(rebasing: C[st..<st + ln]), s)
                            out.append(Hit(idx: Int32(i), score: sc))
                        }
                        P[k] = out
                    }
                }
            }
        }
    }
    return parts.flatMap { $0 }
}

func better(_ a: Hit, _ b: Hit, _ c: Corpus) -> Bool {
    if a.score != b.score { return a.score > b.score }
    let la = c.len[Int(a.idx)], lb = c.len[Int(b.idx)]
    if la != lb { return la < lb }
    return a.idx < b.idx
}
// Bounded selection: keeps only the best k, so a 1-letter query never sorts every hit.
func topK(_ hits: [Hit], _ k: Int, _ c: Corpus) -> [Hit] {
    var best: [Hit] = []
    best.reserveCapacity(k + 1)
    for h in hits {
        if best.count == k, !better(h, best[k - 1], c) { continue }
        var i = best.count
        while i > 0 && better(h, best[i - 1], c) { i -= 1 }
        best.insert(h, at: i)
        if best.count > k { best.removeLast() }
    }
    return best
}

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

// ---------- Load corpus ----------
let args = CommandLine.arguments
func lines(_ p: String) -> [String] {
    (try? String(contentsOfFile: p, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
}
let apps = lines(args[1]), settings = lines(args[2]), files = lines(args[3])

func buildCorpus(fileTarget: Int) -> Corpus {
    var c = Corpus()
    for a in apps { c.add(a, kind: 0) }
    for s in settings { c.add(s, kind: 1) }
    var i = 0
    while c.count < fileTarget {
        let f = files[i % files.count]
        // pad by suffixing a copy number so strings are distinct but realistic
        c.add(i < files.count ? f : "\(f) \(i / files.count)", kind: 2)
        i += 1
    }
    return c
}

var checksum: Int = 0
let typing = ["vsc", "visual", "keyboard la", "readme", "apparate", "pjapp", "sysset", "dl"]
let cores = ProcessInfo.processInfo.activeProcessorCount

for target in [1_000, 20_000, 200_000] {
    let t0 = now()
    let c = buildCorpus(fileTarget: target)
    let buildMs = Double(now() - t0) / 1e6
    print("\n=== N = \(c.count) candidates (corpus build \(String(format: "%.1f", buildMs)) ms, \(c.lower.count / 1024) KiB text) ===")
    for (label, pre, thr, incremental) in [("naive 1 thread", false, 1, false),
                                           ("bitmask 1 thread", true, 1, false),
                                           ("bitmask \(cores) threads", true, cores, false),
                                           ("bitmask + incremental, 1 thread", true, 1, true)] {
        var worst = 0.0, sum = 0.0, n = 0
        for word in typing {
            var prevHits: [Int32]? = nil
            for p in 1...word.count {
                let q = Array(word.utf8.prefix(p)).map { ($0 >= 65 && $0 <= 90) ? $0 + 32 : $0 }
                var best = Double.infinity
                var hits: [Hit] = []
                for _ in 0..<7 {
                    let t = now()
                    hits = search(c, query: q, within: incremental ? prevHits : nil, prefilter: pre, threads: thr)
                    for h in topK(hits, 50, c) { checksum &+= Int(h.idx) }
                    best = min(best, Double(now() - t) / 1e6)
                }
                if incremental { prevHits = hits.map { $0.idx } }
                worst = max(worst, best); sum += best; n += 1
            }
        }
        print(String(format: "  %-34@ mean %7.3f ms/keystroke, max of per-keystroke best-of-7 %7.3f ms", label as NSString, sum / Double(n), worst))
    }
    if target == 20_000 {
        for word in ["vsc", "keyboard la", "sysset", "term", "safa"] {
            let q = Array(word.utf8)
            let top = topK(search(c, query: q, within: nil, prefilter: true, threads: 1), 4, c)
            let shown = top.map { "\(c.names[Int($0.idx)]) [\(["app","setting","file"][Int(c.kind[Int($0.idx)])])]" }
            print("  top for '\(word)': " + shown.joined(separator: " | "))
        }
    }
}
print("checksum \(checksum)")
```
