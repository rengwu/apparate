import Foundation
import ApparateCore

@MainActor func rankingTests(_ h: Harness) async {
    let apps = [fixture("Visual Studio Code", alternates: ["Code"]), fixture("Terminal"), fixture("Calculator"), fixture("Calendar"),
                fixture("Keyboard layouts", .setting, keywords: ["input", "languages"]), fixture("Text replacements", .setting),
                fixture("Restart", .command), fixture("Resources", .folder), fixture("README.md", .file), fixture("Preview"),
                fixture("code-review.md", .file), fixture("terminal-notes.md", .file), fixture("term.txt", .file)]
    await h.test("ranking: golden queries, tiers and kind order") {
        for (query, expected) in [("vsc", "Visual Studio Code"), ("code", "Visual Studio Code"), ("keyboard la", "Keyboard layouts"),
                                  ("term", "Terminal"), ("calc", "Calculator"), ("cale", "Calendar")] {
            let result = try search(apps, query)
            try expect(result.first?.item.name == expected, "\(query): \(result.map(\.item.name))")
        }
        let vsc = try search([fixture("Visual Studio Code")], "vsc")[0]
        try expect(vsc.tier == .word && vsc.highlights == [0, 7, 14])
        let code = try search(apps, "code")[0]
        try expect(code.source == .alternate(0) && code.highlights.isEmpty && code.textScore.isFinite)
        let re = try search(apps.filter { ["Restart", "Resources", "README.md", "Text replacements", "Preview"].contains($0.name) }, "re").map(\.item.name)
        try expect(re == ["Restart", "Resources", "README.md", "Text replacements", "Preview"], "re: \(re)")
        let tier = try search([fixture("Terminal"), fixture("tml-prefix.txt", .file)], "tml")
        try expect(tier.first?.item.kind == .file && tier.last?.tier == .fuzzy)
    }
    await h.test("ranking: keyword tier, split keywords and word prefixes") {
        let rows = try search([fixture("Other", .setting, keywords: ["network", "dns"]), fixture("DNS.txt", .file)], "dns")
        try expect(rows.map(\.tier) == [.prefix, .keyword])
        try expect(rows[1].source == .keyword(1) && rows[1].highlights.isEmpty)
        let multi = try search(apps, "input la")[0]
        try expect(multi.item.name == "Keyboard layouts" && multi.source == .keywords([0, 1]) && multi.highlights.isEmpty)
        for name in ["Keyboard layouts", "KeyboardLayouts", "Keyboard   layouts"] {
            let row = try search([fixture(name)], "keyboard  la")[0]
            try expect(row.tier == .word && row.item.kind == .app, "Word tokens failed for \(name)")
        }
    }
    await h.test("ranking: deterministic ties, duplicate names and bounded top 50") {
        let items = (0..<180).map { i in fixture(i < 2 ? "Alpha" : "Alpha \(String(format: "%03d", i))", .app, id: "app:\(String(format: "%03d", i))") }
        let index = try SearchIndex(items: items.reversed())
        let rows = index.search(ParsedQuery("alpha"))
        try expect(rows.count == 50 && rows[0].item.id == "app:000" && rows[1].item.id == "app:001")
        let exhaustive = index.search(ParsedQuery("alpha"), limit: items.count)
        try expect(rows == Array(exhaustive.prefix(50)))
        let otherOrder = try SearchIndex(items: items).search(ParsedQuery("alpha"))
        try expect(rows == otherOrder)
        for _ in 0..<10 { try expect(index.search(ParsedQuery("alpha")) == rows) }
        do { _ = try SearchIndex(items: [items[0], items[0]]); throw TestFailure(description: "Duplicate ID accepted") }
        catch IndexError.duplicateID { }
        try expect(ItemID.setting(bundle: "a?b", anchor: "c", title: "d") != ItemID.setting(bundle: "a", anchor: "b?c", title: "d"))
    }
    await h.test("scopes and fallback: explicit prefixes, reconfiguration and whitespace") {
        let items = [fixture("Notes"), fixture("notes.md", .file), fixture("Notes", .folder), fixture("DNS", .setting)]
        try expect(try search(items, "'notes").allSatisfy { [.file, .folder].contains($0.item.kind) })
        try expect(try search(items, ".dns").map(\.item.kind) == [.setting])
        try expect(try search(items, "?swift  actors").first?.webQuery == "swift  actors")
        for empty in ["", "   ", "?", "' ", "."] { try expect(try search(items, empty).isEmpty) }
        try expect(try search(items, "' notes") == search(items, "'notes"))
        for query in ["'zzzz", ".zzzz"] { try expect(try search(items, query).isEmpty) }
        try expect(try search(items, "zzzz").map(\.item.kind) == [.web])
        try expect(try search(items, "notes").allSatisfy { $0.item.kind != .web })
        var config = AppConfig(); config.prefixes = ["files": "!", "apps": "@", "commands": ":"]
        try expect(ParsedQuery("'notes", config: config).scope == nil)
        try expect(try search(items, "'notes", config: config).first?.webQuery == "'notes")
        try expect(try search(items, "! notes", config: config).allSatisfy { [.file, .folder].contains($0.item.kind) })
        try expect(try search(items, "@zzzz", config: config).isEmpty)
        try expect(try search(items, "@notes", config: config).map(\.item.kind) == [.app])
        try expect(ParsedQuery("@a/b", config: config).isPath == false)
        try expect(try search(apps, ":rest", config: config).map(\.item.kind) == [.command])
    }
    await h.test("path mode: ordered segments, roots, trailing and repeated separators") {
        let items = [fixture("Sources", .folder, path: "/Fixture/Projects/klip/Sources"),
                     fixture("Sources.swift", .file, path: "/Fixture/Projects/klip/Sources/Sources.swift"),
                     fixture("klip", .folder, path: "/Fixture/Projects/klip"),
                     fixture("Notes.md", .file, path: "/Fixture/Projects/other/Notes.md"), fixture("klip/sources")]
        for query in ["klip/sources", "'klip/sources", "projects/klip/sources", "klip//sources", "~/projects/klip/sources", "/projects/klip/sources"] {
            let rows = try search(items, query)
            try expect(rows.first?.item.name == "Sources" && rows.count == 2, query)
            try expect(rows.allSatisfy { $0.textScore.isFinite })
        }
        let trailing = try search(items, "klip/")
        try expect(Set(trailing.map(\.item.name)) == Set(["Sources", "Sources.swift"]))
        try expect(try search(items, "sources/klip").allSatisfy { $0.item.kind == .web })
        for q in ["/", "///", "~/", "'//"] { try expect(try search(items, q).isEmpty, q) }
        try expect(try search(items, "?a/b").first?.webQuery == "a/b")
        try expect(try search(items, "klip/klip/sources").first?.item.kind == .web, "One ancestor used twice")
    }
    await h.test("cancellation: no partial results") {
        let index = try SearchIndex(items: apps)
        try expect(index.search(ParsedQuery("re"), isCancelled: { true }).isEmpty)
    }
    await h.test("top selection: tier pruning agrees with exhaustive results across scopes and paths") {
        var random = SeededRandom(state: 0xB0A7DED)
        let names = ["Alpha", "Visual Studio Code", "Archive", "Café", "Network", "Notes", "Sources", "README", "Text replacements"]
        let kinds: [ItemKind] = [.app, .command, .setting, .folder, .file]
        let items = (0..<400).map { i -> SearchItem in
            let name = names[random.int(names.count)] + "-\(i)", kind = kinds[random.int(kinds.count)]
            return fixture(name, kind, id: "fixture:\(i)", alternates: kind == .app ? ["Code"] : [],
                           keywords: kind == .setting ? ["keyboard", "dns", "input"] : [],
                           path: "/Fixture/Projects/Project-\(i % 12)/Sources/\(name)")
        }
        let index = try SearchIndex(items: items), reverse = try SearchIndex(items: items.reversed())
        let usage = UsageSnapshot(counts: ["fixture:2": 20, "fixture:38": 20])
        for q in ["a", "ar", "code", "vsc", "network", "re", "t r", "cafe", ".dns", ".key input", "'notes", "project/s", "project/", "sources/", "sources/sources/a", "zzqv"] {
            let query = ParsedQuery(q), full = index.search(query, usage: usage, limit: items.count)
            for limit in [1, 5, 50] {
                let expected = Array(full.prefix(limit))
                try expect(index.search(query, usage: usage, limit: limit) == expected, "Pruning differed for \(q), limit \(limit)")
                try expect(reverse.search(query, usage: usage, limit: limit) == expected, "Input order differed for \(q)")
            }
        }
    }
}

struct SeededRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

@MainActor func unicodeTests(_ h: Harness) async {
    await h.test("Unicode: normalization, expansion and displayed-character highlights") {
        let items = [fixture("Café", id: "composed"), fixture("Cafe\u{301}", id: "decomposed")]
        for query in ["cafe", "café"] {
            let rows = try search(items, query)
            try expect(rows.count == 2 && rows.allSatisfy { $0.tier == .exact && $0.highlights == [0, 1, 2, 3] })
        }
        let street = try search([fixture("Straße")], "strasse")[0]
        try expect(street.highlights == [0, 1, 2, 3, 4, 5] && street.tier == .exact)
        let cjk = try search([fixture("東京資料")], "東京")[0]
        try expect(cjk.highlights == [0, 1])
        let emoji = try search([fixture("👩🏽‍💻 Notes 📚")], "👩🏽‍💻n📚")[0]
        try expect(emoji.highlights == [0, 2, 8], "Emoji highlights: \(emoji.highlights)")
        let wide = try search([fixture("Ｃｏｄｅ")], "code")[0]
        try expect(wide.tier == .exact && wide.highlights == [0, 1, 2, 3])
        let mark = try search([fixture(""), fixture("\u{301}"), fixture("Alpha")], "\u{301}")[0]
        try expect(mark.tier == .exact && mark.highlights == [0])
        try expect(try search([fixture("")], "alpha").first?.item.kind == .web)
        let crlf = try search([fixture("A\r\nB")], "ab")[0]
        try expect(crlf.highlights == [0, 2], "CRLF must count as one displayed character")
    }
    await h.test("matching: no inherited name or query length caps") {
        let row = try search([fixture(String(repeating: "a", count: 300))], String(repeating: "a", count: 100))[0]
        try expect(row.item.kind == .app && row.highlights.count == 100 && row.textScore.isFinite)
    }
    await h.test("mask property: 1200 random Unicode subsequences survive filtering") {
        var random = SeededRandom(state: 0x4170706172617465)
        let alphabet = Array("abZ9 _-/éß東京👩🏽‍💻Ａ")
        for i in 0..<1200 {
            let name = String((0..<(4 + random.int(28))).map { _ in alphabet[random.int(alphabet.count)] })
            let folded = name.map { String($0).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }.joined()
            let scalars = Array(folded.unicodeScalars)
            let chosen = scalars.enumerated().filter { $0.offset % 3 == 0 }.map { $0.element }
            let q = String(String.UnicodeScalarView(chosen)).trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { continue }
            var config = AppConfig(); config.prefixes = [:]
            // Slash invokes path mode; this property concerns the name mask.
            config.prefixes["apps"] = "@"
            // A separator keeps a leading combining scalar in q from joining the prefix grapheme.
            let result = try search([fixture(name, id: "random:\(i)")], "@ " + q, config: config)
            try expect(result.first?.item.kind == .app, "Subsequence lost at case \(i); name=\(name.debugDescription); query=\(q.debugDescription)")
            try expect(result[0].highlights.allSatisfy { $0 >= 0 && $0 < name.count })
        }
    }
}
