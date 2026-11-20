import Foundation
import ApparateCore
import Darwin

private func shallowWakeups() throws -> (UInt64, UInt64) {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    try expect(result == 0, "Wakeup counters unavailable")
    return (info.ri_interrupt_wkups, info.ri_pkg_idle_wkups)
}
/// Child process only: its CPU and wakeups are excluded from the watcher measurement.
func runShallowWriter() throws {
    let path = CommandLine.arguments.last!
    try expect(path.contains("/apparate-m1-") && path.hasSuffix("/Root/Sub/deep"), "Writer requires an owned fixture subtree")
    let root = URL(fileURLWithPath: path), began = ContinuousClock.now
    var mutations = 0
    while durationMS(began.duration(to: .now)) < 70_000 {
        let a = root.appendingPathComponent("churn.tmp"), b = root.appendingPathComponent("renamed.tmp")
        try Data("fixture".utf8).write(to: a)
        try FileManager.default.moveItem(at: a, to: b)
        try FileManager.default.removeItem(at: b)
        mutations += 3
        usleep(10_000)
    }
    print("{\"mutations\":\(mutations),\"duration_seconds\":\(durationMS(began.duration(to: .now)) / 1000)}")
}
@MainActor func runShallowIdle() async throws {
    let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appendingPathComponent("Root"), data = dir.appendingPathComponent("Data")
    try makeFile(root, "Sub/deep/initial.txt")
    var config = AppConfig(); config.folders = [.init(path: root.path, depth: 1)]
    let watcher = RecordingFileWatcher(), controller = FileIndexController(config: config, store: try FileIndexStore(directory: data), access: fixtureAccess, watcher: watcher)
    controller.start(); defer { controller.stop() }
    try await eventually({ !controller.isIndexing && controller.snapshot?.count == 2 }, timeout: 10)
    try expect(watcher.recursivePaths.isEmpty && watcher.shallowPaths == [root.path])
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--shallow-writer", root.path + "/Sub/deep"]
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    try await Task.sleep(for: .seconds(2))
    try expect(process.isRunning)
    let metrics = controller.metrics, batches = watcher.batches.count
    let began = ContinuousClock.now, cpu = fileCPU(), wakeups = try shallowWakeups()
    try await Task.sleep(for: .seconds(32)); try await Task.sleep(for: .seconds(32))
    let seconds = durationMS(began.duration(to: .now)) / 1000, cpuSeconds = fileCPU() - cpu, afterWakeups = try shallowWakeups()
    try expect(process.isRunning, "Writer did not span the whole measurement")
    let scans = controller.metrics.completedScans - metrics.completedScans, updates = controller.metrics.completedUpdates - metrics.completedUpdates
    let publications = controller.metrics.publications - metrics.publications, events = watcher.batches.count - batches
    try expect(events == 0 && scans == 0 && updates == 0 && publications == 0, "Deep activity reached the shallow index")
    try expect(cpuSeconds / seconds * 100 < 0.1, "Watcher idle exceeded 0.1% of one core")
    process.waitUntilExit(); try expect(process.terminationStatus == 0)
    let writer = try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile())
    let change = ContinuousClock.now
    try makeFile(root, "immediate.txt")
    try await eventually({ controller.snapshot?.contains(path: root.path + "/immediate.txt") == true }, timeout: 8)
    let result: [String: Any] = ["result": "Passed", "scope": "Production FileIndexController and vnode watcher; separate fixture writer process; no UI or real home/root scans",
        "observation_seconds": seconds, "cpu_seconds": cpuSeconds, "cpu_percent_one_core": cpuSeconds / seconds * 100,
        "interrupt_wakeups": afterWakeups.0 - wakeups.0, "package_idle_wakeups": afterWakeups.1 - wakeups.1,
        "watcher_batches": events, "completed_scans": scans, "completed_updates": updates, "publications": publications,
        "recursive_streams": watcher.recursivePaths.count, "shallow_watches": watcher.shallowPaths.count,
        "writer": writer, "phys_footprint_bytes": fileFootprint(), "immediate_change_to_searchable_ms": durationMS(change.duration(to: .now)),
        "latency_boundary": "Before immediate fixture write to snapshot searchability, checked every 10 ms", "watch_healthy": controller.watchHealthy]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
}
