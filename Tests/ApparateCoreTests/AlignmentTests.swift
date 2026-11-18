import Foundation
import ApparateCore

@MainActor func alignmentTests(_ h: Harness) async {
    await h.test("scoring and traceback: exhaustive alignment oracle on 300 short names") {
        var random = SeededRandom(state: 0xA11E), config = AppConfig()
        config.prefixes = ["apps": "@"]
        let alphabet = Array("abcABC._-")
        for _ in 0..<300 {
            let name = (0..<(5 + random.int(7))).map { _ in alphabet[random.int(alphabet.count)] }
            let lower = name.map { Character(String($0).lowercased()) }
            let query = lower.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
            func bonus(_ p: Int) -> Double {
                if p == 0 { return 0.9 }
                if name[p - 1] == "_" || name[p - 1] == "-" { return 0.8 }
                if name[p - 1].isLowercase && name[p].isUppercase { return 0.7 }
                if name[p - 1] == "." { return 0.6 }
                return 0
            }
            func alignmentScore(_ positions: [Int]) -> Double {
                var score = Double(positions[0]) * -0.005 + bonus(positions[0])
                for i in 1..<positions.count {
                    let gap = positions[i] - positions[i - 1] - 1
                    score += gap == 0 ? 1 : Double(gap) * -0.01 + bonus(positions[i])
                }
                return score + Double(name.count - positions.last! - 1) * -0.005
            }
            var best = -Double.infinity
            func enumerate(_ positions: [Int]) {
                if positions.count == query.count { best = max(best, alignmentScore(positions)); return }
                for p in ((positions.last ?? -1) + 1)..<name.count where lower[p] == query[positions.count] {
                    enumerate(positions + [p])
                }
            }
            enumerate([])
            let row = try search([fixture(String(name))], "@ " + String(query), config: config)[0]
            try near(row.textScore, best)
            try expect(row.highlights.map { lower[$0] } == query)
            try near(alignmentScore(row.highlights), best)
        }
    }
}
