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
    private var setupWindow: SetupWindow?
    private var settingsWindow: SettingsWindow?
    private var settingsModel: SettingsModel?
    private var menu: MenuController?
    private var hotkey: HotKeyRegistration?
    private var nativeRegistrar: NativeHotKeyRegistrar?
    private var actions: ActionDispatcher?
#if APPARATE_TESTING
    private var testEffects: TestEffects?
    private var profile: TestProfile?
#endif
    private var icons: IconLoader!
    private var files: FileIndexController?
#if APPARATE_TESTING
    private var diagnostics: AppTestDiagnostics?
    private var performance: FullPerformance?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let env = ProcessInfo.processInfo.environment
#if APPARATE_TESTING
            profile = try TestProfile.read(env)
            NSApp.setActivationPolicy(profile == nil ? .accessory : .prohibited)
            icons = IconLoader(fixtureOnly: profile?.mode == "fixtures")
            if let profile, profile.performance == "pipeline" || profile.performance == "latency" {
                Task(priority: .userInitiated) { await PerformanceVerification.run(profile) }; return
            }
            if let profile, profile.panelCheck != nil {
                Task(priority: .userInitiated) { await PanelVerification.run(profile) }
                return
            }
            if let profile, profile.settingsCheck {
                Task { await SettingsVerification.run(profile) }; return
            }
#else
            NSApp.setActivationPolicy(.accessory)
            icons = IconLoader()
#endif
            let directory = AppConfig.dataDirectory(environment: env)
            let firstRun = !FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path)
            let store = try ConfigStore(directory: directory); config = store
            let history = try UsageStore(directory: directory); usage = history
            var pathReader = PathReading()
            var openWith = OpenWithWorkspace.service(history: history)
            var presentationAllowed = true
#if APPARATE_TESTING
            if profile != nil {
                pathReader = .restricted(to: directory.path)
                openWith = OpenWithService { _,_ in OpenWithDiscovery(contentType: nil, claimed: []) }
                presentationAllowed = false
            }
#endif
            let session = LauncherSession(config: store.current, requiresFiles: true, pathReader: pathReader,
                openWith: openWith, usage: { try await history.snapshot() }); self.session = session
            let panel = PanelController(session: session, icons: icons, presentationAllowed: presentationAllowed); self.panel = panel
#if APPARATE_TESTING
            panel.onTiming = { [weak self] shown, commit in self?.diagnostics?.shownMS = shown; if let commit { self?.diagnostics?.commitProxyMS = commit } }
#endif
            let (executor, registrar) = effectServices(directory: directory)
            session.setPathAccess(FileAccessPolicy(observations: access?.observations ?? []))
            access?.onError = { [weak self] message in self?.logError(message) }
            var presence: @Sendable (URL) -> FilePresence = { filePresence($0) }
#if APPARATE_TESTING
            if profile != nil { presence = { _ in FilePresence.present } }
#endif
            let dispatcher = ActionDispatcher(executor: executor, presence: presence, recordOpenWith: { try await history.recordSuccessfulOpen(id: $0, contentType: $1, application: $2) }, record: { try await history.recordSuccessfulOpen(id: $0) })
            actions = dispatcher
            dispatcher.onHistoryError = { [weak self] _ in self?.logError("Usage history could not be saved.") }
            panel.rows.onDrop = { id in
                Task {
                    await dispatcher.recordUse(of: id)
                    session.successfulOpen()
                }
            }
            session.onOpenWithFailure = { [weak self] failure in
                guard let self else { return }
                self.panel?.hide()
                if let id = failure.missingID { self.catalog?.removeMissing(id); self.files?.removeMissing(id) }
                self.alertError(failure.reason, title: "Couldn’t find applications for \(failure.title)")
            }
            session.onError = { [weak self] message in self?.logError(message) }
            session.onAction = { [weak self] request in
                guard let self else { return }
                self.panel?.hide()
                Task {
                    if let failure = await dispatcher.perform(request) {
                        if let id = failure.missingID { self.catalog?.removeMissing(id); self.files?.removeMissing(id) }
                        let verb: String
                        switch request.operation { case .open: verb = "open"; case .reveal: verb = "reveal"; case .copyPath: verb = "copy the path for" }
                        self.alertError(failure.reason, title: "Couldn’t \(verb) \(failure.title)")
                    } else if request.operation == .open { self.session?.successfulOpen() }
                }
            }
            hotkey = HotKeyRegistration(registrar: registrar)
            let login: any LoginServicing
            let readSpotlight: () -> SpotlightShortcut
#if APPARATE_TESTING
            login = profile == nil ? NativeLoginService() : FixtureLoginService()
            readSpotlight = profile == nil ? NativeLoginService.spotlight : { .disabled }
#else
            login = NativeLoginService(); readSpotlight = NativeLoginService.spotlight
#endif
            let settings = SettingsModel(store: store, hotkey: hotkey!, access: access!, login: login, readSpotlight: readSpotlight)
            settingsModel = settings
            settingsWindow = SettingsWindow(model: settings, presentationAllowed: presentationAllowed)
            setupWindow = SetupWindow(model: settings, presentationAllowed: presentationAllowed)
            let menu = MenuController(presentationAllowed: presentationAllowed); self.menu = menu
            settings.onChange = { [weak self] in self?.refreshPreferences() }
            settings.retryHotkey()
            if settings.hotkeyError != nil && !(firstRun && settings.spotlightNotice) {
                alertError(settings.hotkeyError!, title: "Shortcut unavailable")
            }
            menu.onOpen = { [weak self] in self?.panel?.show() }
            menu.onSettings = { [weak self] in self?.showSettings() }
            menu.onQuit = { NSApp.terminate(nil) }
            panel.onSettings = { [weak self] in self?.showSettings() }
            setupWindow?.onChooseFolders = { [weak self] in self?.showSettings(tab: .folders) }
            settingsWindow?.onRevealConfig = { [weak self] in self?.preferencesAction { try await executor.reveal(store.file) } }
            let keyboard = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!
            settingsWindow?.onKeyboardShortcuts = { [weak self] in self?.preferencesAction { try await executor.openURL(keyboard) } }
            setupWindow?.onKeyboardShortcuts = settingsWindow?.onKeyboardShortcuts
            settingsWindow?.onPickFolders = { [weak self] window, completion in
#if APPARATE_TESTING
                guard self?.profile == nil else { completion([]); return }
#endif
                let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
                picker.allowsMultipleSelection = true; picker.treatsFilePackagesAsDirectories = false
                picker.beginSheetModal(for: window) { response in
                    MainActor.assumeIsolated { completion(response == .OK ? picker.urls.map(\.path) : []) }
                }
            }
            store.onChange = { [weak self] value, problems in
                guard let self else { return }
                self.session?.setConfig(value)
                self.files?.setConfig(value)
                self.settingsModel?.configChanged()
                self.latestConfigError = problems.last
                for problem in problems { self.logError(problem) }
            }
            latestConfigError = store.errors.last
            for problem in store.errors { logError(problem) }
            let paths = AppSource.defaultRoots.map(\.path) + [AppSource.finder.path]
            let source = SystemCatalogSource(cacheDirectory: directory)
#if APPARATE_TESTING
            if profile?.mode == "fixtures" {
                catalog = CatalogController(paths: [], loader: { CatalogLoad(snapshot: try TestProfile.fixtureCatalog(), watchPaths: []) })
            } else { catalog = CatalogController(paths: paths, loader: { try await source.load() }) }
#else
            catalog = CatalogController(paths: paths, loader: { try await source.load() })
#endif
            let fileStore = try FileIndexStore(directory: directory)
            let fileController = FileIndexController(config: store.current, store: fileStore,
                access: FileAccessPolicy(observations: access?.observations ?? []))
            files = fileController
            fileController.onError = { [weak self] in self?.logError($0) }
            fileController.onChange = { [weak self] snapshot in
                self?.session?.setFiles(snapshot); self?.refreshIndexStatus()
#if APPARATE_TESTING
                self?.diagnostics?.ready()
#endif
            }
            access?.onCompletion = { [weak self] observations in
                let policy = FileAccessPolicy(observations: observations)
                self?.session?.setPathAccess(policy); self?.files?.setAccess(policy)
            }
            access?.onChange = { [weak self] in self?.refreshPreferences() }
            fileController.onStatusChange = { [weak self] in self?.refreshIndexStatus() }
            settings.onRebuild = { [weak fileController] in fileController?.rebuild() }
            refreshPreferences()
            catalog?.onError = { [weak self] message in self?.logError(message) }
            catalog?.onChange = { [weak self] snapshot in
                guard let self else { return }
                self.icons.invalidate(); self.session?.setCatalog(snapshot)
#if APPARATE_TESTING
                self.diagnostics?.catalogPublished()
#endif
            }
#if APPARATE_TESTING
            if let profile, profile.performance == nil {
                diagnostics = AppTestDiagnostics(profile: profile, catalog: catalog, files: files, session: session, panel: panel,
                                                 access: access, setupWindow: setupWindow, settingsWindow: settingsWindow, menu: menu, effects: testEffects)
            }
#endif
            fileController.start(); catalog?.start()
#if APPARATE_TESTING
            if let profile, profile.performance == "full" || profile.performance == "prepare" {
                let measurement = FullPerformance(profile: profile, catalog: catalog!, files: fileController, session: session, panel: panel,
                    settings: settingsWindow!, setup: setupWindow!, menu: menu, effects: testEffects!)
                performance = measurement
                Task { await measurement.run() }
            }
            if profile == nil {
                if SetupWindow.shouldShow(configExisted: !firstRun, override: env["APPARATE_SHOW"]) { setupWindow?.show() }
                else if env["APPARATE_SHOW"] == "panel" { panel.show() }
            }
#else
            if firstRun { setupWindow?.show() }
#endif

        } catch {
            // Configuration failures terminate instead of running with partial services.
            NSLog("Startup failed: %@", error.localizedDescription); NSApp.terminate(nil)
        }
    }
    private func effectServices(directory: URL) -> (any ActionExecuting, any HotKeyRegistering) {
#if APPARATE_TESTING
        if profile != nil {
            let effects = TestEffects(); testEffects = effects
            access = FolderAccessController(directory: directory, probe: { folder in
                switch folder { case .desktop: .allowed; case .documents: .denied; case .downloads: .notFound }
            })
            return (effects, effects)
        }
#endif
        let native = NativeHotKeyRegistrar(); native.onPress = { [weak self] in self?.hotkeyPressed() }
        nativeRegistrar = native; access = FolderAccessController(directory: directory)
        return (NativeActionExecutor(), native)
    }
    private func hotkeyPressed() {
        if settingsWindow?.recording == true { settingsWindow?.recordCurrentShortcut(); return }
        if let key = hotkey?.active, let window = NSApp.keyWindow,
           window === settingsWindow?.window || window === setupWindow?.window,
           menu?.performWindowCommand(key, close: { window.performClose(nil) }) == true { return }
        if let key = hotkey?.active, panel?.isShowing == true,
           menu?.performWindowCommand(key, close: { panel?.hide() }) == true { return }
        panel?.toggle()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return false }
    private func showSettings(tab: SettingsWindow.Tab? = nil) { panel?.hide(); settingsWindow?.show(tab: tab) }
    private func refreshPreferences() {
        if settingsWindow?.window.isVisible == true { settingsWindow?.refresh() }
        if setupWindow?.window.isVisible == true { setupWindow?.refresh() }
        if let settingsModel { menu?.update(visible: settingsModel.config.showMenuBarIcon, activeKey: hotkey?.active) }
    }
    private func refreshIndexStatus() {
        guard let files else { return }
        settingsModel?.index = SettingsIndexState(count: files.snapshot?.count ?? 0, updated: files.snapshot?.lastUpdate,
            roots: files.rootStatuses, indexing: files.isIndexing, error: files.lastError)
    }
    private func preferencesAction(_ action: @escaping () async throws -> Void) {
        Task { do { try await action() } catch { settingsModel?.report(error.localizedDescription) } }
    }
    private func logError(_ reason: String) {
#if APPARATE_TESTING
        diagnostics?.errors += 1; performance?.errors += 1
        if profile != nil { return }
#endif
        NSLog("Apparate: %@", reason)
    }
    private func alertError(_ reason: String, title: String) {
#if APPARATE_TESTING
        diagnostics?.errors += 1
        if profile != nil { return }
#endif
        NSApp.activate()
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = reason
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
    func applicationWillTerminate(_ notification: Notification) { catalog?.stop(); files?.stop(); hotkey?.stop(); config?.stopWatching() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
