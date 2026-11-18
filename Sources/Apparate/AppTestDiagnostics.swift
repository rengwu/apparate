import AppKit
import ApparateCore

/// Test-only app orchestration. Fake effect adapters are installed before this
/// object exists; it observes production readiness and keeps diagnostics out of app wiring.
@MainActor final class AppTestDiagnostics {
    let profile: TestProfile?
    let catalog: CatalogController?
    let files: FileIndexController?
    let session: LauncherSession?
    let panel: PanelController?
    let access: FolderAccessController?
    let setupWindow: SetupWindow?
    let settingsWindow: SettingsWindow?
    let menu: MenuController?
    let testEffects: TestEffects?
    var errors = 0, publications = 0
    private var readyAt: ContinuousClock.Instant?
    private var readyCPU = 0.0
    private var observationPublications = 0, observationScans = 0, observationFileUpdates = 0
    private var observationReads = 0, observationReuses = 0, observationSnapshots = 0
    private var observationWatch = CatalogWatchDiagnostics()
    var shownMS: Double?, commitProxyMS: Double?
    private var captureWritten = false, testStarted = false, reportWritten = false
    init(profile: TestProfile, catalog: CatalogController?, files: FileIndexController?, session: LauncherSession?, panel: PanelController?, access: FolderAccessController?, setupWindow: SetupWindow?, settingsWindow: SettingsWindow?, menu: MenuController?, effects: TestEffects?) {
        self.profile = profile; self.catalog = catalog; self.files = files; self.session = session; self.panel = panel
        self.access = access; self.setupWindow = setupWindow; self.testEffects = effects
        self.settingsWindow = settingsWindow; self.menu = menu
        DispatchQueue.main.asyncAfter(deadline: .now() + profile.seconds + 60) { [weak self] in self?.finishTest() }
    }
    func catalogPublished() { publications += 1; ready() }
    func ready() {
        guard readyAt == nil, session?.isCatalogReady == true else { return }
        readyAt = .now; readyCPU = ProcessMetrics.cpuSeconds(); runRequestedWindow()
    }
    private func runRequestedWindow() {
        if let profile {
            guard !testStarted else { return }; testStarted = true
            if profile.show == "panel" { do { try panel?.beginHiddenShowing(); panel?.enterTestQuery(profile.query) } catch { errors += 1 } }
            else if profile.show == "setup" { Task { await access?.check() } }
            if profile.show != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self else { return }
                    do {
                        let file = profile.directory.appendingPathComponent("\(profile.show!).\(profile.show == "setup" ? "jpg" : "png")")
                        if profile.show == "panel" {
                            try self.panel?.verifyPendingPresentation()
                            try self.panel?.capture(to: file)
                        }
                        else { try self.setupWindow?.capture(to: file) }
                        self.captureWritten = FileManager.default.fileExists(atPath: file.path)
                        if profile.performAction { self.session?.act(.open) }
                    } catch { self.errors += 1 }
                }
            }
            let observe: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                self.readyAt = .now; self.readyCPU = ProcessMetrics.cpuSeconds()
                self.observationReads = self.catalog?.metadataReads ?? 0
                self.observationReuses = self.catalog?.reusedApps ?? 0
                self.observationSnapshots = self.catalog?.reusedSnapshots ?? 0
                self.observationWatch = self.catalog?.watchDiagnostics ?? CatalogWatchDiagnostics()
                self.observationFileUpdates = self.files?.metrics.completedUpdates ?? 0
                self.observationPublications = self.publications; self.observationScans = self.catalog?.completedScans ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + profile.seconds) { [weak self] in self?.finishTest() }
            }
            if profile.mode == "live-readonly" {
                // Exclude startup watch replay and cache writes from the quiet observation.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: observe)
            } else { observe() }
        }
    }
    func finishTest() {
        guard let profile, !reportWritten else { return }; reportWritten = true
        var hidden = true
        do { try panel?.verifyHidden(); try setupWindow?.verifyHidden(); try settingsWindow?.verifyHidden() }
        catch { hidden = false; errors += 1 }
        if menu?.nativeItemCount != 0 { hidden = false; errors += 1 }
        let footprint: Any
        do { footprint = try ProcessMetrics.footprint() } catch { footprint = NSNull(); errors += 1 }
        let elapsed = readyAt.map { durationMS($0.duration(to: .now)) / 1000 } ?? 0
        let cpu = readyAt == nil ? 0 : ProcessMetrics.cpuSeconds() - readyCPU
        let metrics = catalog?.metrics ?? CatalogMetrics()
        let firstMetrics = catalog?.firstMetrics ?? CatalogMetrics()
        var report: [String: Any] = ["mode": profile.mode, "ready": readyAt != nil, "errors": errors,
            "catalog_publications": publications, "item_count": catalog?.snapshot?.entries.count ?? 0,
            "observation_catalog_publications": publications - observationPublications,
            "observation_completed_scans": (catalog?.completedScans ?? 0) - observationScans,
            "app_count": metrics.appCount, "settings_count": metrics.settingsCount,
            "skipped_app_bundles": metrics.skippedApps, "malformed_settings_resources": metrics.malformedSettings,
            "app_scan_ms": metrics.appScanMS, "settings_load_ms": metrics.settingsLoadMS, "snapshot_prepare_ms": metrics.prepareMS,
            "settings_cache_hit": metrics.settingsCacheHit, "settings_cache_write_failed": metrics.settingsCacheWriteFailed,
            "completed_scans": catalog?.completedScans ?? 0,
            "first_app_scan_ms": firstMetrics.appScanMS, "first_settings_load_ms": firstMetrics.settingsLoadMS,
            "first_settings_cache_hit": firstMetrics.settingsCacheHit,
            "watch_healthy": catalog?.watchHealthy ?? false, "physical_footprint_bytes": footprint,
            "observation_seconds": elapsed, "cpu_seconds": cpu, "cpu_percent_one_core": elapsed > 0 ? cpu / elapsed * 100 : 0,
            "native_hotkey_registrations": 0, "native_actions": 0, "protected_folder_probes": 0,
            "native_status_items": menu?.nativeItemCount ?? 0, "native_login_changes": 0, "symbolichotkeys_writes": 0,
            "fake_registrations": testEffects?.registrationCount ?? 0, "fake_actions": testEffects?.actionCount ?? 0,
            "capture_written": captureWritten, "focus_guards_checked": hidden, "visible_profile": "none", "render_profile": profile.show ?? "none",
            "timing_trigger": "hidden owned-view driver; no physical/global key event",
            "commit_measurement": "not measured; hidden profiles never order a window",
            "capture_method": "app-owned view bitmap; vibrancy can differ from on-screen composition"]
        report["app_metadata_reads"] = metrics.appMetadataReads
        report["reused_app_bundles"] = metrics.reusedApps
        report["snapshot_reused"] = metrics.snapshotReused
        report["settings_memory_hit"] = metrics.settingsMemoryHit
        report["observation_app_metadata_reads"] = (catalog?.metadataReads ?? 0) - observationReads
        report["observation_reused_app_bundles"] = (catalog?.reusedApps ?? 0) - observationReuses
        report["observation_reused_snapshots"] = (catalog?.reusedSnapshots ?? 0) - observationSnapshots
        let events = (catalog?.watchDiagnostics ?? CatalogWatchDiagnostics()).since(observationWatch)
        report["catalog_events"] = ["batches": events.batches, "events": events.events, "relevant_events": events.relevantEvents,
            "reset_batches": events.resetBatches, "creation_checks": events.creationChecks,
            "root_events": events.rootEvents, "bundle_events": events.bundleEvents, "bundle_content_events": events.bundleContentEvents,
            "flags": Dictionary(uniqueKeysWithValues: events.flags.map { (String(format: "0x%08x", $0.key), $0.value) })]
        report["fake_application_opens"] = testEffects?.applicationOpens ?? 0
        report["fake_url_opens"] = testEffects?.urlOpens ?? 0
        report["file_unavailable_roots"] = files?.snapshot?.roots.filter { $0.status != .indexed }.count ?? 0
        report["file_unavailable_entries"] = files?.snapshot?.unavailableCount ?? 0
        report["discovered_app_count"] = files?.snapshot?.applicationCount ?? 0
        report["file_count"] = files?.snapshot?.count ?? 0
        report["file_loaded_from_disk"] = files?.metrics.loadedFromDisk ?? false
        report["file_disk_read_ms"] = files?.metrics.diskReadMS ?? 0
        report["file_prepare_ms"] = files?.metrics.prepareMS ?? 0
        report["file_crawl_ms"] = files?.metrics.crawlMS ?? 0
        report["file_save_ms"] = files?.metrics.saveMS ?? 0
        report["file_completed_updates"] = files?.metrics.completedUpdates ?? 0
        report["observation_file_updates"] = (files?.metrics.completedUpdates ?? 0) - observationFileUpdates
        report["file_watch_healthy"] = files?.watchHealthy ?? false
        if let shownMS { report["callback_to_show_return_ms"] = shownMS }
        if let commitProxyMS { report["callback_to_transaction_completion_ms"] = commitProxyMS }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: profile.directory.appendingPathComponent("diagnostics.json"), options: .atomic)
        } catch { NSLog("Test receipt could not be written.") }
        panel?.hide(); setupWindow?.hide(); NSApp.terminate(nil)
    }
}
