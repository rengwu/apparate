import AppKit
import ApparateCore
import Synchronization

private final class RebuildSampler: Sendable {
    struct State: Sendable { var peak: UInt64 = 0; var samples = 0, failures = 0; var previous: UInt64?, gaps: [Double] = [] }
    let state = Mutex(State())
    private let timer: any DispatchSourceTimer
    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "local.apparate.footprint", qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(25), leeway: .milliseconds(1))
        timer.setEventHandler { [self] in
            let tick = ObservationClock.now, bytes = try? ProcessMetrics.footprint()
            state.withLock { value in
                if let previous = value.previous { value.gaps.append(ObservationClock.milliseconds(previous, tick)) }
                value.previous = tick
                if let bytes { value.samples += 1; value.peak = max(value.peak, bytes) } else { value.failures += 1 }
            }
        }
        timer.resume()
    }
    func stop() async -> State {
        await withCheckedContinuation { continuation in
            timer.setCancelHandler { [self] in continuation.resume(returning: state.withLock { $0 }) }; timer.setEventHandler {}; timer.cancel()
        }
    }
}

/// Attached to AppDelegate's normal retained graph; real SQLite, watchers and catalogs.
@MainActor final class FullPerformance {
    let profile: TestProfile, catalog: CatalogController, files: FileIndexController, session: LauncherSession, panel: PanelController
    let settings: SettingsWindow, setup: SetupWindow, menu: MenuController, effects: TestEffects
    var errors = 0
    init(profile: TestProfile, catalog: CatalogController, files: FileIndexController, session: LauncherSession, panel: PanelController,
         settings: SettingsWindow, setup: SetupWindow, menu: MenuController, effects: TestEffects) {
        self.profile = profile; self.catalog = catalog; self.files = files; self.session = session; self.panel = panel
        self.settings = settings; self.setup = setup; self.menu = menu; self.effects = effects
    }
    private func wait(_ predicate: () -> Bool, seconds: Double = 180) async throws {
        let start = ObservationClock.now
        while !predicate(), ObservationClock.milliseconds(start, ObservationClock.now) < seconds * 1000 { try await Task.sleep(for: .milliseconds(50)) }
        guard predicate() else { throw SourceError("Full-app readiness/rebuild deadline expired") }
    }
    private func hidden() throws {
        try panel.verifyHidden(); try settings.verifyHidden(); try setup.verifyHidden()
        guard menu.nativeItemCount == 0, effects.actionCount == 0, !NSApp.isActive else { throw SourceError("Hidden full-app effect guard failed") }
    }
    func run() async {
        var report = PerformanceData.base(profile)
        defer { NSApp.terminate(nil) }
        do {
            try await wait { self.session.isCatalogReady && !self.files.isIndexing }
            try await Task.sleep(for: .seconds(2)); try hidden()
            report["file_count"] = files.snapshot?.count ?? 0; report["loaded_from_disk"] = files.metrics.loadedFromDisk
            report["app_count"] = catalog.metrics.appCount; report["settings_count"] = catalog.metrics.settingsCount
            report["file_watch_healthy"] = files.watchHealthy; report["catalog_watch_healthy"] = catalog.watchHealthy
            report["after_load_bytes"] = try ProcessMetrics.footprint()
            report["dot_count"] = files.snapshot?.dotEntryCount ?? 0
            report["result_location"] = session.resultLocation.rawValue
            report["icon_points"] = session.resultLocation.iconSize.rawValue
            report["icon_raster_pixels"] = session.resultLocation.iconSize.pixels
            guard files.watchHealthy, catalog.watchHealthy, (files.snapshot?.count ?? 0) > 0 else { throw SourceError("Full graph is not ready with healthy watchers") }
            if profile.performance == "full" {
                guard files.metrics.loadedFromDisk else { throw SourceError("Measured full run did not load the persisted index") }
                try panel.beginHiddenShowing(); try await Task.sleep(for: .milliseconds(100))
                let origin = ContinuousClock.now
                for i in 0..<120 {
                    try await Task.sleep(until: origin.advanced(by: .milliseconds(i * 40)), clock: .continuous)
                    try panel.injectText(PerformanceData.queries[i % PerformanceData.queries.count])
                }
                try await Task.sleep(for: .milliseconds(300)); report["after_typing_bytes"] = try ProcessMetrics.footprint()
                panel.hide()
                for tab in SettingsWindow.Tab.allCases { settings.setTab(tab); settings.window.contentView?.layoutSubtreeIfNeeded(); try settings.verifyHidden() }
                setup.refresh(); setup.window.contentView?.layoutSubtreeIfNeeded()
                report["after_preferences_bytes"] = try ProcessMetrics.footprint()
                settings.close(); setup.window.close(); try hidden()
                let sampler = RebuildSampler(), previous = files.metrics.completedUpdates, start = ObservationClock.now
                files.rebuild()
                do { try await wait { self.files.metrics.completedUpdates > previous && !self.files.isIndexing } }
                catch { _ = await sampler.stop(); throw error }
                let samples = await sampler.stop()
                report["rebuild_ms"] = ObservationClock.milliseconds(start, ObservationClock.now)
                report["rebuild_prepared_chunks"] = files.metrics.preparedChunks
                report["rebuild_sampled_peak_bytes"] = samples.samples > 0 ? samples.peak as Any : NSNull()
                report["rebuild_samples"] = samples.samples; report["rebuild_sample_failures"] = samples.failures
                report["rebuild_sample_gap_ms"] = PerformanceData.stats(samples.gaps)
                report["rebuild_sampling"] = "25 ms requested, sampled lower bound; no shipping helper process; sampler stopped before idle"
                report["after_rebuild_bytes"] = try ProcessMetrics.footprint()
                // No UI timer, activity, memory sampler or readiness polling during idle.
                try await Task.sleep(for: .seconds(3))
                var idle: [[String: Any]] = []
                for attempt in 0..<2 {
                    try hidden(); guard !panel.activityHeld else { throw SourceError("Latency activity retained during idle") }
                    let fileUpdates = files.metrics.completedUpdates, fileScans = files.metrics.completedScans, scans = catalog.completedScans, watch = catalog.watchDiagnostics
                    let cpu = ProcessMetrics.cpuSeconds(), wake = ProcessMetrics.wakeups(), start = ObservationClock.now
                    print("M6 idle interval \(attempt + 1) started"); fflush(stdout)
                    try await Task.sleep(for: .seconds(64))
                    let end = ObservationClock.now, endCPU = ProcessMetrics.cpuSeconds(), endWake = ProcessMetrics.wakeups()
                    let seconds = ObservationClock.milliseconds(start, end) / 1000
                    let changes = files.metrics.completedUpdates - fileUpdates, scanCount = catalog.completedScans - scans
                    let fileScanCount = files.metrics.completedScans - fileScans
                    let events = catalog.watchDiagnostics.since(watch)
                    let busy = fileScanCount > 0 || scanCount > 0 || files.isIndexing || events.relevantEvents > 0
                    var interval: [String: Any] = ["seconds": seconds, "cpu_seconds": endCPU - cpu, "cpu_percent_one_core": (endCPU-cpu)/seconds*100,
                        "file_updates": changes, "file_scans": fileScanCount, "catalog_scans": scanCount, "catalog_events": events.events, "catalog_relevant_events": events.relevantEvents,
                        "quiet": !busy, "activity_held": panel.activityHeld]
                    if let wake, let endWake { interval["interrupt_wakeups"] = endWake.interrupts - wake.interrupts; interval["package_idle_wakeups"] = endWake.packageIdle - wake.packageIdle }
                    else { interval["wakeups_result"] = "Untested: proc_pid_rusage unavailable" }
                    idle.append(interval)
                    if !busy { break }
                    if attempt == 0 { try await Task.sleep(for: .seconds(3)) }
                }
                report["idle"] = idle
                report["after_idle_bytes"] = try ProcessMetrics.footprint()
            }
            try hidden(); report["fake_registrations"] = effects.registrationCount
            report["fake_actions"] = effects.actionCount; report["focus_guards_checked"] = true
            report["scope"] = "Full retained production graph, isolated persisted SQLite, real filesystem/catalog/config watchers, real app and settings sources; hidden preferences layout, fake global effects. Fixture generator external and absent from app. No presented windows or screen capture."
            report["result"] = errors == 0 ? "Passed" : "Failed"; report["errors"] = errors
        } catch { report["result"] = "Failed"; report["errors"] = errors + 1; report["failure"] = String(describing: error) }
        report["thermal_end"] = ProcessInfo.processInfo.thermalState.rawValue
        try? PerformanceData.write(report, to: profile.directory.appendingPathComponent("diagnostics.json"))
    }
}
