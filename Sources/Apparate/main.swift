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
    private var diagnostics: AppTestDiagnostics?
    private var files: FileIndexController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let env = ProcessInfo.processInfo.environment
            profile = try TestProfile.read(env)
            let directory = AppConfig.dataDirectory(environment: env)
            let firstRun = !FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path)
            let store = try ConfigStore(directory: directory); config = store
            let history = try UsageStore(directory: directory); usage = history
            let session = LauncherSession(config: store.current, requiresFiles: true, usage: { try await history.snapshot() }); self.session = session
            let panel = PanelController(session: session, icons: icons); self.panel = panel
            panel.onTiming = { [weak self] shown, commit in self?.diagnostics?.shownMS = shown; if let commit { self?.diagnostics?.commitProxyMS = commit } }
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
                        if let id = failure.missingID { self.catalog?.removeMissing(id); self.files?.removeMissing(id) }
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
                self.files?.setConfig(value)
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
            let fileStore = try FileIndexStore(directory: directory)
            let fileController = FileIndexController(config: store.current, store: fileStore,
                access: FileAccessPolicy(observations: access?.observations ?? []))
            files = fileController
            fileController.onError = { [weak self] in self?.logError($0) }
            fileController.onChange = { [weak self] snapshot in
                self?.session?.setFiles(snapshot); self?.diagnostics?.ready()
            }
            access?.onCompletion = { [weak self] observations in self?.files?.setAccess(FileAccessPolicy(observations: observations)) }
            catalog?.onError = { [weak self] message in self?.logError(message) }
            catalog?.onChange = { [weak self] snapshot in
                guard let self else { return }
                self.icons.invalidate(); self.session?.setCatalog(snapshot); self.diagnostics?.catalogPublished()
            }
            if let profile {
                diagnostics = AppTestDiagnostics(profile: profile, catalog: catalog, files: files, session: session, panel: panel,
                                                 access: access, accessWindow: accessWindow, effects: testEffects)
            }
            fileController.start(); catalog?.start()
            if profile == nil {
                if firstRun || env["APPARATE_SHOW"] == "setup" { accessWindow?.show() }
                else if env["APPARATE_SHOW"] == "panel" { panel.show() }
            }

        } catch {
            // Invalid test wiring fails closed before any native global effect is installed.
            NSLog("Startup failed: %@", error.localizedDescription); NSApp.terminate(nil)
        }
    }
    private func hotkeyPressed() {
        let start = ContinuousClock.now
        if panel?.isVisible == true { panel?.hide() } else { panel?.show(start: start) }
    }
    private func logError(_ reason: String) {
        diagnostics?.errors += 1
        if profile == nil { NSLog("Apparate: %@", reason) }
    }
    private func alertError(_ reason: String, title: String) {
        diagnostics?.errors += 1
        if profile != nil { return }
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
