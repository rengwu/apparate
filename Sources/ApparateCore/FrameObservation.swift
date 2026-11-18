import Foundation
import Darwin
import CryptoKit

/// Shared with the external observer: SCStream displayTime uses mach absolute ticks.
package enum ObservationClock {
    package static var now: UInt64 { mach_absolute_time() }
    package static let timebase: (UInt32, UInt32) = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return (t.numer, t.denom) }()
    package static func milliseconds(_ start: UInt64, _ end: UInt64) -> Double { (Double(end) - Double(start)) * Double(timebase.0) / Double(timebase.1) / 1e6 }
    package static func after(_ start: UInt64, milliseconds: Double) -> UInt64 { start + UInt64(milliseconds * 1e6 * Double(timebase.1) / Double(timebase.0)) }
    package static func digest(_ rows: [SearchResult]) -> UInt64 {
        let text = rows.map { "\($0.item.id)|\($0.tier.rawValue)|\($0.textScore.bitPattern)|\($0.usageBoost.bitPattern)|\($0.source)|\($0.highlights)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
package struct FrameMarker: Hashable, Codable, Sendable {
    package let run: UInt64, show: UInt64, revision: UInt64, digest: UInt64
    package init(run: UInt64, show: UInt64, revision: UInt64, digest: UInt64) { self.run = run; self.show = show; self.revision = revision; self.digest = digest }
    package static let columns = 4, rows = 80
    private static func checksum(_ bytes: [UInt8]) -> UInt32 { bytes.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 } }
    package var bytes: [UInt8] {
        var bytes: [UInt8] = [65, 80, 80, 54]
        for value in [run, show, revision, digest] { for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) } }
        let checksum = Self.checksum(bytes)
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: checksum >> shift)) }
        return bytes
    }
    package var bits: [Bool] { bytes.flatMap { byte in (0..<8).map { byte & (1 << $0) != 0 } } }
    package static func decode(bits: [Bool]) -> Self? {
        guard bits.count == 320 else { return nil }
        let bytes = stride(from: 0, to: 320, by: 8).map { i in (0..<8).reduce(UInt8(0)) { $0 | (bits[i + $1] ? (1 << $1) : 0) } }
        guard Array(bytes.prefix(4)) == [65,80,80,54] else { return nil }
        func integer(_ start: Int, _ count: Int) -> UInt64 { (0..<count).reduce(0) { $0 | (UInt64(bytes[start + $1]) << ($1 * 8)) } }
        guard integer(36,4) == UInt64(checksum(Array(bytes.prefix(36)))) else { return nil }
        return Self(run: integer(4,8), show: integer(12,8), revision: integer(20,8), digest: integer(28,8))
    }
}
package struct FrameExpectation: Codable, Sendable {
    package let marker: FrameMarker
    package let input: UInt64, deadline: UInt64
    package init(marker: FrameMarker, input: UInt64, deadline: UInt64) { self.marker = marker; self.input = input; self.deadline = deadline }
}
/// BGRA buffer decoder, also used with synthetic frames at different scales/offsets.
package enum MarkerPixels {
    package static func decode(width: Int, height: Int, originX: Double, originY: Double, scale: Double,
                               pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> FrameMarker? {
        guard scale >= 1, scale <= 4, originX.isFinite, originY.isFinite else { return nil }
        var bits: [Bool] = []; bits.reserveCapacity(320)
        for i in 0..<320 {
            let x = Int(floor(originX + (Double(i % 4) + 0.5) * scale))
            let y = Int(floor(originY + (Double(i / 4) + 0.5) * scale))
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let (r,g,b) = pixel(x,y)
            if r >= 215 && g >= 215 && b >= 215 { bits.append(true) }
            else if r <= 40 && g <= 40 && b <= 40 { bits.append(false) }
            else { return nil }
        }
        return FrameMarker.decode(bits: bits)
    }
}
/// Single-owner state; callers serialize frame delivery. Every expectation has an end.
package struct FrameDetector {
    package let expected: [FrameExpectation]
    package private(set) var first: [FrameMarker: UInt64] = [:]
    package private(set) var rejected = 0, duplicates = 0, outOfOrder = 0
    private var last: UInt64 = 0
    package init(_ expected: [FrameExpectation]) { self.expected = expected }
    package mutating func accept(_ marker: FrameMarker?, at time: UInt64) {
        guard time >= last else { outOfOrder += 1; return }; last = time
        guard let marker, let event = expected.first(where: { $0.marker == marker }), time >= event.input, time <= event.deadline else { rejected += 1; return }
        guard first[marker] == nil else { duplicates += 1; return }
        first[marker] = time
    }
}
