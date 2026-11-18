import Foundation
import Darwin
import CryptoKit
import ApparateCore

private let corpusSeed: UInt64 = 0x4170706172617465
private let nameQueries = ["code", "terminal", "calendar", "calculator", "readme", "report", "network", "project", "sources", "settings", "archive", "notes", "cafe", "strasse", "東京", "zzqv"]
private let pathQueries = ["project/sources", "project/tests", "projects/readme", "workspace/report", "sources/network", "docs/notes", "archive/cafe", "project/", "sources/", "p/s", "s/r", "zzqv/", "project//sources"]

private func corpus(_ count: Int) -> [SearchItem] {
    var random = SeededRandom(state: corpusSeed), items: [SearchItem] = []
    let words = ["Code", "Terminal", "Calendar", "Calculator", "README", "Report", "Network", "Project", "Sources", "Settings", "Archive", "Notes", "Resources", "Design", "Search", "Index", "Config", "Layout", "Preview", "Keyboard"]
    let extensions = ["swift", "md", "json", "txt", "html", "pdf", "png"]
    let folders = ["Sources", "Tests", "Docs", "Resources", "Archive", "Notes", "Design"]
    items.reserveCapacity(count)
    for i in 0..<count {
        let project = random.int(900), subfolder = folders[random.int(folders.count)]
        let stem = i % 97 == 0 ? ["Café", "Straße", "東京資料", "📚 Notes"][random.int(4)] : words[random.int(words.count)]
        let other = words[random.int(words.count)]
        let kind: ItemKind = i < 120 ? .app : (i < 240 ? .setting : (i % 19 == 0 ? .folder : .file))
        let base = "\(stem)-\(other)-\(String(format: "%06d", i))"
        let name = kind == .file ? base + "." + extensions[random.int(extensions.count)] : base
        let path = "/Fixture/Workspace/Projects/Project-\(project)/\(subfolder)/\(name)"
        items.append(SearchItem(id: "\(kind.rawValue):" + path, kind: kind, name: name,
                                alternateNames: kind == .app && i % 7 == 0 ? [stem] : [],
                                keywords: kind == .setting ? [stem.lowercased(), "system"] : [],
                                path: kind == .file || kind == .folder ? path : nil))
    }
    return items
}

private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
}
private func milliseconds(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
private func stats(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    return ["median_ms": sorted[sorted.count / 2], "p95_ms": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], "max_ms": sorted.last!]
}

func runBenchmark() throws {
    let args = CommandLine.arguments
    guard let flag = args.firstIndex(of: "--benchmark"), flag + 1 < args.count, let size = Int(args[flag + 1]), size > 0 else {
        throw TestFailure(description: "Usage: ApparateCoreTests --benchmark 20000 [--rounds 3]")
    }
    let rounds = args.firstIndex(of: "--rounds").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 3
    guard rounds > 0 else { throw TestFailure(description: "Rounds must be positive") }
    let baseline = footprint()
    let (index, generation, preparation) = try autoreleasepool {
        let generationStart = DispatchTime.now().uptimeNanoseconds
        let items = corpus(size), generation = milliseconds(generationStart)
        let preparationStart = DispatchTime.now().uptimeNanoseconds
        let index = try SearchIndex(items: items)
        return (index, generation, milliseconds(preparationStart))
    }
    let builtFootprint = footprint()
    var hash = SHA256()
    for item in index.items {
        for value in [item.id, item.name, item.path ?? ""] {
            hash.update(data: Data("\(value.utf8.count):\(value)".utf8))
        }
    }
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    var checksum: UInt64 = 0
    func consume(_ rows: [SearchResult]) {
        checksum &+= UInt64(rows.count)
        for row in rows {
            checksum &+= UInt64(row.item.id.utf8.count + row.highlights.reduce(0, +))
            checksum ^= row.textScore.bitPattern
        }
    }
    for query in ["r", "code", "cafe", "project/sources", "project/"] { consume(index.search(ParsedQuery(query))) }
    func measure(_ queries: [String], pathOnly: Bool) -> [String: Any] {
        var readings: [Double] = [], cases: [[String: Any]] = []
        for word in queries {
            var prefix = ""
            for character in word {
                prefix.append(character)
                let query = ParsedQuery(prefix)
                if pathOnly && !query.isPath { continue }
                for _ in 0..<rounds {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let rows = index.search(query)
                    let elapsed = milliseconds(start)
                    consume(rows)
                    readings.append(elapsed)
                    cases.append(["query": prefix, "ms": elapsed, "rows": rows.count])
                }
            }
        }
        return ["statistics": stats(readings), "samples": readings.count, "cases": cases]
    }
    let names = measure(nameQueries, pathOnly: false)
    let paths = measure(pathQueries, pathOnly: true)
    let output: [String: Any] = ["schema": 1, "corpus_version": 1, "size": size, "seed_hex": String(corpusSeed, radix: 16),
        "corpus_sha256": digest, "rounds": rounds, "name_queries": nameQueries, "path_queries": pathQueries,
        "baseline_phys_footprint_bytes": baseline, "after_build_phys_footprint_bytes": builtFootprint,
        "after_search_phys_footprint_bytes": footprint(), "preparation_ms": preparation, "corpus_generation_ms": generation,
        "preparation_includes": "SearchIndex construction only; synthetic corpus generation measured separately",
        "warmup_queries": 5, "usage_lambda": 0.5, "result_limit": 50, "names": names, "paths": paths,
        "checksum": String(checksum), "scope": "single-threaded core only; includes selection and highlights; excludes UI, data discovery and query parsing"]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
}
