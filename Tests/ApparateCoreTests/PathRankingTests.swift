import Foundation
import ApparateCore

private struct TightPathTree: Sendable {
    let root = "/Fixture"
    let items: [SearchItem]
    let children: [String: [String]]
    init(_ paths: [String]) {
        var nodes: Set<String> = ["/Fixture"], listings: [String: Set<String>] = [:]
        for suffix in paths {
            var parent = "/Fixture"
            for part in suffix.split(separator: "/") {
                let name = String(part), path = parent + "/" + name
                listings[parent, default: []].insert(name); nodes.insert(path); parent = path
            }
        }
        items = nodes.sorted().map { path in
            SearchItem(id: "folder:" + path, kind: .folder, name: URL(fileURLWithPath: path).lastPathComponent, path: path)
        }
        children = listings.mapValues { $0.sorted() }
    }
    func prepare() async throws -> (SearchIndex, FileIndexSnapshot) {
        let reader = FileReading(metadata: { _ in FileMetadata(type: .directory) }, children: { children[$0] ?? [] }, ignoreContents: { _ in nil }, ignoresCase: { _ in false })
        return try await (SearchIndex(items: items), FileCrawler(reader: reader).crawl(folders: [.init(path: root, depth: 30)], respectGitignore: false, skipHiddenFiles: false, access: fixtureAccess).snapshot)
    }
}

@MainActor func pathRankingTests(_ h: Harness) async {
    await h.test("tight paths: two skipped folders beat one or two opens; five opens still win") {
        let shallow = "/Fixture/Projects/apparate/build", deep = "/Fixture/Projects/apparate/docs/wiki/build"
        let (regular, compact) = try await TightPathTree(["Projects/apparate/build", "Projects/apparate/docs/wiki/build"]).prepare()
        for (opens, first) in [(0.0, shallow), (1, shallow), (2, shallow), (5, deep), (20, deep)] {
            let usage = UsageSnapshot(counts: ["folder:" + deep: opens])
            for text in ["apparate/build", "'apparate/build", "apparate//build"] {
                let query = ParsedQuery(text), rows = compact.search(query, usage: usage)
                try expect(rows == regular.search(query, usage: usage, includeWebFallback: false), text)
                try expect(rows.count == 2 && rows.first?.item.path == first, "Wrong winner at \(opens) opens: \(text)")
                try expect(rows.allSatisfy { $0.highlights == [0, 1, 2, 3, 4] && $0.tier == .exact && $0.source == .name })
                let a = rows.first { $0.item.path == shallow }!, b = rows.first { $0.item.path == deep }!
                try near(a.textScore - b.textScore, 0.2)
            }
            // The name-only query retains usage ordering without any path penalty.
            let plain = compact.search(ParsedQuery("build"), usage: usage)
            try expect(plain == regular.search(ParsedQuery("build"), usage: usage, includeWebFallback: false))
            try expect(plain.first?.item.path == (opens > 0 ? deep : shallow))
        }
    }
    await h.test("tight paths: interior and trailing gaps, free ancestors and shared cap") {
        let suffixes = ["a/b/c", "a/x/b/c", "a/b/x/c", "a/x/b/y/c", "Users/Home/Projects/a/b/c",
                        "a/x0/x1/x2/x3/leaf", "a/y0/y1/y2/y3/y4/y5/y6/y7/leaf", "a/leaf"]
        let (regular, compact) = try await TightPathTree(suffixes).prepare()
        for text in ["a/b/c", "a/leaf", "a/"] {
            let query = ParsedQuery(text)
            try expect(compact.search(query) == regular.search(query, includeWebFallback: false), text)
        }
        let rows = compact.search(ParsedQuery("a/b/c"))
        func score(_ path: String) throws -> Double {
            guard let row = rows.first(where: { $0.item.path == "/Fixture/" + path }) else { throw TestFailure(description: "Missing \(path)") }
            return row.textScore
        }
        try near(try score("a/b/c"), score("Users/Home/Projects/a/b/c"))
        try near(try score("a/b/c") - score("a/x/b/c"), 0.3) // 0.1 gap + existing 0.2 adjacency bonus.
        try near(try score("a/b/c") - score("a/b/x/c"), 0.1)
        try near(try score("a/b/c") - score("a/x/b/y/c"), 0.4)
        let capped = compact.search(ParsedQuery("a/leaf"))
        let direct = capped.first { $0.item.path == "/Fixture/a/leaf" }!
        for row in capped where row.item.id != direct.item.id { try near(direct.textScore - row.textScore, 0.4) }
        let deepest = "/Fixture/a/y0/y1/y2/y3/y4/y5/y6/y7/leaf"
        let usage = UsageSnapshot(counts: ["folder:" + deepest: 20])
        let used = compact.search(ParsedQuery("a/leaf"), usage: usage)
        try expect(used.first?.item.path == deepest && used == regular.search(ParsedQuery("a/leaf"), usage: usage, includeWebFallback: false))
    }
    await h.test("tight paths: adjusted alignment beats the raw winner and shares one cap across gaps") {
        // Earlier exact a has a better raw score than later ax, but loses after gaps.
        let (regular, compact) = try await TightPathTree(["a/x/ax/target", "ax/target", "a/x0/x1/x2/b/y0/y1/y2/target", "a/b/target"]).prepare()
        for text in ["a/target", "a/b/target"] {
            let q = ParsedQuery(text); try expect(compact.search(q) == regular.search(q, includeWebFallback: false))
        }
        let tradeoff = compact.search(ParsedQuery("a/target"))
        try near(tradeoff.first { $0.item.path == "/Fixture/a/x/ax/target" }!.textScore,
                 tradeoff.first { $0.item.path == "/Fixture/ax/target" }!.textScore)
        let cap = compact.search(ParsedQuery("a/b/target"))
        // Six gaps together cap at 0.4; the consecutive pair keeps its old +0.2.
        try near(cap.first { $0.item.path == "/Fixture/a/b/target" }!.textScore - cap.first { $0.item.path == "/Fixture/a/x0/x1/x2/b/y0/y1/y2/target" }!.textScore, 0.6)
    }
    await h.test("tight paths: exhaustive independent alignment oracle for repeated fuzzy segments") {
        var random = SeededRandom(state: 0xDEC060)
        let names = ["a", "A", "ab", "ba", "b", "aa", "x"]
        var componentScores: [String: Double] = [:]
        for query in ["a", "b", "ab"] { for name in names {
            let index = try SearchIndex(items: [fixture(name)])
            componentScores[query + ":" + name] = index.search(ParsedQuery(query), includeWebFallback: false).first?.textScore
        } }
        let leafScore = try SearchIndex(items: [fixture("target")]).search(ParsedQuery("target"))[0].textScore
        for _ in 0..<160 {
            let chain = (0..<(3 + random.int(7))).map { _ in names[random.int(names.count)] }
            let queries = (0..<(1 + random.int(3))).map { _ in ["a", "b", "ab"][random.int(3)] }
            var best = -Double.infinity
            func enumerate(_ positions: [Int], _ raw: Double) {
                if positions.count == queries.count {
                    var skipped = chain.count - positions.last! - 1
                    for i in 1..<positions.count { skipped += positions[i] - positions[i - 1] - 1 }
                    best = max(best, raw - min(0.4, Double(skipped) * 0.1)); return
                }
                for p in ((positions.last ?? -1) + 1)..<chain.count {
                    guard let score = componentScores[queries[positions.count] + ":" + chain[p]] else { continue }
                    let adjacent = positions.last.map { $0 + 1 == p ? 0.2 : 0 } ?? 0
                    enumerate(positions + [p], raw + score + adjacent)
                }
            }
            enumerate([], 0)
            let path = chain.joined(separator: "/") + "/target"
            let (regular, compact) = try await TightPathTree([path]).prepare()
            let query = ParsedQuery((queries + ["target"]).joined(separator: "/"))
            let rows = compact.search(query)
            try expect(rows == regular.search(query, includeWebFallback: false), "Compact mismatch: \(query.text), \(path)")
            if best.isFinite {
                try expect(rows.count == 1); try near(rows[0].textScore, leafScore + best)
            } else { try expect(rows.isEmpty) }
        }
    }
    await h.test("tight paths: penalized candidates compete before the top-50 cutoff") {
        let shallow = "apparate/build", far = (0..<80).map { "apparate/docs/cache-\($0)/wiki/build" }
        let (regular, compact) = try await TightPathTree(far + [shallow]).prepare()
        let usage = UsageSnapshot(counts: Dictionary(uniqueKeysWithValues: far.map { ("folder:/Fixture/" + $0, 1.0) }))
        let query = ParsedQuery("apparate/build"), rows = compact.search(query, usage: usage)
        try expect(rows.count == 50 && rows.first?.item.path == "/Fixture/" + shallow)
        try expect(rows == regular.search(query, usage: usage, includeWebFallback: false))
        try expect(rows == Array(compact.search(query, usage: usage, limit: 100).prefix(50)))
        let empty = try SearchIndex(items: [])
        let merged = SearchPipeline().search(SearchRequest(generation: 1, index: empty, query: query, files: compact, usage: usage))
        try expect(merged == rows)
    }
}
