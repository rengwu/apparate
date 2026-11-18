import Foundation
import ApparateFixtures
import Darwin
import Synchronization
import ApparateCore

func fileFootprint() -> UInt64 {
    var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    } }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
}
func fileCPU() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}
func fileStats(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    return ["median_ms": sorted[sorted.count / 2], "p95_ms": sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)], "max_ms": sorted.last!]
}
private final class FootprintSampler: Sendable {
    let peak = Mutex<UInt64>(0)
    let timer: any DispatchSourceTimer
    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.setEventHandler { [weak self] in let current = fileFootprint(); self?.peak.withLock { $0 = max($0, current) } }
        timer.schedule(deadline: .now(), repeating: .milliseconds(10)); timer.resume()
    }
    func reset() { peak.withLock { $0 = fileFootprint() } }
    func read() -> UInt64 { peak.withLock { max($0, fileFootprint()) } }
    func stop() { timer.cancel() }
}

@MainActor func runFileBenchmark() async throws {
    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--file-benchmark"), flag + 1 < arguments.count else { throw TestFailure(description: "Expected synthetic or projects") }
    let mode = arguments[flag + 1]
    guard ["synthetic", "projects"].contains(mode) else { throw TestFailure(description: "Invalid benchmark mode") }
    let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let synthetic = SyntheticFiles(count: 200_000)
    let root = mode == "synthetic" ? synthetic.root : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects").path
    let crawler = FileCrawler(reader: mode == "synthetic" ? synthetic.reader : FileReading())
    let folders = [AppConfig.Folder(path: root)]
    let sampler = FootprintSampler(); defer { sampler.stop() }
    let baseline = fileFootprint(), start = ContinuousClock.now
    var first: FileCrawlResult? = try await Task.detached(priority: .utility) {
        try await crawler.crawl(folders: folders, respectGitignore: true, access: FileAccessPolicy())
    }.value
    let crawlMS = durationMS(start.duration(to: .now)), afterCrawl = fileFootprint(), count = first!.snapshot.count
    let unreadable = first!.dirtyPaths.count, unavailable = first!.snapshot.unavailableCount
    let store = try FileIndexStore(directory: directory.appendingPathComponent("database"))
    let saveStart = ContinuousClock.now
    try await store.save(first!, signature: "benchmark", checkpoints: [], replacing: true)
    let saveMS = durationMS(saveStart.duration(to: .now)); first = nil
    let loaded = try await store.load()!, snapshot = loaded.snapshot, afterLoad = fileFootprint()
    var checksum: UInt64 = 0
    func measure(_ paths: Bool, rounds: Int = 3) -> [String: Any] {
        let words = paths ? ["projects/readme", "project/report", "src/config", "sources/index", "project/", "docs/", "p/r", "zzqq/"] : ["readme", "report", "config", "network", "calendar", "terminal", "archive", "notes", "search", "index", "cafe", "strasse", "東京", "zzqq"]
        var readings: [Double] = []
        for word in words {
            var prefix = ""
            for character in word {
                prefix.append(character); let query = ParsedQuery(prefix)
                if paths && !query.isPath { continue }
                for _ in 0..<rounds {
                    let began = ContinuousClock.now, rows = snapshot.search(query)
                    readings.append(durationMS(began.duration(to: .now)))
                    checksum &+= UInt64(rows.count); for row in rows { checksum ^= row.textScore.bitPattern }
                }
            }
        }
        return ["samples": readings.count, "statistics": fileStats(readings)]
    }
    for q in ["readme", "config", "projects/report", "project/"] { checksum &+= UInt64(snapshot.search(ParsedQuery(q)).count) }
    let names = measure(false), paths = measure(true)
    var report: [String: Any] = ["schema": 1, "mode": mode, "seed": "deterministic-17-31-v1", "entry_count": count, "discovered_apps": snapshot.applicationCount, "failed_directories": unreadable, "unavailable_entries": unavailable,
        "baseline_phys_footprint_bytes": baseline, "after_crawl_phys_footprint_bytes": afterCrawl,
        "after_load_phys_footprint_bytes": afterLoad, "after_search_phys_footprint_bytes": fileFootprint(),
        "crawl_and_prepare_ms": crawlMS, "sqlite_save_ms": saveMS, "sqlite_read_decode_ms": loaded.readMS,
        "loaded_snapshot_prepare_ms": loaded.prepareMS, "names": names, "paths": paths,
        "scope": "Core scoring, top-50 and highlights; excludes UI/coordinator delivery; query parsing outside timer",
        "real_data_policy": "Projects read-only, aggregate counts/timings only; mutations confined to synthetic or temporary fixtures"]
    if mode == "synthetic" {
        synthetic.change.withLock { $0 = 1 }
        let updateStart = ContinuousClock.now
        let updated = try await crawler.update(snapshot, changes: [FileChange(path: root + "/Project-0000")], respectGitignore: true, access: fixtureAccess)
        let updateMS = durationMS(updateStart.duration(to: .now))
        try expect(updated.snapshot.count == count + 1 && snapshot.count == count)
        try expect(updated.snapshot.search(ParsedQuery("new-entry")).count == 1)
        report["small_change_prepare_ms"] = updateMS
        report["small_change_prepared_chunks"] = updated.preparedChunks
        report["old_plus_updated_phys_footprint_bytes"] = fileFootprint()
        let incrementalSave = ContinuousClock.now
        try await store.save(updated, signature: "benchmark", checkpoints: [], replacing: false)
        report["small_change_save_ms"] = durationMS(incrementalSave.duration(to: .now))
        sampler.reset()
        let rebuilding = Task.detached(priority: .utility) {
            try await crawler.crawl(folders: folders, respectGitignore: true, access: fixtureAccess, previous: updated.snapshot)
        }
        report["names_during_rebuild"] = measure(false, rounds: 1)
        report["paths_during_rebuild"] = measure(true, rounds: 1)
        let rebuilt = try await rebuilding.value
        try expect(rebuilt.snapshot.count == updated.snapshot.count)
        report["old_updated_and_rebuilt_phys_footprint_bytes"] = fileFootprint()
        report["rebuild_peak_sampled_phys_footprint_bytes"] = sampler.read()
        synthetic.change.withLock { $0 = 2 }
        let removed = try await crawler.update(rebuilt.snapshot, changes: [FileChange(path: root + "/Project-0000")], respectGitignore: true, access: fixtureAccess)
        synthetic.change.withLock { $0 = 1 }
        let recycled = try await crawler.update(removed.snapshot, changes: [FileChange(path: root + "/Project-0000")], respectGitignore: true, access: fixtureAccess)
        try expect(recycled.snapshot.count == rebuilt.snapshot.count)
        report["recycle_prepared_chunks"] = recycled.preparedChunks
        report["retained_recycling_snapshots_phys_footprint_bytes"] = fileFootprint()
    }
    report["footprint_sampling_ms"] = 10
    report["checksum"] = String(checksum)
    report["result"] = "Passed"
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
}

@MainActor func runFileIdle() async throws {
    let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appendingPathComponent("root"), data = dir.appendingPathComponent("data")
    try makeFile(root, "ready.txt")
    var config = AppConfig(); config.folders = [.init(path: root.path)]
    let controller = FileIndexController(config: config, store: try FileIndexStore(directory: data), access: fixtureAccess)
    controller.start(); defer { controller.stop() }
    try await eventually({ controller.snapshot?.count == 2 }, timeout: 10)
    try await Task.sleep(for: .seconds(1))
    let updates = controller.metrics.completedUpdates, publications = controller.metrics.publications
    let start = ContinuousClock.now, cpu = fileCPU()
    // Split waits keep the outer tool responsive; no polling or application work in interval.
    try await Task.sleep(for: .seconds(32)); try await Task.sleep(for: .seconds(32))
    let seconds = durationMS(start.duration(to: .now)) / 1000, consumed = fileCPU() - cpu
    try expect(controller.metrics.completedUpdates == updates && controller.metrics.publications == publications)
    let mutation = ContinuousClock.now
    try makeFile(root, "changed.txt")
    try await eventually({ controller.snapshot?.contains(path: root.appendingPathComponent("changed.txt").path) == true }, timeout: 8)
    let latency = durationMS(mutation.duration(to: .now))
    let report: [String: Any] = ["result": "Passed", "observation_seconds": seconds, "cpu_seconds": consumed, "cpu_percent_one_core": consumed / seconds * 100,
        "completed_updates": 0, "publications": 0, "phys_footprint_bytes": fileFootprint(), "fixture_change_to_searchable_ms": latency,
        "change_latency_boundary": "before fixture write to controller snapshot containing its path; checked at 10 ms intervals", "watch_healthy": controller.watchHealthy]
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
}
