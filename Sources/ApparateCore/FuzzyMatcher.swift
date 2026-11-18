import Foundation

struct TextMatch {
    let tier: MatchTier
    let score: Double
    let compact: Bool
}

/// Fzy recurrence (jhawthorn/fzy, MIT), adapted to Unicode scalars and finite exact scores.
/// Rolling rows are reused within a search. The full traceback is allocated for the top results only.
struct FuzzyMatcher {
    private var d: [Double] = [], m: [Double] = []
    private var dBoundary: [Bool] = [], mBoundary: [Bool] = []

    @inline(__always) func hasSubsequence(_ query: [UInt32], _ text: TextBuffer) -> Bool {
        guard !query.isEmpty, query.count <= text.count else { return false }
        var i = 0
        for j in 0..<text.count where text[j] == query[i] {
            i += 1
            if i == query.count { return true }
        }
        return false
    }

    @inline(__always) func starts(_ query: [UInt32], _ text: TextBuffer, at start: Int = 0) -> Bool {
        guard start + query.count <= text.count else { return false }
        for i in query.indices where query[i] != text[start + i] { return false }
        return true
    }

    private func wordPrefixes(_ words: [[UInt32]], _ text: TextBuffer) -> Bool {
        guard !words.isEmpty else { return false }
        var next = 0
        for word in words {
            var found = false
            while next < text.count {
                let position = next; next += 1
                if text.bonuses[position] > 0 && starts(word, text, at: position) {
                    next = position + word.count
                    // The next query word must start a different name word.
                    while next < text.count && text.bonuses[next] == 0 { next += 1 }
                    found = true; break
                }
            }
            if !found { return false }
        }
        return true
    }

    private func boundarySubsequence(_ query: [UInt32], _ text: TextBuffer) -> Bool {
        var i = 0
        for j in 0..<text.count where text.bonuses[j] > 0 && text[j] == query[i] {
            i += 1
            if i == query.count { return true }
        }
        return false
    }

    mutating func match(_ query: MatchQuery, text: TextBuffer, mask: UInt64, keyword: Bool = false,
                        maximumTier: MatchTier = .keyword) -> TextMatch? {
        guard !query.scalars.isEmpty, text.count > 0 else { return nil }
        if keyword {
            guard maximumTier == .keyword else { return nil }
            guard starts(query.scalars, text) || wordPrefixes(query.words, text) else { return nil }
            let q = hasSubsequence(query.scalars, text) ? query.scalars : query.compact
            guard hasSubsequence(q, text) else { return nil }
            return TextMatch(tier: .keyword, score: score(q, text).score, compact: q != query.scalars)
        }
        // A consecutive match at a 0.9 start bonus reaches the maximum possible score:
        // no later alignment can improve its bonus or reduce the total gap penalty.
        if starts(query.scalars, text) {
            let tier: MatchTier = query.scalars.count == text.count ? .exact : .prefix
            guard tier <= maximumTier else { return nil }
            let value = text.bonuses[0] == 9
                ? 0.9 + Double(query.scalars.count - 1) - Double(text.count - query.scalars.count) * 0.005
                : score(query.scalars, text).score
            return TextMatch(tier: tier, score: value, compact: false)
        }
        guard maximumTier >= .word else { return nil }
        let wordMatch = query.words.count > 1 && mask & query.compactMask == query.compactMask && wordPrefixes(query.words, text)
        guard (mask & query.mask == query.mask && hasSubsequence(query.scalars, text)) || wordMatch else { return nil }
        let singleWord = !wordMatch && wordPrefixes([query.scalars], text)
        if maximumTier == .word && !wordMatch && !singleWord && !boundarySubsequence(query.scalars, text) { return nil }
        let useCompact = wordMatch
        let q = useCompact ? query.compact : query.scalars
        let scored = score(q, text)
        let tier: MatchTier
        if wordMatch || scored.boundaries || singleWord { tier = .word }
        else { tier = .fuzzy }
        guard tier <= maximumTier else { return nil }
        return TextMatch(tier: tier, score: scored.score, compact: useCompact)
    }

    mutating func score(_ query: [UInt32], _ text: TextBuffer) -> (score: Double, boundaries: Bool) {
        let n = text.count
        if d.count < n {
            d = Array(repeating: -.infinity, count: n); m = d
            dBoundary = Array(repeating: false, count: n); mBoundary = dBoundary
        }
        for i in query.indices {
            var previousM = -Double.infinity, previousD = -Double.infinity, running = -Double.infinity
            var previousMB = false, previousDB = false, runningB = false
            let gap = i == query.count - 1 ? -0.005 : -0.01
            for j in 0..<n {
                let oldM = m[j], oldD = d[j], oldMB = mBoundary[j], oldDB = dBoundary[j]
                var current = -Double.infinity, boundary = false
                if query[i] == text[j] {
                    let bonus = Double(text.bonuses[j]) / 10
                    if i == 0 { current = Double(j) * -0.005 + bonus; boundary = bonus > 0 }
                    else if j > 0 {
                        let fromGap = previousM + bonus, consecutive = previousD + 1
                        if fromGap > consecutive || (fromGap == consecutive && previousMB) {
                            current = fromGap; boundary = previousMB && bonus > 0
                        } else { current = consecutive; boundary = previousDB && bonus > 0 }
                    }
                }
                let skipped = running + gap
                if current > skipped || (current == skipped && boundary) { running = current; runningB = boundary }
                else { running = skipped }
                d[j] = current; m[j] = running; dBoundary[j] = boundary; mBoundary[j] = runningB
                previousM = oldM; previousD = oldD; previousMB = oldMB; previousDB = oldDB
            }
        }
        return (m[n - 1], mBoundary[n - 1])
    }

    func positions(_ query: [UInt32], _ text: TextBuffer) -> [Int] {
        guard hasSubsequence(query, text) else { return [] }
        if text.bonuses[0] == 9 && starts(query, text) { return Array(query.indices) }
        let n = query.count, count = text.count
        var d = Array(repeating: -Double.infinity, count: n * count), m = d
        for i in 0..<n {
            let gap = i == n - 1 ? -0.005 : -0.01
            var running = -Double.infinity
            for j in 0..<count {
                let p = i * count + j
                if query[i] == text[j] {
                    if i == 0 { d[p] = Double(j) * -0.005 + Double(text.bonuses[j]) / 10 }
                    else if j > 0 { d[p] = max(m[p - count - 1] + Double(text.bonuses[j]) / 10, d[p - count - 1] + 1) }
                }
                running = max(d[p], running + gap); m[p] = running
            }
        }
        var positions = Array(repeating: 0, count: n), j = count - 1, required = false
        for i in (0..<n).reversed() {
            while j >= 0 {
                let p = i * count + j
                if d[p].isFinite && (required || d[p] == m[p]) {
                    required = i > 0 && j > 0 && d[p] == d[p - count - 1] + 1
                    positions[i] = j; j -= 1; break
                }
                j -= 1
            }
        }
        return positions
    }
}
