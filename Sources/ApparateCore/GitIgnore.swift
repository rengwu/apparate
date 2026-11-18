import Foundation
import Darwin

/// Git wildmatch syntax over UTF-8 bytes. Search normalization is deliberately not used.
public struct GitIgnore: Sendable {
    struct Rule: Sendable {
        var pattern: [UInt8]
        var negated: Bool
        var directoryOnly: Bool
        var anchored: Bool
    }
    let rules: [Rule]
    let ignoreCase: Bool
    public init(_ contents: String, ignoreCase: Bool = false) {
        self.ignoreCase = ignoreCase
        rules = contents.utf8.split(separator: 10, omittingEmptySubsequences: false).compactMap { line in
            var bytes = Array(line)
            if bytes.last == 13 { bytes.removeLast() }
            while bytes.last == 32 {
                var slashes = 0, i = bytes.count - 2
                while i >= 0 && bytes[i] == 92 { slashes += 1; i -= 1 }
                if slashes % 2 == 1 { break }
                bytes.removeLast()
            }
            guard !bytes.isEmpty, bytes.first != 35 else { return nil }
            let negative = bytes.first == 33
            if negative { bytes.removeFirst() }
            let directory = bytes.last == 47
            if directory { bytes.removeLast() }
            let anchored = bytes.contains(47)
            if bytes.first == 47 { bytes.removeFirst() }
            guard !bytes.isEmpty else { return nil }
            return Rule(pattern: bytes, negated: negative, directoryOnly: directory, anchored: anchored)
        }
    }
    /// Caller handles excluded parents by pruning traversal. nil means no matching rule.
    public func decision(path: String, isDirectory: Bool) -> Bool? {
        var decision: Bool?
        for rule in rules where !rule.directoryOnly || isDirectory {
            let value = rule.anchored ? path : String(path.split(separator: "/").last ?? "")
            if Self.matches(rule.pattern, Array(value.utf8), ignoreCase: ignoreCase) { decision = !rule.negated }
        }
        return decision
    }
    private static func matches(_ pattern: [UInt8], _ value: [UInt8], ignoreCase: Bool) -> Bool {
        func fold(_ c: UInt8) -> UInt8 { ignoreCase && c >= 65 && c <= 90 ? c + 32 : c }
        // Memoization bounds adversarial star/backtracking combinations.
        var memo: [Int: Bool] = [:]
        func match(_ p: Int, _ s: Int) -> Bool {
            let key = p * (value.count + 1) + s
            if let answer = memo[key] { return answer }
            let answer: Bool
            if p == pattern.count { answer = s == value.count }
            else if pattern[p] == 42 {
                var end = p + 1
                while end < pattern.count && pattern[end] == 42 { end += 1 }
                let globstar = end - p >= 2 && (p == 0 || pattern[p - 1] == 47) && (end == pattern.count || pattern[end] == 47)
                if globstar && end < pattern.count {
                    answer = match(end + 1, s) || (s < value.count && match(p, s + 1))
                } else {
                    answer = match(end, s) || (s < value.count && (globstar || value[s] != 47) && match(p, s + 1))
                }
            } else if pattern[p] == 63 {
                answer = s < value.count && value[s] != 47 && match(p + 1, s + 1)
            } else if pattern[p] == 92 {
                answer = p + 1 < pattern.count && s < value.count && fold(pattern[p + 1]) == fold(value[s]) && match(p + 2, s + 1)
            } else if pattern[p] == 91, s < value.count, value[s] != 47 {
                var i = p + 1, negate = false, found = false
                if i < pattern.count && (pattern[i] == 33 || pattern[i] == 94) { negate = true; i += 1 }
                let start = i
                if i < pattern.count && pattern[i] == 93 { found = value[s] == 93; i += 1 }
                while i < pattern.count && pattern[i] != 93 {
                    if pattern[i] == 91, i + 1 < pattern.count, pattern[i + 1] == 58,
                       let finish = (i + 2..<pattern.count).first(where: { pattern[$0] == 58 && $0 + 1 < pattern.count && pattern[$0 + 1] == 93 }) {
                        let name = String(decoding: pattern[(i + 2)..<finish], as: UTF8.self)
                        let c = Int32(value[s]), f = Int32(fold(value[s]))
                        switch name {
                        case "alnum": found = found || isalnum(c) != 0
                        case "alpha": found = found || isalpha(c) != 0
                        case "blank": found = found || isblank(c) != 0
                        case "cntrl": found = found || iscntrl(c) != 0
                        case "digit": found = found || isdigit(c) != 0
                        case "graph": found = found || isgraph(c) != 0
                        case "lower": found = found || islower(f) != 0
                        case "upper": found = found || (ignoreCase ? islower(f) : isupper(c)) != 0
                        case "print": found = found || isprint(c) != 0
                        case "punct": found = found || ispunct(c) != 0
                        case "space": found = found || isspace(c) != 0
                        case "xdigit": found = found || isxdigit(c) != 0
                        default: break
                        }
                        i = finish + 2; continue
                    }
                    if pattern[i] == 92 && i + 1 < pattern.count { i += 1 }
                    let lower = fold(pattern[i]); i += 1
                    if i + 1 < pattern.count && pattern[i] == 45 && pattern[i + 1] != 93 {
                        i += 1
                        if pattern[i] == 92 && i + 1 < pattern.count { i += 1 }
                        let upper = fold(pattern[i]); i += 1
                        found = found || (lower <= fold(value[s]) && fold(value[s]) <= upper)
                    } else { found = found || lower == fold(value[s]) }
                }
                if i < pattern.count && i > start { answer = (negate ? !found : found) && match(i + 1, s + 1) }
                else { answer = false }
            } else { answer = s < value.count && fold(pattern[p]) == fold(value[s]) && match(p + 1, s + 1) }
            memo[key] = answer; return answer
        }
        return match(0, 0)
    }
}

struct IgnoreScope: Sendable {
    let directory: String
    let rules: GitIgnore
    func decision(_ path: String, directory isDirectory: Bool) -> Bool? {
        guard path.hasPrefix(directory == "/" ? "/" : directory + "/") else { return nil }
        return rules.decision(path: String(path.dropFirst(directory == "/" ? 1 : directory.count + 1)), isDirectory: isDirectory)
    }
}
