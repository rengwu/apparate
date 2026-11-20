import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import ApparateCore
import Synchronization

/// A single-window observer. Capture mode must be launched separately after user consent.
/// Self-test never calls preflight, content enumeration, or any capture API.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    struct State: Sendable { var rows: [[String: String]] = []; var stopped = false }
    let state = Mutex(State())
    func stream(_ stream: SCStream, didStopWithError error: any Error) { state.withLock { $0.stopped = true } }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let callback = ObservationClock.now
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let a = attachments.first else {
            state.withLock { $0.rows.append(["callback_ticks": "\(callback)", "status": "missing-attachments"]) }; return
        }
        let status = (a[.status] as? NSNumber)?.intValue ?? -1
        let display = (a[.displayTime] as? NSNumber)?.uint64Value
        var row = ["callback_ticks": "\(callback)", "status": "\(status)", "display_ticks": display.map(String.init) ?? ""]
        let contentScale = (a[.contentScale] as? NSNumber)?.doubleValue ?? 0
        let scaleFactor = (a[.scaleFactor] as? NSNumber)?.doubleValue ?? 0
        row["content_scale"] = "\(contentScale)"; row["scale_factor"] = "\(scaleFactor)"
        let rect = (a[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        if let rect { row["content_x"] = "\(rect.minX)"; row["content_y"] = "\(rect.minY)"; row["content_width"] = "\(rect.width)"; row["content_height"] = "\(rect.height)" }
        if status == SCFrameStatus.complete.rawValue, display != nil, let rect, let buffer = CMSampleBufferGetImageBuffer(sample),
           CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
            row["width"] = "\(width)"; row["height"] = "\(height)"
            // The capture canvas fits the maximum panel; contentRect changes each frame.
            // Reject invalid geometry rather than decoding a stretched/partial window. Metadata is retained so
            // first authorized live calibration can reject rather than hide a scale mismatch.
            let scale = contentScale * scaleFactor
            row["point_width"] = "\(rect.width / scale)"; row["point_height"] = "\(rect.height / scale)"
            let geometryOK = scale >= 1 && scale <= 4 && abs(rect.width / scale - PanelLayout.width) < 1 && (PanelLayout.stripHeight - 1...PanelLayout.maximumHeight + 1).contains(rect.height / scale)
            row["geometry_valid"] = String(geometryOK)
            if geometryOK, let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                let marker = MarkerPixels.decode(width: width, height: height, originX: rect.minX + 588 * scale, originY: rect.minY + 16 * scale, scale: scale) { x,y in
                    let p = base + y * stride + x * 4; return (p[2], p[1], p[0])
                }
                if let marker { row["run"] = "\(marker.run)"; row["show"] = "\(marker.show)"; row["revision"] = "\(marker.revision)"; row["digest"] = "\(marker.digest)" }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        state.withLock { $0.rows.append(row) }
    }
}

@main struct Observer {
    static func selfTest() throws {
        let marker = FrameMarker(run: 2, show: 7, revision: 17, digest: 0x123456)
        for scale in [1.0, 1.5, 2.0, 3.0] {
            let bits = marker.bits
            let decoded = MarkerPixels.decode(width: 180, height: 100, originX: 11, originY: 13, scale: scale) { x,y in
                let i = Int(Double(y - 13) / scale) * FrameMarker.columns + Int(Double(x - 11) / scale)
                let value: UInt8 = bits[i] ? 255 : 0; return (value,value,value)
            }
            guard decoded == marker else { throw SourceError("Synthetic pixel marker failed") }
        }
        for mode in ResultLocation.allCases {
            for count in [0, 1, 3, 9] {
                let height = PanelLayout.height(rows: count, location: mode)
                guard height <= PanelLayout.maximumHeight else { throw SourceError("Layout exceeds observer canvas") }
                for scale in [1.0, 2.0, 3.0] {
                    let x = 588 * scale + 11, y = 16 * scale + 13
                    let decoded = MarkerPixels.decode(width: Int(640 * scale) + 22, height: Int(height * scale) + 26, originX: x, originY: y, scale: scale) { px,py in
                        let i = Int((Double(py) - y) / scale) * FrameMarker.columns + Int((Double(px) - x) / scale)
                        let value: UInt8 = marker.bits[i] ? 255 : 0; return (value,value,value)
                    }
                    guard decoded == marker else { throw SourceError("Layout-sized offset marker failed") }
                }
            }
        }
        var detector = FrameDetector([FrameExpectation(marker: marker, input: 100, deadline: 200)])
        detector.accept(marker, at: 99); detector.accept(marker, at: 150); detector.accept(marker, at: 160); detector.accept(marker, at: 130)
        guard detector.first[marker] == 150, detector.rejected == 1, detector.duplicates == 1, detector.outOfOrder == 1 else { throw SourceError("Synthetic detector failed") }
        print("Passed: inline/right/below strip/1/3/9 canvas, pixel scales 1/1.5/2/3, offset, bounded timestamp, stale/duplicate/out-of-order; no preflight or capture")
    }
    @MainActor static func main() async {
        do {
            let args = CommandLine.arguments
            if args == [args[0], "--self-test"] { try selfTest(); return }
            guard args.count == 6, args[1] == "--capture-owned-window", let pid = Int32(args[2]), let windowID = UInt32(args[3]),
                  let seconds = Double(args[4]), (1...180).contains(seconds) else {
                throw SourceError("Usage: ApparateObserver --self-test OR --capture-owned-window PID WINDOW_ID SECONDS NEW_OUTPUT_DIRECTORY (only after user authorization)")
            }
            // Never request access: preflight this actual terminal-launched process identity.
            guard CGPreflightScreenCaptureAccess() else { throw SourceError("Observer launch identity lacks Screen Recording permission; no prompt requested") }
            let output = URL(fileURLWithPath: args[5], isDirectory: true)
            guard !FileManager.default.fileExists(atPath: output.path) else { throw SourceError("Output directory already exists") }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID && $0.owningApplication?.processID == pid }),
                  window.owningApplication?.bundleIdentifier == "local.apparate", window.frame.width == 640, (PanelLayout.stripHeight...PanelLayout.maximumHeight).contains(window.frame.height) else {
                throw SourceError("Owned Apparate panel identity/geometry unavailable")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(PanelLayout.width * Double(filter.pointPixelScale)); configuration.height = Int(PanelLayout.maximumHeight * Double(filter.pointPixelScale))
            configuration.scalesToFit = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA; configuration.queueDepth = 8
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
            configuration.showsCursor = false; configuration.capturesAudio = false; configuration.ignoreShadowsSingleWindow = true
            let recorder = Recorder(), queue = DispatchQueue(label: "local.apparate.observer", qos: .userInteractive)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: recorder)
            try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            let start = ObservationClock.now
            // Bounded capture with process/stream watchdog. A nonactivating launcher may
            // be key while another app remains frontmost: the visible app driver must
            // monitor its own key window before this observer can qualify a live run.
            var lost = false
            while ObservationClock.milliseconds(start, ObservationClock.now) < seconds * 1000 {
                try await Task.sleep(for: .milliseconds(100))
                if NSRunningApplication(processIdentifier: pid) == nil || recorder.state.withLock({ $0.stopped }) { lost = true; break }
            }
            try await stream.stopCapture()
            await withCheckedContinuation { (c: CheckedContinuation<Void,Never>) in queue.async { c.resume() } }
            let rows = recorder.state.withLock { $0.rows }
            let keys = Set(rows.flatMap(\.keys)).sorted()
            let csv = ([keys.joined(separator: ",")] + rows.map { row in keys.map { row[$0] ?? "" }.joined(separator: ",") }).joined(separator: "\n") + "\n"
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try csv.write(to: output.appendingPathComponent("frames.csv"), atomically: true, encoding: .utf8)
            let displays = content.displays.map { display -> [String: Any] in
                let mode = CGDisplayCopyDisplayMode(display.displayID)
                return ["id": display.displayID, "width": display.width, "height": display.height, "refresh_hz": mode?.refreshRate ?? 0]
            }
            let receipt: [String: Any] = ["pid": pid, "window_id": windowID, "frames": rows.count, "watchdog_stopped": lost,
                "preflight": true, "timebase_numer": ObservationClock.timebase.0, "timebase_denom": ObservationClock.timebase.1,
                "point_pixel_scale": filter.pointPixelScale, "displays": displays,
                "scope": "First observed WindowServer displayTime; single owned window; no pixels saved, no scan-out claim; live vibrancy composition and geometry calibration must be checked before verdict"]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("observer.json"))
        } catch { FileHandle.standardError.write(Data(("Observer failed: \(error)\n").utf8)); exit(1) }
    }
}
