import Foundation

private struct FileCandidate {
    let id: Int32
    let kind: ItemKind
    let match: TextMatch
    let pathScore: Double
    let boost: Double
    var score: Double { match.score + pathScore + boost }
}
extension FileIndexSnapshot {
    func resolve(_ usage: UsageSnapshot) -> [Int32: Double] {
        var resolved: [Int32: Double] = [:]
        for (key, boost) in usage.boosts {
            let prefix = key.hasPrefix("folder:") ? "folder:" : "file:"
            guard key.hasPrefix(prefix), let id = find(String(key.dropFirst(prefix.count))), let node = node(id),
                  searchable(node), (node.kind == .folder) == (prefix == "folder:") else { continue }
            resolved[id] = boost
        }
        return resolved
    }
    public func search(_ query: ParsedQuery, usage: UsageSnapshot = UsageSnapshot(), limit: Int = 50,
                       isCancelled: @Sendable () -> Bool = { false }) -> [SearchResult] {
        let files = search(query, boosts: resolve(usage), limit: limit, isCancelled: isCancelled)
        let apps = applications?.index.search(query, usage: usage, limit: limit, includeWebFallback: false, isCancelled: isCancelled) ?? []
        guard !isCancelled() else { return [] }
        if apps.isEmpty { return files }
        if files.isEmpty { return apps }
        return Array((files + apps).sorted(by: SearchResult.rankedBefore).prefix(limit))
    }
    func search(_ query: ParsedQuery, boosts: [Int32: Double], limit: Int = 50,
                isCancelled: @Sendable () -> Bool) -> [SearchResult] {
        guard !query.isEmpty, limit > 0, query.scope == nil || query.scope == .files else { return [] }
        let nameQuery = MatchQuery(query.isPath ? (query.hasTrailingSeparator ? "" : query.pathSegments.last!) : query.text)
        let parentQueries = (query.isPath ? (query.hasTrailingSeparator ? query.pathSegments : Array(query.pathSegments.dropLast())) : []).map(MatchQuery.init)
        var matcher = FuzzyMatcher(), heap: [FileCandidate] = [], parentScores: [Int32: Double] = [:]
        heap.reserveCapacity(limit)
        func nameLess(_ a: Int32, _ b: Int32) -> Bool {
            let ca = chunks[Int(a) / FileChunk.size], cb = chunks[Int(b) / FileChunk.size]
            return ca.text.withText(a % Int32(FileChunk.size)) { x in cb.text.withText(b % Int32(FileChunk.size)) { y in
                for i in 0..<min(x.count, y.count) { if x[i] != y[i] { return x[i] < y[i] } }
                return x.count < y.count
            } }
        }
        func better(_ a: FileCandidate, _ b: FileCandidate) -> Bool {
            if a.match.tier != b.match.tier { return a.match.tier < b.match.tier }
            if a.kind.rank != b.kind.rank { return a.kind.rank < b.kind.rank }
            if a.score != b.score { return a.score > b.score }
            if nameLess(a.id, b.id) { return true }
            if nameLess(b.id, a.id) { return false }
            return pathLess(a.id, b.id)
        }
        func offer(_ c: FileCandidate) {
            if heap.count < limit {
                heap.append(c); var i = heap.count - 1
                while i > 0 { let p = (i - 1) / 2; if !better(heap[p], heap[i]) { break }; heap.swapAt(p, i); i = p }
            } else if better(c, heap[0]) {
                heap[0] = c; var i = 0
                while i * 2 + 1 < heap.count {
                    var child = i * 2 + 1
                    if child + 1 < heap.count && better(heap[child], heap[child + 1]) { child += 1 }
                    if !better(heap[i], heap[child]) { break }; heap.swapAt(i, child); i = child
                }
            }
        }
        for (chunkID, chunk) in chunks.enumerated() {
            if isCancelled() { return [] }
            let kinds = restrictedKinds?[chunkID] ?? chunk.kinds
            for offset in kinds.indices {
                guard let kind = kinds[offset] else { continue }
                let id = Int32(chunkID * FileChunk.size + offset), textID = Int32(offset)
                var maximumTier: MatchTier = .keyword
                if heap.count == limit {
                    maximumTier = heap[0].match.tier
                    if kind.rank > heap[0].kind.rank {
                        guard maximumTier.rawValue > 0 else { continue }
                        maximumTier = MatchTier(rawValue: maximumTier.rawValue - 1)!
                    }
                }
                let match: TextMatch
                if query.isPath && query.hasTrailingSeparator {
                    guard maximumTier >= .prefix else { continue }
                    match = TextMatch(tier: .prefix, score: 0, compact: false)
                } else {
                    let span = chunk.text.spans[offset], mask = nameQuery.words.count > 1 ? nameQuery.compactMask : nameQuery.mask
                    if span.mask & mask != mask || (maximumTier == .exact && Int(span.count) != nameQuery.scalars.count) { continue }
                    guard let found = chunk.text.withText(textID, { matcher.match(nameQuery, text: $0, mask: span.mask, maximumTier: maximumTier) }) else { continue }
                    match = found
                }
                var pathScore = 0.0
                if !parentQueries.isEmpty {
                    let parent = chunk.parents[offset]
                    guard parent >= 0 else { continue }
                    if parentScores[parent] == nil { parentScores[parent] = scoreParents(parent, queries: parentQueries, matcher: &matcher) ?? -.infinity }
                    pathScore = parentScores[parent]!
                    guard pathScore.isFinite else { continue }
                }
                offer(FileCandidate(id: id, kind: kind, match: match, pathScore: pathScore, boost: boosts[id] ?? 0))
            }
        }
        guard !isCancelled() else { return [] }
        return heap.sorted(by: better).compactMap { c in
            guard let entry = entry(c.id) else { return nil }
            let chunk = chunks[Int(c.id) / FileChunk.size], textID = c.id % Int32(FileChunk.size)
            let q = c.match.compact ? nameQuery.compact : nameQuery.scalars
            let highlights = q.isEmpty ? [] : chunk.text.displayedOffsets(chunk.text.withText(textID) { matcher.positions(q, $0) }, text: textID)
            return SearchResult(item: entry.item, tier: c.match.tier, textScore: c.match.score + c.pathScore,
                                usageBoost: c.boost, source: .name, highlights: highlights, webQuery: nil)
        }
    }
    private func scoreParents(_ parent: Int32, queries: [MatchQuery], matcher: inout FuzzyMatcher) -> Double? {
        var chain: [Int32] = [], current = parent
        while current >= 0 {
            chain.append(current)
            current = chunks[Int(current) / FileChunk.size].parents[Int(current) % FileChunk.size]
        }
        chain.reverse()
        guard chain.count >= queries.count else { return nil }
        var previous = Array(repeating: -Double.infinity, count: chain.count)
        for (i, query) in queries.enumerated() {
            var row = Array(repeating: -Double.infinity, count: chain.count), earlier = -Double.infinity
            for j in chain.indices {
                let id = chain[j], chunk = chunks[Int(id) / FileChunk.size], textID = id % Int32(FileChunk.size), span = chunk.text.spans[Int(textID)]
                if span.mask & query.mask == query.mask {
                    let score: Double? = chunk.text.withText(textID) { buffer in matcher.hasSubsequence(query.scalars, buffer) ? matcher.score(query.scalars, buffer).score : nil }
                    if let score { if i == 0 { row[j] = score } else if j > 0 { row[j] = score + max(earlier, previous[j - 1] + 0.2) } }
                }
                earlier = max(earlier, previous[j])
            }
            previous = row
        }
        let score = previous.max() ?? -.infinity
        return score.isFinite ? score : nil
    }
    /// Only ties need path comparison. Walk UTF-8 components without constructing full paths.
    private func pathLess(_ lhs: Int32, _ rhs: Int32) -> Bool {
        func chain(_ id: Int32) -> [Int32] {
            var result: [Int32] = [], current = id
            while current >= 0 {
                result.append(current)
                current = chunks[Int(current) / FileChunk.size].parents[Int(current) % FileChunk.size]
            }
            return result.reversed()
        }
        let left = chain(lhs), right = chain(rhs)
        if left.first == right.first {
            // Most ties are equal directory names below the same root. Shared ancestors
            // are identical by node ID; compare the first different component only.
            // Include the following slash: "a/x" sorts after "a.txt/x", unlike "a".
            for i in 0..<min(left.count, right.count) where left[i] != right[i] {
                let a = node(left[i])!.name + (i + 1 < left.count ? "/" : "")
                let b = node(right[i])!.name + (i + 1 < right.count ? "/" : "")
                if a != b { return a < b }
            }
            return left.count < right.count
        }
        func pieces(_ id: Int32) -> [String] {
            var result: [String] = [], current = id
            while let n = node(current) {
                if let anchor = n.anchor { result.append(anchor); break }
                result.append(n.name); result.append("/"); current = n.parent
            }
            return result.reversed()
        }
        // Swift String's lexical order is canonical-equivalence aware, as is the M1 ID tie
        // break. Normalize individual components so composed/decomposed names compare equally.
        let a = pieces(lhs).lazy.flatMap { $0.precomposedStringWithCanonicalMapping.utf8 }
        let b = pieces(rhs).lazy.flatMap { $0.precomposedStringWithCanonicalMapping.utf8 }
        return a.lexicographicallyPrecedes(b)
    }
}

extension SearchResult {
    /// Each source already returns rank-ordered rows. Merge only their heads, preserving
    /// source order for equal rows and the highest-ranked occurrence of duplicate IDs.
    package static func merge(_ groups: [[SearchResult]], limit: Int = 50) -> [SearchResult] {
        guard limit > 0 else { return [] }
        var offsets = Array(repeating: 0, count: groups.count), seen = Set<String>(), result: [SearchResult] = []
        result.reserveCapacity(limit)
        while result.count < limit {
            var best: Int?
            for group in groups.indices where offsets[group] < groups[group].count {
                if best == nil || rankedBefore(groups[group][offsets[group]], groups[best!][offsets[best!]]) { best = group }
            }
            guard let best else { break }
            let row = groups[best][offsets[best]]; offsets[best] += 1
            if seen.insert(row.item.id).inserted { result.append(row) }
        }
        return result
    }
    package static func rankedBefore(_ a: SearchResult, _ b: SearchResult) -> Bool {
        if a.tier != b.tier { return a.tier < b.tier }
        if a.item.kind.rank != b.item.kind.rank { return a.item.kind.rank < b.item.kind.rank }
        let x = a.textScore + a.usageBoost, y = b.textScore + b.usageBoost
        if x != y { return x > y }
        let an = FoldedText(a.item.name).scalars, bn = FoldedText(b.item.name).scalars
        if an != bn { return an.lexicographicallyPrecedes(bn) }
        return a.item.id < b.item.id
    }
}

// Owned exclusively by SearchCoordinator's serial worker; never accessed on MainActor.
final class FileUsageCache: @unchecked Sendable {
    private var index: UUID?, usage: UUID?
    private var boosts: [Int32: Double] = [:]
    func resolve(_ file: FileIndexSnapshot, _ snapshot: UsageSnapshot) -> [Int32: Double] {
        if index != file.identity || usage != snapshot.identity {
            boosts = file.resolve(snapshot); index = file.identity; usage = snapshot.identity
        }
        return boosts
    }
}
