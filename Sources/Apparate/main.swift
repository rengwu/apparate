import AppKit
import ApparateCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config: ConfigStore?
    private(set) var latestConfigError: String?
    private var usage: UsageStore?
    private var catalog: CatalogController?
    private var session: LauncherSession?
    private var panel: PanelController?
    private var access: FolderAccessController?
    private var accessWindow: AccessWindow?
    private var hotkey: HotKeyRegistration?
    private var nativeRegistrar: NativeHotKeyRegistrar?
    private var actions: ActionDispatcher?
    private var testEffects: TestEffects?
    private var profile: TestProfile?
    private let icons = IconLoader()
    private var errors = 0, publications = 0
    private var readyAt: ContinuousClock.Instant?
    private var readyCPU = 0.0
    private var observationPublications = 0, observationScans = 0
    private var shownMS: Double?, commitProxyMS: Double?
    private var captureWritten = false, testStarted = false, reportWritten = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let env = ProcessInfo.processInfo.environment
            profile = try TestProfile.read(env)
            let directory = AppConfig.dataDirectory(environment: env)
            let firstRun = !FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path)
            let store = try ConfigStore(directory: directory); config = store
            let history = try UsageStore(directory: directory); usage = history
            let session = LauncherSession(config: store.current, usage: { try await history.snapshot() }); self.session = session
            let panel = PanelController(session: session, icons: icons); self.panel = panel
            panel.onTiming = { [weak self] shown, commit in self?.shownMS = shown; if let commit { self?.commitProxyMS = commit } }
            let executor: any ActionExecuting
            let registrar: any HotKeyRegistering
            if profile != nil {
                let effects = TestEffects(); testEffects = effects; executor = effects; registrar = effects
                access = FolderAccessController(directory: directory, probe: { folder in
                    switch folder { case .desktop: .allowed; case .documents: .denied; case .downloads: .notFound }
                })
            } else {
                executor = NativeActionExecutor()
                let native = NativeHotKeyRegistrar(); native.onPress = { [weak self] in self?.hotkeyPressed() }
                nativeRegistrar = native; registrar = native
                access = FolderAccessController(directory: directory)
            }
            access?.onError = { [weak self] message in self?.logError(message) }
            accessWindow = AccessWindow(controller: access!)
            let presence: @Sendable (URL) -> FilePresence
            if profile == nil { presence = { url in filePresence(url) } }
            else { presence = { _ in FilePresence.present } }
            let dispatcher = ActionDispatcher(executor: executor, presence: presence, record: { try await history.recordSuccessfulOpen(id: $0) })
            actions = dispatcher
            dispatcher.onHistoryError = { [weak self] _ in self?.logError("Usage history could not be saved.") }
            session.onError = { [weak self] message in self?.logError(message) }
            session.onAction = { [weak self] request in
                guard let self else { return }
                self.panel?.hide()
                Task {
                    if let failure = await dispatcher.perform(request) {
                        if let id = failure.missingID { self.catalog?.removeMissing(id) }
                        let verb: String
                        switch request.operation { case .open: verb = "open"; case .reveal: verb = "reveal"; case .copyPath: verb = "copy the path for" }
                        self.alertError(failure.reason, title: "Couldn’t \(verb) \(failure.title)")
                    } else if request.operation == .open { self.session?.successfulOpen() }
                }
            }
            hotkey = HotKeyRegistration(registrar: registrar)
            do { try hotkey?.replace(with: store.current.hotKey) } catch { alertError(error.localizedDescription, title: "Shortcut unavailable") }
            store.onChange = { [weak self] value, problems in
                guard let self else { return }
                self.session?.setConfig(value)
                do { try self.hotkey?.replace(with: value.hotKey) } catch { self.alertError(error.localizedDescription, title: "Shortcut unavailable") }
                self.latestConfigError = problems.last
                for problem in problems { self.logError(problem) }
            }
            latestConfigError = store.errors.last
            for problem in store.errors { logError(problem) }
            if profile?.mode == "fixtures" {
                catalog = CatalogController(paths: [], loader: {
                    CatalogLoad(snapshot: try TestProfile.fixtureCatalog(), watchPaths: [])
                })
            } else {
                let paths = AppSource.defaultRoots.map(\.path) + [AppSource.finder.path]
                catalog = CatalogController(paths: paths, loader: {
                    try await Task.detached(priority: .utility) { try CatalogLoad.system(cacheDirectory: directory) }.value
                })
            }
            catalog?.onError = { [weak self] message in self?.logError(message) }
            catalog?.onChange = { [weak self] snapshot in
                guard let self else { return }
                self.publications += 1; self.icons.invalidate(); self.session?.setCatalog(snapshot)
                if self.readyAt == nil {
                    self.readyAt = .now; self.readyCPU = ProcessMetrics.cpuSeconds()
                    if self.profile == nil, let metrics = self.catalog?.metrics {
                        if metrics.skippedApps > 0 || metrics.malformedSettings > 0 {
                            NSLog("Catalog skipped %d malformed application bundles and %d settings records/resources.", metrics.skippedApps, metrics.malformedSettings)
                        }
                        if metrics.settingsCacheWriteFailed { NSLog("Settings cache could not be saved; system resources remain available.") }
                    }
                    self.runRequestedWindow()
                }
            }
            catalog?.start()
            if let profile {
                // Outer timeout also quits a test whose catalog never becomes ready.
                DispatchQueue.main.asyncAfter(deadline: .now() + profile.seconds + 15) { [weak self] in self?.finishTest() }
            } else if firstRun || env["APPARATE_SHOW"] == "setup" { accessWindow?.show() }
        } catch {
            // Invalid test wiring fails closed before any native global effect is installed.
            NSLog("Startup failed: %@", error.localizedDescription); NSApp.terminate(nil)
        }
    }
    private func hotkeyPressed() {
        let start = ContinuousClock.now
        if panel?.isVisible == true { panel?.hide() } else { panel?.show(start: start) }
    }
    private func runRequestedWindow() {
        if let profile {
            guard !testStarted else { return }; testStarted = true
            if profile.show == "panel" { hotkeyPressed(); panel?.enterTestQuery(profile.query) }
            else if profile.show == "setup" { accessWindow?.show(); Task { await access?.check() } }
            if profile.show != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self else { return }
                    do {
                        let file = profile.directory.appendingPathComponent("\(profile.show!).png")
                        if profile.show == "panel" {
                            try self.panel?.verifyPendingPresentation()
                            try self.panel?.capture(to: file)
                        }
                        else { try self.accessWindow?.capture(to: file) }
                        self.captureWritten = FileManager.default.fileExists(atPath: file.path)
                        if profile.performAction { self.session?.act(.open) }
                    } catch { self.errors += 1 }
                }
            }
            let observe: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                self.readyAt = .now; self.readyCPU = ProcessMetrics.cpuSeconds()
                self.observationPublications = self.publications; self.observationScans = self.catalog?.completedScans ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + profile.seconds) { [weak self] in self?.finishTest() }
            }
            if profile.mode == "live-readonly" {
                // Exclude startup watch replay and cache writes from the quiet observation.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: observe)
            } else { observe() }
        } else if ProcessInfo.processInfo.environment["APPARATE_SHOW"] == "panel" { panel?.show() }
    }
    private func logError(_ reason: String) {
        errors += 1
        if profile == nil { NSLog("Apparate: %@", reason) }
    }
    private func alertError(_ reason: String, title: String) {
        errors += 1
        if profile != nil { return }
        NSApp.activate()
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = reason
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
    private func finishTest() {
        guard let profile, !reportWritten else { return }; reportWritten = true
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
            "watch_healthy": catalog?.watchHealthy ?? false, "physical_footprint_bytes": ProcessMetrics.footprint(),
            "observation_seconds": elapsed, "cpu_seconds": cpu, "cpu_percent_one_core": elapsed > 0 ? cpu / elapsed * 100 : 0,
            "native_hotkey_registrations": 0, "native_actions": 0, "protected_folder_probes": 0,
            "fake_registrations": testEffects?.registrationCount ?? 0, "fake_actions": testEffects?.actionCount ?? 0,
            "capture_written": captureWritten, "visible_profile": profile.show ?? "none",
            "timing_trigger": "injected callback entry; no physical/global key event",
            "commit_measurement": "next implicit non-animated transaction completion; commit proxy, not presentation",
            "capture_method": "app-owned view bitmap; vibrancy can differ from on-screen composition"]
        if let shownMS { report["callback_to_show_return_ms"] = shownMS }
        if let commitProxyMS { report["callback_to_transaction_completion_ms"] = commitProxyMS }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: profile.directory.appendingPathComponent("diagnostics.json"), options: .atomic)
        } catch { NSLog("Test receipt could not be written.") }
        panel?.hide(); accessWindow?.hide(); NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) { catalog?.stop(); hotkey?.stop(); config?.stopWatching() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
