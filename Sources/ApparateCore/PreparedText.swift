import Foundation

// ASCII has implicit character offsets. Only non-ASCII text pays for scalar + character maps.
// A negative start encodes the offset in the Unicode buffers as -(offset + 1).
struct TextSpan: Sendable {
    let start: Int32
    let count: Int32
    let mask: UInt64
    var isASCII: Bool { start >= 0 }
    var offset: Int { isASCII ? Int(start) : -Int(start) - 1 }
}

@inline(__always) func characterBit(_ value: UInt32) -> UInt64 {
    let bit = value >= 97 && value <= 122 ? value - 97 :
        (value >= 48 && value <= 57 ? value - 48 + 26 : value % 28 + 36)
    return 1 << bit
}

struct FoldedText {
    var scalars: [UInt32] = []
    var bonuses: [UInt8] = []
    var characters: [Int32] = []
    var mask: UInt64 = 0

    init(_ text: String) {
        var previous: Character = "/"
        for (offset, character) in text.enumerated() {
            let bonus: UInt8
            if previous == "/" { bonus = 9 }
            else if previous.isWhitespace || previous == "-" || previous == "_" { bonus = 8 }
            else if previous.isLowercase && character.isUppercase { bonus = 7 }
            else if previous == "." { bonus = 6 }
            else { bonus = 0 }
            let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            for (i, scalar) in folded.unicodeScalars.enumerated() {
                scalars.append(scalar.value)
                // An expansion (ß -> ss) creates one word start, not two.
                bonuses.append(i == 0 ? bonus : 0)
                characters.append(Int32(offset))
                mask |= characterBit(scalar.value)
            }
            previous = character
        }
    }
}

struct TextStore: Sendable {
    var spans: [TextSpan] = []
    var ascii: [UInt8] = []
    var asciiBonuses: [UInt8] = []
    var unicode: [UInt32] = []
    var unicodeBonuses: [UInt8] = []
    var characterOffsets: [Int32] = []

    mutating func append(_ text: String) -> Int32 {
        let id = Int32(spans.count)
        // CRLF is one displayed Character despite containing two ASCII bytes.
        if text.utf8.allSatisfy({ $0 < 128 }) && !text.contains("\r\n") {
            let start = Int32(ascii.count)
            var previous: UInt8 = 47, mask: UInt64 = 0
            for byte in text.utf8 {
                let lower = byte >= 65 && byte <= 90 ? byte + 32 : byte
                ascii.append(lower); mask |= characterBit(UInt32(lower))
                let bonus: UInt8
                if previous == 47 { bonus = 9 }
                else if previous == 32 || previous == 45 || previous == 95 || (9...13).contains(previous) { bonus = 8 }
                else if (97...122).contains(previous) && (65...90).contains(byte) { bonus = 7 }
                else if previous == 46 { bonus = 6 }
                else { bonus = 0 }
                asciiBonuses.append(bonus); previous = byte
            }
            spans.append(TextSpan(start: start, count: Int32(ascii.count) - start, mask: mask))
        } else {
            let folded = FoldedText(text)
            spans.append(TextSpan(start: -Int32(unicode.count) - 1, count: Int32(folded.scalars.count), mask: folded.mask))
            unicode.append(contentsOf: folded.scalars); unicodeBonuses.append(contentsOf: folded.bonuses)
            characterOffsets.append(contentsOf: folded.characters)
        }
        return id
    }

    @inline(__always) func withText<T>(_ id: Int32, _ body: (TextBuffer) -> T) -> T {
        let span = spans[Int(id)], start = span.offset, count = Int(span.count)
        if span.isASCII {
            return ascii.withUnsafeBufferPointer { text in
                asciiBonuses.withUnsafeBufferPointer { bonuses in
                    body(TextBuffer(bytes: UnsafeBufferPointer(rebasing: text[start..<(start + count)]), scalars: nil,
                                    bonuses: UnsafeBufferPointer(rebasing: bonuses[start..<(start + count)])))
                }
            }
        }
        return unicode.withUnsafeBufferPointer { text in
            unicodeBonuses.withUnsafeBufferPointer { bonuses in
                body(TextBuffer(bytes: nil, scalars: UnsafeBufferPointer(rebasing: text[start..<(start + count)]),
                                bonuses: UnsafeBufferPointer(rebasing: bonuses[start..<(start + count)])))
            }
        }
    }

    func displayedOffsets(_ positions: [Int], text: Int32) -> [Int] {
        let span = spans[Int(text)]
        if span.isASCII { return positions }
        var mapped: [Int] = []
        for p in positions {
            let value = Int(characterOffsets[span.offset + p])
            if mapped.last != value { mapped.append(value) }
        }
        return mapped
    }

    func less(_ lhs: Int32, _ rhs: Int32) -> Bool {
        withText(lhs) { a in withText(rhs) { b in
            for i in 0..<min(a.count, b.count) { if a[i] != b[i] { return a[i] < b[i] } }
            return a.count < b.count
        } }
    }
}

// Pointers never escape TextStore.withText's lifetime and are never stored in a Sendable value.
struct TextBuffer {
    let bytes: UnsafeBufferPointer<UInt8>?
    let scalars: UnsafeBufferPointer<UInt32>?
    let bonuses: UnsafeBufferPointer<UInt8>
    var count: Int { bonuses.count }
    @inline(__always) subscript(_ i: Int) -> UInt32 { bytes.map { UInt32($0[i]) } ?? scalars![i] }
}

struct MatchQuery {
    let scalars: [UInt32]
    let compact: [UInt32]
    let words: [[UInt32]]
    let mask: UInt64
    let compactMask: UInt64
    init(_ text: String) {
        scalars = FoldedText(text).scalars
        words = text.split(whereSeparator: \.isWhitespace).map { FoldedText(String($0)).scalars }
        compact = words.flatMap { $0 }
        mask = scalars.reduce(0) { $0 | characterBit($1) }
        compactMask = compact.reduce(0) { $0 | characterBit($1) }
    }
}
