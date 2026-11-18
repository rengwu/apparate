import Foundation
import ApparateCore

@MainActor func observationTests(_ h: Harness) async {
    await h.test("observation: marker identity checksum and corrupt frames") {
        let marker = FrameMarker(run: 91, show: 2, revision: 123, digest: 0xfedcba9876543210)
        try expect(FrameMarker.decode(bits: marker.bits) == marker)
        for i in [0,31,32,140,287,319] { var bits = marker.bits; bits[i].toggle(); try expect(FrameMarker.decode(bits: bits) == nil) }
        try expect(FrameMarker.decode(bits: []) == nil)
    }
    await h.test("observation: bounded first frame rejects stale duplicate out-of-order and missing") {
        let a = FrameMarker(run: 1, show: 1, revision: 1, digest: 7), b = FrameMarker(run: 1, show: 1, revision: 2, digest: 8)
        var d = FrameDetector([.init(marker: a, input: 100, deadline: 200), .init(marker: b, input: 200, deadline: 300)])
        d.accept(a, at: 99); d.accept(a, at: 130); d.accept(a, at: 140); d.accept(b, at: 120); d.accept(b, at: 301)
        d.accept(FrameMarker(run: 2, show: 1, revision: 1, digest: 7), at: 302)
        try expect(d.first[a] == 130 && d.first[b] == nil && d.duplicates == 1 && d.outOfOrder == 1 && d.rejected == 3)
    }
    await h.test("observation: pixels support scale offset and reject crop/corruption") {
        let marker = FrameMarker(run: 4, show: 99, revision: 100, digest: ObservationClock.digest([]))
        for scale in [1.0, 1.5, 2.0, 3.0] {
            let bits = marker.bits
            func pixel(_ x: Int, _ y: Int) -> (UInt8,UInt8,UInt8) {
                let col = Int(Double(x - 6) / scale), row = Int(Double(y - 9) / scale)
                let value: UInt8 = bits[row * 4 + col] ? 255 : 0; return (value,value,value)
            }
            try expect(MarkerPixels.decode(width: 40, height: 260, originX: 6, originY: 9, scale: scale, pixel: pixel) == marker)
            try expect(MarkerPixels.decode(width: 40, height: 20, originX: 6, originY: 9, scale: scale, pixel: pixel) == nil)
        }
        try expect(MarkerPixels.decode(width: 40, height: 260, originX: 0, originY: 0, scale: 2, pixel: { _,_ in (128,128,128) }) == nil)
    }
}
