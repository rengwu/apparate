import AppKit
import ApparateCore
import ApparateFixtures
import Synchronization

enum PerformanceData {
    static let queries = ["", "r", "re", "rea", "read", "readme", "readme", "report", "config", "network", "project/", "project/read", "projects/report", "c", "ca", "café", "straße", "東京", ".zzzz", "?example"]
    static let dotQueries = ["'.config", "'.env", "'.git", "'.github", "'.editorconfig", "'project/.env", "'project/.git", "'project/", "'config", ".config"]
    static func stats(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else { return ["count": 0] }
        let sorted = values.sorted()
        return ["count": sorted.count, "median": sorted[sorted.count / 2], "p95": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], "max": sorted.last!]
    }
    static func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
    }
    static func csv(_ rows: [[String: String]], to url: URL) throws {
        let keys = Set(rows.flatMap(\.keys)).sorted()
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let text = ([keys.map(quote).joined(separator: ",")] + rows.map { row in keys.map { quote(row[$0] ?? "") }.joined(separator: ",") }).joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    static func base(_ profile: TestProfile) -> [String: Any] {
        ["schema": 1, "profile": profile.performance!, "count": profile.panelCount, "thermal_start": ProcessInfo.processInfo.thermalState.rawValue,
         "visible_profile": "none", "native_actions": 0, "native_hotkey_registrations": 0, "native_status_items": 0,
         "native_login_changes": 0, "protected_folder_probes": 0, "symbolichotkeys_writes": 0,
         "timebase_numer": ObservationClock.timebase.0, "timebase_denom": ObservationClock.timebase.1,
         "clock": "mach_absolute_time", "on_screen_budgets": "Untested"]
    }
}

private final class PerformanceTraces: Sendable {
    let values = Mutex<[UInt64: SearchTrace]>([:])
    func append(_ trace: SearchTrace) { values.withLock { $0[trace.generation] = trace } }
}

/// Bounded hidden diagnostics only. Independent deadlines never wait for query completion.
@MainActor enum PerformanceVerification {
    static func run(_ profile: TestProfile) async {
        var report = PerformanceData.base(profile)
        defer { NSApp.terminate(nil) }
        do {
            let files = try await Task.detached(priority: .userInitiated) {
                let fixture = SyntheticFiles(count: profile.panelCount, includeDots: profile.dotEntries)
                return try await FileCrawler(reader: fixture.reader).crawl(folders: [.init(path: fixture.root)], respectGitignore: true, access: FileAccessPolicy()).snapshot
            }.value
            report["file_count"] = files.count; report["dot_count"] = files.dotEntryCount
            report["dot_fixture"] = profile.dotEntries
            let catalog = try TestProfile.fixtureCatalog()
            if profile.performance == "pipeline" { try await pipeline(profile, files: files, catalog: catalog, report: &report) }
            else { try await latency(profile, files: files, catalog: catalog, report: &report) }
            report["result"] = "Passed"; report["errors"] = 0; report["focus_guards_checked"] = true
        } catch { report["result"] = "Failed"; report["errors"] = 1; report["failure"] = String(describing: error) }
        report["thermal_end"] = ProcessInfo.processInfo.thermalState.rawValue
        try? PerformanceData.write(report, to: profile.directory.appendingPathComponent("diagnostics.json"))
    }
    private static func pipeline(_ profile: TestProfile, files: FileIndexSnapshot, catalog: CatalogSnapshot, report: inout [String: Any]) async throws {
        let rows = try await Task.detached(priority: .userInitiated) {
            let usage = UsageSnapshot(), pipeline = SearchPipeline()
            var rows: [[String: String]] = []
            for repeatIndex in 0..<2 {
                let queries = PerformanceData.queries + (profile.dotEntries ? PerformanceData.dotQueries : [])
                for i in 0..<(queries.count * 6) {
                    let text = queries[i % queries.count], query = ParsedQuery(text)
                    let request = SearchRequest(generation: UInt64(i), index: catalog.index, query: query, files: files, usage: usage)
                    // Independent reference, parsed query and hashes all outside timing.
                    let local = catalog.index.search(query, usage: usage, includeWebFallback: false)
                    let reference = SearchResult.merge([local, query.scope == .web ? [] : files.search(query, usage: usage)])
                    let expected = reference.isEmpty ? catalog.index.search(query, usage: usage) : reference
                    var fileRows: [SearchResult] = [], actual: [SearchResult] = [], fileMS = 0.0, pipelineMS = 0.0
                    func measureFile() { let start = ObservationClock.now; fileRows = files.search(query, usage: usage); fileMS = ObservationClock.milliseconds(start, ObservationClock.now) }
                    func measurePipeline() { let start = ObservationClock.now; actual = pipeline.search(request); pipelineMS = ObservationClock.milliseconds(start, ObservationClock.now) }
                    if repeatIndex == 0 { measureFile(); measurePipeline() } else { measurePipeline(); measureFile() }
                    guard ObservationClock.digest(actual) == ObservationClock.digest(expected) else { throw SourceError("Matched pipeline/reference digest mismatch") }
                    var row = ["repeat": "\(repeatIndex)", "event": "\(i)", "query": text, "file_ms": "\(fileMS)", "pipeline_ms": "\(pipelineMS)", "file_count": "\(fileRows.count)", "digest": "\(ObservationClock.digest(actual))"]
                    // Separate profiled invocation: never counted as uninstrumented pipeline time.
                    _ = pipeline.search(request, stage: { row["probe_" + $0 + "_ms"] = "\($1)" })
                    rows.append(row)
                }
            }
            return rows
        }.value
        try PerformanceData.csv(rows, to: profile.directory.appendingPathComponent("pipeline.csv"))
        report["file"] = PerformanceData.stats(rows.compactMap { Double($0["file_ms"]!) })
        report["pipeline"] = PerformanceData.stats(rows.compactMap { Double($0["pipeline_ms"]!) })
        for (label, subset) in [("ordinary", rows.filter { !PerformanceData.dotQueries.contains($0["query"]!) }),
                                ("dot_queries", rows.filter { PerformanceData.dotQueries.contains($0["query"]!) })] {
            report[label + "_pipeline"] = PerformanceData.stats(subset.compactMap { Double($0["pipeline_ms"]!) })
        }
        report["matched_hashes"] = rows.count
        report["scope"] = "Same snapshot, parsed query, empty usage, top-50 limit; file-only vs production pipeline; independent reference hash outside timers; stage-probe third invocation separate. Opposite orders, not an end-to-end latency verdict."
    }
    private static func latency(_ profile: TestProfile, files: FileIndexSnapshot, catalog: CatalogSnapshot, report: inout [String: Any]) async throws {
        let traces = PerformanceTraces()
        let coordinator = SearchCoordinator(observe: { traces.append($0) })
        coordinator.delivery = profile.delivery; coordinator.measureStages = profile.stageProbes
        let session = LauncherSession(config: AppConfig(), requiresFiles: true, coordinator: coordinator, usage: { UsageSnapshot() })
        session.setCatalog(catalog); session.setFiles(files)
        let panel = PanelController(session: session, icons: IconLoader(fixtureOnly: true), presentationAllowed: false,
                                    opaque: profile.opaque, activityEnabled: true, bareField: profile.bareField)
        defer { panel.hide() }
        let run = ObservationClock.now; panel.observationRun = run
        var shows: [Double] = []
        for _ in 0..<101 { let start = ObservationClock.now; try panel.beginHiddenShowing(); shows.append(ObservationClock.milliseconds(start, ObservationClock.now)); panel.hide() }
        try panel.beginHiddenShowing(); try await Task.sleep(for: .milliseconds(100))
        // Oracle precomputed outside every timed input interval; only synthetic data.
        let expected = await Task.detached(priority: .userInitiated) {
            let engine = SearchPipeline(), usage = UsageSnapshot()
            return PerformanceData.queries.map { text -> UInt64 in
                if text.isEmpty { return ObservationClock.digest([]) }
                return ObservationClock.digest(engine.search(.init(generation: 0, index: catalog.index, query: ParsedQuery(text), files: files, usage: usage)))
            }
        }.value
        var records: [[String: String]] = [], mismatches = 0
        for cadence in [40.0, 1.0] {
            let total = cadence == 40 ? 120 : 40
            var events = (0..<total).map { ["phase": cadence == 40 ? "fixed-40ms" : "stress-1ms", "event": "\($0)", "status": "not-delivered"] }
            var active: Int?, revisions: [UInt64: Int] = [:], generations: [Int: UInt64] = [:]
            let origin = ObservationClock.after(ObservationClock.now, milliseconds: 100)
            @MainActor func timestamp(_ i: Int, _ key: String, _ tick: UInt64 = ObservationClock.now) { events[i][key] = "\(tick)" }
            session.onSubmitted = { revision, generation in
                if let i = active { revisions[revision] = i; generations[i] = generation; timestamp(i, "submit_ticks") }
            }
            coordinator.onDelivery = { generation, _ in
                if let i = generations.first(where: { $0.value == generation })?.key { timestamp(i, "delivery_ticks") }
            }
            session.onResponse = { revision in if let i = revisions[revision] { timestamp(i, "accept_ticks") } }
            panel.onTextBegin = { if let i = active { timestamp(i, "text_begin_ticks") } }
            panel.onText = { _, revision in if let i = active { revisions[revision] = i; timestamp(i, "text_commit_ticks") } }
            panel.onUpdate = { revision, pending, applyMS in
                guard !pending, let i = revisions[revision] ?? active, events[i]["status"] == "delivered" else { return }
                timestamp(i, "view_ticks"); events[i]["view_apply_ms"] = "\(applyMS)"
                events[i]["status"] = "view-state"
                if let input = events[i]["input_ticks"].flatMap(UInt64.init), ObservationClock.milliseconds(input, ObservationClock.now) > 250 { events[i]["status"] = "timed-out" }
                let digest = ObservationClock.digest(session.model.rows.map(\.result))
                events[i]["actual_digest"] = "\(digest)"
                if digest != expected[i % expected.count] { mismatches += 1 }
                if let marker = panel.rows.observationMarker {
                    events[i]["run"] = "\(marker.run)"; events[i]["show"] = "\(marker.show)"; events[i]["revision"] = "\(marker.revision)"
                }
            }
            // Timer on an independent serial queue: records wake before dispatch to main.
            let scheduler = DispatchQueue(label: "local.apparate.performance.scheduler", qos: .userInitiated)
            let deliverInput: @MainActor @Sendable (Int, UInt64, UInt64) -> Void = { i, scheduled, wake in
                if let prior = active, events[prior]["status"] == "delivered" { events[prior]["status"] = "superseded" }
                active = i; events[i]["scheduled_ticks"] = "\(scheduled)"; events[i]["wake_ticks"] = "\(wake)"
                timestamp(i, "input_ticks"); events[i]["status"] = "delivered"
                events[i]["deadline_ticks"] = "\(ObservationClock.after(ObservationClock.now, milliseconds: 250))"
                events[i]["expected_digest"] = "\(expected[i % expected.count])"
                if profile.stageProbes {
                    let queued = ObservationClock.now
                    DispatchQueue.main.async { events[i]["noop_main_queue_ms"] = "\(ObservationClock.milliseconds(queued, ObservationClock.now))" }
                }
                do {
                    try panel.injectText(PerformanceData.queries[i % PerformanceData.queries.count]); timestamp(i, "handler_end_ticks")
                    events[i]["revision"] = "\(session.model.revision)"; events[i]["run"] = "\(run)"; events[i]["show"] = "\(panel.observationShow)"
                }
                catch { events[i]["status"] = "aborted" }
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let timer = DispatchSource.makeTimerSource(flags: .strict, queue: scheduler)
                let next = Mutex(0)
                let remaining = max(0, ObservationClock.milliseconds(ObservationClock.now, origin))
                timer.schedule(deadline: .now() + remaining / 1000, repeating: .nanoseconds(Int(cadence * 1e6)), leeway: .nanoseconds(0))
                let tick: @Sendable () -> Void = {
                    let wake = ObservationClock.now
                    let due = min(total - 1, max(0, Int(ObservationClock.milliseconds(origin, wake) / cadence)))
                    let indices = next.withLock { next -> Range<Int> in
                        let first = next; next = max(next, due + 1); return first..<next
                    }
                    for i in indices {
                        let scheduled = ObservationClock.after(origin, milliseconds: Double(i) * cadence)
                        DispatchQueue.main.async {
                            deliverInput(i, scheduled, wake)
                            if i == total - 1 { continuation.resume() }
                        }
                    }
                    if due == total - 1 { timer.setEventHandler {}; timer.cancel() }
                }
                timer.setEventHandler(handler: tick)
                timer.resume()
            }
            // The final window is bounded, independent of whether anything completed.
            try await Task.sleep(for: .milliseconds(250))
            let allTraces = traces.values.withLock { $0 }
            for i in events.indices {
                if events[i]["status"] == "delivered" { events[i]["status"] = "timed-out" }
                if let generation = generations[i], let t = allTraces[generation] {
                    events[i]["worker_queue_ms"] = "\(durationMS(t.submitted.duration(to: t.started)))"
                    events[i]["search_ms"] = "\(durationMS(t.started.duration(to: t.finished)))"
                    events[i]["worker_cpu_ms"] = "\(Double(t.cpuNanoseconds) / 1e6)"
                    events[i]["worker_started_ticks"] = "\(t.startedTicks)"; events[i]["worker_finished_ticks"] = "\(t.finishedTicks)"
                    if let delivery = events[i]["delivery_ticks"].flatMap(UInt64.init) { events[i]["worker_to_main_ms"] = "\(ObservationClock.milliseconds(t.finishedTicks, delivery))" }
                    for (key, value) in t.stages { events[i]["probe_" + key + "_ms"] = "\(value)" }
                }
            }
            records += events
            session.onSubmitted = nil; session.onResponse = nil; coordinator.onDelivery = nil
            panel.onTextBegin = nil; panel.onText = nil; panel.onUpdate = nil
        }
        try panel.verifyHidden()
        try PerformanceData.csv(records, to: profile.directory.appendingPathComponent("events.csv"))
        let fixed = records.filter { $0["phase"] == "fixed-40ms" }
        func durations(_ start: String, _ end: String) -> [Double] { fixed.compactMap { row in
            guard end != "view_ticks" || row["status"] == "view-state", let a = row[start].flatMap(UInt64.init), let b = row[end].flatMap(UInt64.init) else { return nil }; return ObservationClock.milliseconds(a,b)
        } }
        report["input_to_view_ms"] = PerformanceData.stats(durations("input_ticks", "view_ticks"))
        report["input_handler_ms"] = PerformanceData.stats(durations("input_ticks", "handler_end_ticks"))
        report["scheduled_to_input_ms"] = PerformanceData.stats(durations("scheduled_ticks", "input_ticks"))
        report["timer_lateness_ms"] = PerformanceData.stats(durations("scheduled_ticks", "wake_ticks"))
        report["scheduler_to_main_ms"] = PerformanceData.stats(durations("wake_ticks", "input_ticks"))
        for key in ["search_ms", "worker_queue_ms", "worker_to_main_ms", "noop_main_queue_ms"] { report[key] = PerformanceData.stats(fixed.compactMap { $0[key].flatMap(Double.init) }) }
        report["statuses"] = Dictionary(grouping: records, by: { $0["status"]! }).mapValues(\.count)
        report["fixed_statuses"] = Dictionary(grouping: fixed, by: { $0["status"]! }).mapValues(\.count)
        report["hidden_warm_show_ms"] = PerformanceData.stats(Array(shows.dropFirst())); report["hidden_cold_show_ms"] = shows.first!
        report["bare_field"] = profile.bareField; report["stage_probes"] = profile.stageProbes; report["delivery"] = profile.delivery.rawValue
        report["result_mismatches"] = mismatches
        report["writing_tools_images"] = (0..<_dyld_image_count()).filter { String(cString: _dyld_get_image_name($0)).localizedCaseInsensitiveContains("WritingTools") }.count
        report["scope"] = "Hidden field-editor injection to view state; 120 fixed + 40 stress inputs, no drawing or screen capture in timed path; absolute scheduling, all events retained. 100 warm hidden calls are not frame timings. Shared mach absolute ticks throughout."
        // Separate functional raster check, after timing ends. No retained images.
        var decoded = 0
        for query in ["", "readme", "?example", "?example", ".zzzz"] {
            try panel.injectText(query)
            let deadline = ObservationClock.after(ObservationClock.now, milliseconds: 2000)
            while session.model.pending && ObservationClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            guard !session.model.pending, let marker = panel.rows.observationMarker else { throw SourceError("Marker functional result unavailable") }
            let bitmap = try panel.render(), scale = Double(bitmap.pixelsWide) / 640
            let actual = MarkerPixels.decode(width: bitmap.pixelsWide, height: bitmap.pixelsHigh, originX: 6 * scale, originY: 47 * scale, scale: scale) { x,y in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (128,128,128) }
                return (UInt8(clamping: Int(color.redComponent * 255)), UInt8(clamping: Int(color.greenComponent * 255)), UInt8(clamping: Int(color.blueComponent * 255)))
            }
            guard actual == marker else { throw SourceError("Native raster marker did not certify drawn rows") }; decoded += 1
        }
        report["native_marker_round_trips"] = decoded
        guard mismatches == 0, !records.contains(where: { $0["status"] == "aborted" || $0["status"] == "timed-out" }) else { throw SourceError("Hidden input harness mismatch, abort or timeout") }
    }
}
