import Foundation

private struct Candidate {
    let item: Int
    let match: TextMatch
    let textID: Int32
    let source: MatchSource
    var pathScore: Double = 0
    var boost: Double = 0
    var score: Double { match.score + pathScore + boost }
}

extension SearchIndex {
    /// Complete top results, including display-character highlights. No I/O on the search path.
    /// A cancelled search returns no partial rows; the coordinator also guards final delivery.
    public func search(_ query: ParsedQuery, usage: UsageSnapshot = UsageSnapshot(), limit: Int = 50, includeWebFallback: Bool = true,
                       isCancelled: @Sendable () -> Bool = { false }) -> [SearchResult] {
        guard !query.isEmpty, limit > 0, !isCancelled() else { return [] }
        if query.scope == .web { return [webResult(query.text)] }
        let nameQuery = MatchQuery(query.isPath ? (query.hasTrailingSeparator ? "" : query.pathSegments.last!) : query.text)
        let parentQueries = (query.isPath ? (query.hasTrailingSeparator ? query.pathSegments : Array(query.pathSegments.dropLast())) : []).map(MatchQuery.init)
        var matcher = FuzzyMatcher(), heap: [Candidate] = []
        // Baseline measurement showed repeated ancestor scoring dominating trailing-slash queries.
        // Parent chains are interned, so one score (including failures) per chain suffices per query.
        var parentScores = Array(repeating: Double.nan, count: parentQueries.isEmpty ? 0 : folders.count)
        heap.reserveCapacity(min(limit, items.count))

        func better(_ a: Candidate, _ b: Candidate) -> Bool {
            if a.match.tier != b.match.tier { return a.match.tier < b.match.tier }
            let ak = items[a.item].kind.rank, bk = items[b.item].kind.rank
            if ak != bk { return ak < bk }
            if a.score != b.score { return a.score > b.score }
            if text.less(Int32(a.item), Int32(b.item)) { return true }
            if text.less(Int32(b.item), Int32(a.item)) { return false }
            return items[a.item].id < items[b.item].id
        }
        // Worst result at the root. O(log limit) selection, followed by sorting at most 50 rows.
        func offer(_ candidate: Candidate) {
            if heap.count < limit {
                heap.append(candidate)
                var child = heap.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    if !better(heap[parent], heap[child]) { break }
                    heap.swapAt(parent, child); child = parent
                }
            } else if better(candidate, heap[0]) {
                heap[0] = candidate
                var parent = 0
                while parent * 2 + 1 < heap.count {
                    var child = parent * 2 + 1
                    if child + 1 < heap.count && better(heap[child], heap[child + 1]) { child += 1 }
                    if !better(heap[parent], heap[child]) { break }
                    heap.swapAt(parent, child); parent = child
                }
            }
        }

        for i in items.indices {
            if i & 255 == 0 && isCancelled() { return [] }
            let item = items[i]
            guard query.includes(item.kind) else { continue }
            var maximumTier: MatchTier = .keyword
            if heap.count == limit {
                maximumTier = heap[0].match.tier
                if item.kind.rank > items[heap[0].item].kind.rank {
                    guard maximumTier.rawValue > 0 else { continue }
                    maximumTier = MatchTier(rawValue: maximumTier.rawValue - 1)!
                }
            }
            var best: Candidate?
            func consider(_ textID: Int32, source: MatchSource, keyword: Bool = false) {
                let span = text.spans[Int(textID)]
                if maximumTier == .exact && Int(span.count) != nameQuery.scalars.count { return }
                let mask = nameQuery.words.count > 1 ? nameQuery.compactMask : nameQuery.mask
                if span.mask & mask != mask { return }
                guard let match = text.withText(textID, { matcher.match(nameQuery, text: $0, mask: span.mask, keyword: keyword, maximumTier: maximumTier) }) else { return }
                let candidate = Candidate(item: i, match: match, textID: textID, source: source)
                if best == nil || match.tier < best!.match.tier || (match.tier == best!.match.tier && match.score > best!.match.score) { best = candidate }
            }
            if query.isPath && query.hasTrailingSeparator {
                guard maximumTier >= .prefix else { continue }
                best = Candidate(item: i, match: TextMatch(tier: .prefix, score: 0, compact: false), textID: Int32(i), source: .name)
            } else {
                consider(Int32(i), source: .name)
                if !query.isPath {
                    for t in sources[i].alternates { consider(t, source: .alternate(Int(t - sources[i].alternates.lowerBound))) }
                    if item.kind == .setting && best == nil && maximumTier == .keyword {
                        for t in sources[i].keywords { consider(t, source: .keyword(Int(t - sources[i].keywords.lowerBound)), keyword: true) }
                        // Several query words may refer to different keywords, in any order.
                        if best == nil && nameQuery.words.count > 1 {
                            var matched: [Int] = [], score = 0.0
                            for word in nameQuery.words {
                                if let t = sources[i].keywords.first(where: { id in text.withText(id) { matcher.starts(word, $0) } }) {
                                    matched.append(Int(t - sources[i].keywords.lowerBound))
                                    score += text.withText(t) { matcher.score(word, $0).score }
                                } else { break }
                            }
                            if matched.count == nameQuery.words.count {
                                best = Candidate(item: i, match: TextMatch(tier: .keyword, score: score, compact: false), textID: Int32(i), source: .keywords(matched))
                            }
                        }
                    }
                }
            }
            guard var candidate = best else { continue }
            if !parentQueries.isEmpty {
                let parent = sources[i].parent
                guard parent >= 0 else { continue }
                if parentScores[Int(parent)].isNaN {
                    parentScores[Int(parent)] = parentScore(parent, queries: parentQueries, matcher: &matcher) ?? -.infinity
                }
                let score = parentScores[Int(parent)]
                guard score.isFinite else { continue }
                candidate.pathScore = score
            }
            candidate.boost = usage.boost(for: item.id)
            offer(candidate)
        }
        guard !isCancelled() else { return [] }
        if heap.isEmpty { return includeWebFallback && query.scope == nil ? [webResult(query.text)] : [] }
        heap.sort(by: better)
        return heap.map { candidate in
            let positions: [Int]
            let titleID = Int32(candidate.item)
            let titleMatch: TextMatch? = candidate.source == .name ? candidate.match : text.withText(titleID) {
                matcher.match(nameQuery, text: $0, mask: text.spans[candidate.item].mask)
            }
            if let titleMatch, !nameQuery.scalars.isEmpty {
                let q = titleMatch.compact ? nameQuery.compact : nameQuery.scalars
                positions = text.displayedOffsets(text.withText(titleID) { matcher.positions(q, $0) }, text: titleID)
            } else { positions = [] }
            return SearchResult(item: items[candidate.item], tier: candidate.match.tier,
                                textScore: candidate.match.score + candidate.pathScore, usageBoost: candidate.boost,
                                source: candidate.source, highlights: positions, webQuery: nil)
        }
    }

    private func parentScore(_ parent: Int32, queries: [MatchQuery], matcher: inout FuzzyMatcher) -> Double? {
        var chain: [Int32] = [], node = parent
        while node >= 0 { chain.append(folders[Int(node)].text); node = folders[Int(node)].parent }
        chain.reverse()
        guard chain.count >= queries.count else { return nil }
        var previous = Array(repeating: -Double.infinity, count: chain.count)
        for (i, query) in queries.enumerated() {
            var row = Array(repeating: -Double.infinity, count: chain.count), earlier = -Double.infinity
            for j in chain.indices {
                let t = chain[j], span = text.spans[Int(t)]
                if span.mask & query.mask == query.mask {
                    let score: Double? = text.withText(t) { buffer in
                        matcher.hasSubsequence(query.scalars, buffer) ? matcher.score(query.scalars, buffer).score : nil
                    }
                    if let score {
                        if i == 0 { row[j] = score }
                        else if j > 0 { row[j] = score + max(earlier, previous[j - 1] + 0.2) }
                    }
                }
                earlier = max(earlier, previous[j])
            }
            previous = row
        }
        let best = previous.max() ?? -Double.infinity
        return best.isFinite ? best : nil
    }

    private func webResult(_ text: String) -> SearchResult {
        SearchResult(item: SearchItem(id: "web", kind: .web, name: text), tier: .exact, textScore: 0,
                     usageBoost: 0, source: .web, highlights: [], webQuery: text)
    }
}
