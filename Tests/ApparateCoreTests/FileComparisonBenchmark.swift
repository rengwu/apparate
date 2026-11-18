import Foundation
import CryptoKit
import ApparateCore

/// Same M1 generator and queries, through the real crawler/preparer and the flat engine.
/// App/settings names become files (no alternates/keywords); both engines also receive
/// the structural directories a crawl necessarily indexes, in the same traversal order.
private struct ComparisonTree: Sendable {
    let root = "/Fixture"
    let entries: [String: SearchItem]
    let children: [String: [String]]
    let ordered: [SearchItem]
    init(count: Int) {
        let root = "/Fixture"
        var entries: [String: SearchItem] = [:], children: [String: Set<String>] = [:]
        func add(_ path: String, kind: ItemKind) {
            guard entries[path] == nil else { return }
            let url = URL(fileURLWithPath: path)
            entries[path] = SearchItem(id: (kind == .folder ? "folder:" : "file:") + path,
                                      kind: kind, name: url.lastPathComponent, path: path)
            if path != root {
                let parent = url.deletingLastPathComponent().path
                children[parent, default: []].insert(url.lastPathComponent)
                add(parent, kind: .folder)
            }
        }
        for item in corpus(count) {
            let path = item.path ?? String(item.id.drop(while: { $0 != ":" }).dropFirst())
            add(path, kind: item.kind == .folder ? .folder : .file)
        }
        let sorted = children.mapValues { $0.sorted() }
        var ordered: [SearchItem] = [entries[root]!]
        func visit(_ path: String) {
            // CrawlWork inserts a directory's whole child batch before descending.
            for child in sorted[path] ?? [] { ordered.append(entries[path + "/" + child]!) }
            for child in sorted[path] ?? [] { visit(path + "/" + child) }
        }
        visit(root)
        self.entries = entries; self.children = sorted; self.ordered = ordered
    }
    var reader: FileReading {
        FileReading(metadata: { path in
            guard let entry = entries[path] else { throw TestFailure(description: "Unknown synthetic path") }
            return FileMetadata(type: entry.kind == .folder ? .directory : .file)
        }, children: { children[$0] ?? [] }, ignoreContents: { _ in nil }, ignoresCase: { _ in false })
    }
}

@MainActor func runFileComparisonBenchmark() async throws {
    let tree = ComparisonTree(count: 200_000)
    let scan = try await FileCrawler(reader: tree.reader).crawl(folders: [.init(path: tree.root)], respectGitignore: false, access: fixtureAccess)
    let snapshot = scan.snapshot, reference = try SearchIndex(items: tree.ordered)
    try expect(snapshot.count == tree.ordered.count && scan.dirtyPaths.isEmpty)
    var digest = SHA256()
    for item in tree.ordered {
        for value in [item.id, item.name, item.path ?? ""] { digest.update(data: Data("\(value.utf8.count):\(value)".utf8)) }
    }
    let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    var checksum: UInt64 = 0, verified = 0
    for q in ["r", "code", "cafe", "project/sources", "project/"] {
        checksum &+= UInt64(snapshot.search(ParsedQuery(q)).count + reference.search(ParsedQuery(q), includeWebFallback: false).count)
    }
    func measure(_ words: [String], pathOnly: Bool) throws -> [String: Any] {
        var flat: [Double] = [], file: [Double] = [], cases: [[String: Any]] = []
        for word in words {
            var prefix = ""
            for character in word {
                prefix.append(character)
                let query = ParsedQuery(prefix)
                if pathOnly && !query.isPath { continue }
                // Complete row equality is checked outside the measured interval.
                let expected = reference.search(query, includeWebFallback: false)
                try expect(snapshot.search(query) == expected, "File/reference mismatch for \(prefix)")
                verified += 1
                for round in 0..<3 {
                    func timed(_ useFile: Bool) -> Double {
                        let start = ContinuousClock.now
                        let rows = useFile ? snapshot.search(query) : reference.search(query, includeWebFallback: false)
                        let elapsed = durationMS(start.duration(to: .now))
                        checksum &+= UInt64(rows.count)
                        for row in rows { checksum ^= row.textScore.bitPattern; checksum &+= UInt64(row.highlights.reduce(0, +)) }
                        return elapsed
                    }
                    // Alternate execution order to avoid always warming one engine first.
                    let a: Double, b: Double
                    if round % 2 == 0 { a = timed(false); b = timed(true) } else { b = timed(true); a = timed(false) }
                    flat.append(a); file.append(b); cases.append(["query": prefix, "flat_ms": a, "file_ms": b, "rows": expected.count])
                }
            }
        }
        return ["flat": fileStats(flat), "file": fileStats(file), "file_to_flat_p95": fileStats(file)["p95_ms"]! / fileStats(flat)["p95_ms"]!, "samples": flat.count, "cases": cases]
    }
    let names = try measure(nameQueries, pathOnly: false), paths = try measure(pathQueries, pathOnly: true)
    let ratio = names["file_to_flat_p95"] as! Double
    let report: [String: Any] = ["result": "Passed", "schema": 1, "original_generator_count": 200_000, "entry_count": snapshot.count,
        "name_p95_target_multiplier": 2, "name_p95_within_target": ratio <= 2,
        "structural_directories_added": snapshot.count - 200_000, "seed_hex": String(corpusSeed, radix: 16), "matched_corpus_sha256": hash,
        "transformation": "M1 names and paths unchanged; first 240 app/settings entries treated as files, no alternates/keywords. Structural directories included in BOTH engines, identical child-batch-before-descent order. Original mixed M1 benchmark remains separate.",
        "name_queries": nameQueries, "path_queries": pathQueries, "rounds": 3, "warmup_queries": 5,
        "names": names, "paths": paths, "equality_queries": verified, "checksum": String(checksum),
        "scope": "Core scoring/top-50/highlights; identical complete rows verified per prefix; excludes parsing, equality check, discovery and UI; both representations retained, not a memory benchmark"]
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
}
