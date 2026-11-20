import Foundation
import ApparateCore
import Synchronization

@MainActor private final class LoginFake: LoginServicing {
    var state = LoginState.notRegistered, reject = false, calls: [Bool] = []
    func setEnabled(_ enabled: Bool) throws {
        calls.append(enabled); if reject { throw SourceError("Fixture login refused") }
        state = enabled ? .enabled : .notRegistered
    }
}
@MainActor func settingsTests(_ h: Harness) async {
    await h.test("settings: Open With preserves external fields, rejects stale keys and launcher clashes") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConfigStore(directory: dir); defer { store.stopWatching() }
        let registrar = RegistrarFake(), keys = HotKeyRegistration(registrar: registrar)
        let model = SettingsModel(store: store, hotkey: keys, access: FolderAccessController(directory: dir, probe: { _ in .allowed }), login: LoginFake(), readSpotlight: { .disabled })
        model.retryHotkey(); let registrations = registrar.operations
        var chosen = AppConfig.HotKey.openWithDefault; chosen.keyCode = 40; chosen.modifiers = 2304; chosen.display = "⌥⌘K"
        var external = model.config; external.showMenuBarIcon = false
        try JSONEncoder().encode(external).write(to: store.file, options: .atomic)
        try expect(model.set(\.openWithKey, from: .openWithDefault, to: chosen) && !model.config.showMenuBarIcon && registrar.operations == registrations)
        external = model.config; external.openWithKey = .openWithDefault
        try JSONEncoder().encode(external).write(to: store.file, options: .atomic)
        try expect(!model.set(\.openWithKey, from: chosen, to: chosen) && model.config.openWithKey == .openWithDefault)
        try expect(!model.setHotkey(.openWithDefault, expected: model.config.hotKey) && keys.active == model.config.hotKey && registrar.operations == registrations)
        let good = model.config; external.openWithKey.keyCode = 0
        try JSONEncoder().encode(external).write(to: store.file, options: .atomic); store.reload()
        try expect(!model.editable && model.config == good)
    }
    await h.test("settings: result location writes preserve other fields, reject conflicts and roll back disk failure") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        var failWrite = false
        let store = try ConfigStore(directory: dir, writeData: { data, url in
            if failWrite { throw SourceError("Fixture disk full") }; try data.write(to: url, options: .atomic)
        }); defer { store.stopWatching() }
        let model = SettingsModel(store: store, hotkey: HotKeyRegistration(registrar: RegistrarFake()), access: FolderAccessController(directory: dir, probe: { _ in .allowed }), login: LoginFake(), readSpotlight: { .unknown })
        var external = model.config; external.showMenuBarIcon = false
        try JSONEncoder().encode(external).write(to: store.file, options: .atomic)
        try expect(model.set(\.resultLocation, from: .inline, to: .below) && !model.config.showMenuBarIcon)
        external = model.config; external.resultLocation = .inline
        try JSONEncoder().encode(external).write(to: store.file, options: .atomic)
        try expect(!model.set(\.resultLocation, from: .below, to: .right) && model.config.resultLocation == .inline)
        let saved = try Data(contentsOf: store.file); failWrite = true
        try expect(!model.set(\.resultLocation, from: .inline, to: .right) && model.config.resultLocation == .inline)
        try expect(try Data(contentsOf: store.file) == saved)
    }
    await h.test("settings: fresh field updates preserve unrelated external edits and reject conflicts") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConfigStore(directory: dir); defer { store.stopWatching() }
        let model = SettingsModel(store: store, hotkey: HotKeyRegistration(registrar: RegistrarFake()), access: FolderAccessController(directory: dir, probe: { _ in .allowed }), login: LoginFake(), readSpotlight: { .unknown })
        let old = model.config
        var external = old; external.showMenuBarIcon = false
        try JSONEncoder().encode(external).write(to: store.file, options: .atomic)
        try expect(model.set(\.searchURL, from: old.searchURL, to: SearchPreset.google.url))
        try expect(!model.config.showMenuBarIcon && model.config.searchURL == SearchPreset.google.url)
        external = model.config; external.searchURL = SearchPreset.kagi.url
        try JSONEncoder().encode(external).write(to: store.file, options: .atomic)
        try expect(!model.set(\.searchURL, from: SearchPreset.google.url, to: SearchPreset.bing.url))
        try expect(model.config.searchURL == SearchPreset.kagi.url && model.error?.contains("changed") == true)
        let broken = Data("{broken".utf8); try broken.write(to: store.file, options: .atomic); store.reload()
        try expect(!model.editable && !model.set(\.respectGitignore, from: true, to: false))
        try expect(try Data(contentsOf: store.file) == broken)
        try JSONEncoder().encode(external).write(to: store.file, options: .atomic); model.refresh()
        try expect(model.editable && model.set(\.respectGitignore, from: true, to: false))
    }
    await h.test("settings: hotkey reservation rolls back save failure and avoids config-callback double registration") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        var failWrite = false
        let store = try ConfigStore(directory: dir, writeData: { data, url in
            if failWrite { throw SourceError("Fixture disk full") }; try data.write(to: url, options: .atomic)
        }); defer { store.stopWatching() }
        let registrar = RegistrarFake(), keys = HotKeyRegistration(registrar: registrar)
        let model = SettingsModel(store: store, hotkey: keys, access: FolderAccessController(directory: dir, probe: { _ in .allowed }), login: LoginFake(), readSpotlight: { .disabled })
        store.onChange = { _, _ in model.configChanged() }; model.retryHotkey()
        let old = store.current.hotKey, original = try Data(contentsOf: store.file)
        var next = old; next.keyCode = 111; next.modifiers = 6400; next.display = "⌃⌥⇧F12"
        registrar.reject = true
        try expect(!model.setHotkey(next, expected: old) && keys.active == old)
        try expect(try Data(contentsOf: store.file) == original)
        registrar.reject = false; failWrite = true
        try expect(!model.setHotkey(next, expected: old) && keys.active == old)
        try expect(registrar.operations.suffix(2) == ["register:3", "unregister:3"])
        try expect(try Data(contentsOf: store.file) == original)
        failWrite = false
        try expect(model.setHotkey(next, expected: old) && keys.active == next && store.current.hotKey == next)
        try expect(registrar.operations.suffix(2) == ["register:4", "unregister:1"])
        let before = registrar.operations
        try expect(model.setHotkey(next, expected: next)); try expect(registrar.operations == before)
    }
    await h.test("settings: prefix validation and presets share config rules") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConfigStore(directory: dir); defer { store.stopWatching() }
        let model = SettingsModel(store: store, hotkey: HotKeyRegistration(registrar: RegistrarFake()), access: FolderAccessController(directory: dir, probe: { _ in .allowed }), login: LoginFake(), readSpotlight: { .unknown })
        let initial = model.config
        for prefix in ["", "ab", "/", "~", "a", "1", "?", " "] { try expect(!model.setPrefix(scope: .apps, expected: nil, value: prefix) && model.config == initial) }
        try expect(model.setPrefix(scope: .apps, expected: nil, value: "!"))
        var external = model.config; external.prefixes["commands"] = ":"
        try JSONEncoder().encode(external).write(to: store.file, options: .atomic)
        try expect(model.setPrefix(scope: .apps, expected: "!", value: "@") && model.config.prefixes["commands"] == ":")
        try expect(model.setPrefix(scope: .apps, expected: "@", value: nil))
        for preset in SearchPreset.allCases { try expect(model.set(\.searchURL, from: model.config.searchURL, to: preset.url) && model.preset == preset) }
        try expect(!model.set(\.searchURL, from: model.config.searchURL, to: "https://example.test/no-query"))
        try expect(model.set(\.searchURL, from: model.config.searchURL, to: "https://example.test/find?q={query}") && model.preset == nil)
    }
    await h.test("settings: folders normalize, retain depths, conflict independently and gate rebuild") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConfigStore(directory: dir); defer { store.stopWatching() }
        var config = AppConfig(); config.folders = [.init(path: "/Fixture/Projects", depth: 7)]; try store.save(config)
        let model = SettingsModel(store: store, hotkey: HotKeyRegistration(registrar: RegistrarFake()), access: FolderAccessController(directory: dir, probe: { _ in .allowed }), login: LoginFake(), readSpotlight: { .unknown }, home: "/Fixture")
        try expect(model.addFolders(["~/Projects/./", "/Fixture/Projects/Sub"]) && model.config.folders.count == 2 && model.config.folders[0].depth == 7)
        let saved = model.config
        try expect(model.addFolders([]) && model.config == saved)
        for depth in [0,31] { try expect(!model.changeFolder(path: "~/Projects", expectedDepth: 7, depth: depth)) }
        try expect(model.changeFolder(path: "~/Projects", expectedDepth: 7, depth: 30))
        try expect(!model.changeFolder(path: "~/Projects", expectedDepth: 7, depth: nil))
        try expect(model.changeFolder(path: "~/Projects", expectedDepth: 30, depth: nil) && model.config.folders.count == 1)
        var rebuilds = 0; model.onRebuild = { rebuilds += 1 }
        model.rebuild(); model.index.indexing = true; model.rebuild(); try expect(rebuilds == 1)
        try expect(model.displayed("/Fixture/Projects") == "~/Projects")
    }
    await h.test("settings: Spotlight tri-state binding and shortcut readiness") {
        func prefs(_ enabled: Any, _ parameters: [Any] = [65535,49,1 << 20]) -> [String: Any] { ["64": ["enabled": enabled, "value": ["type": "standard", "parameters": parameters]]] }
        try expect(SpotlightShortcut.read(nil) == .unknown)
        try expect(SpotlightShortcut.read([:]) == .unknown)
        try expect(SpotlightShortcut.read(prefs(true)).usesCommandSpace)
        try expect(SpotlightShortcut.read(prefs(false)) == .disabled)
        try expect(SpotlightShortcut.read(prefs(1)) == .unknown)
        for bad: [Any] in [[49], [0, "49", 1 << 20], [0,true,1 << 20], [0,-1,1 << 20], [0,49,Double.infinity]] { try expect(SpotlightShortcut.read(prefs(true,bad)) == .unknown) }
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConfigStore(directory: dir); defer { store.stopWatching() }
        let registrar = RegistrarFake(), keys = HotKeyRegistration(registrar: registrar)
        var observed = SpotlightShortcut.unknown
        let model = SettingsModel(store: store, hotkey: keys, access: FolderAccessController(directory: dir, probe: { _ in .allowed }), login: LoginFake(), readSpotlight: { observed })
        model.refresh(); try expect(!model.shortcutReady && !model.spotlightNotice)
        observed = .enabled(keyCode: 49, modifiers: 1 << 20); model.refresh(); try expect(model.spotlightNotice && !model.shortcutReady)
        observed = .enabled(keyCode: 49, modifiers: 1 << 19); model.refresh(); try expect(!model.spotlightNotice && model.shortcutReady)
        var other = model.config.hotKey; other.keyCode = 40; other.display = "⌘K"
        try expect(model.setHotkey(other, expected: model.config.hotKey)); observed = .unknown; model.refresh(); try expect(model.shortcutReady)
        keys.stop(); registrar.reject = true; model.refresh(); try expect(!model.shortcutReady && model.hotkeyError != nil)
        registrar.reject = false; model.refresh(); try expect(model.shortcutReady)
    }
    await h.test("settings: login states are observed independently of config; failures do not fake success") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConfigStore(directory: dir); defer { store.stopWatching() }
        let login = LoginFake(), model = SettingsModel(store: store, hotkey: HotKeyRegistration(registrar: RegistrarFake()), access: FolderAccessController(directory: dir, probe: { _ in .allowed }), login: login, readSpotlight: { .disabled })
        let bytes = try Data(contentsOf: store.file)
        for state in [LoginState.notRegistered,.enabled,.requiresApproval,.unavailable] { login.state = state; model.refresh(); try expect(model.loginState == state) }
        login.state = .requiresApproval; model.refresh(); model.setLogin(false)
        try expect(model.loginState == .notRegistered && login.calls == [false])
        login.reject = true; model.setLogin(true); try expect(model.loginState == .notRegistered && model.error != nil)
        try expect(try Data(contentsOf: store.file) == bytes)
    }
    await h.test("settings: access refresh never probes; explicit check, cancel and saved hints") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConfigStore(directory: dir); defer { store.stopWatching() }
        let calls = Mutex<[AccessFolder]>([])
        let access = FolderAccessController(directory: dir, probe: { folder in calls.withLock { $0.append(folder) }; try? await Task.sleep(for: .milliseconds(20)); return .allowed })
        let model = SettingsModel(store: store, hotkey: HotKeyRegistration(registrar: RegistrarFake()), access: access, login: LoginFake(), readSpotlight: { .disabled }, home: "/Fixture")
        for _ in 0..<3 { model.refresh() }
        try expect(calls.withLock { $0.isEmpty } && model.needsAccess && !model.accessReady)
        let original = store.current
        var outside = original; outside.folders = []; try store.save(outside)
        try expect(model.needsAccess && calls.withLock { $0.isEmpty }, "Path access must be available without adding an index root")
        try store.save(original)
        model.requestAccess(); model.cancelAccess()
        try await Task.sleep(for: .milliseconds(30))
        try expect(calls.withLock { $0.isEmpty }, "Closing before a scheduled check starts must cancel it")
        let task = Task { await access.check() }; try await eventually { access.busy }
        access.cancelPending(); await task.value
        try expect(calls.withLock { $0.count } == 1 && !model.accessReady && !access.busy)
        await access.check(); try expect(model.accessReady && !model.needsAccess)
        var denied = FileRoot(path: "/Fixture/Desktop", depth: 10); denied.status = .denied
        model.index.roots = [denied]; try expect(model.needsAccess)
        let reopened = FolderAccessController(directory: dir, probe: { _ in throwawayProbeFailure() })
        try expect(reopened.observations == access.observations)
    }
    await h.test("settings: index text uses snapshot dates and distinguishes loading from empty") {
        let now = Date(timeIntervalSince1970: 2000)
        var state = SettingsIndexState(count: 13412, updated: now.addingTimeInterval(-120))
        try expect(state.text(now: now).contains("2 minutes ago"))
        state.indexing = true; try expect(state.text(now: now).hasSuffix("Indexing…"))
        state.indexing = false; state.updated = now.addingTimeInterval(300); try expect(state.text(now: now).hasSuffix("just now"))
        try expect(SettingsIndexState().text(now: now) == "No indexed items")
    }
}
private func throwawayProbeFailure() -> AccessStatus { fatalError("A saved access hint must not trigger a probe") }
