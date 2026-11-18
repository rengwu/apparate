import AppKit
import ApparateCore
import Synchronization

private struct SettingsCheckFailure: Error, CustomStringConvertible { let description: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw SettingsCheckFailure(description: message) } }
@MainActor private final class SettingsRegistrar: HotKeyRegistering {
    var count = 0, reject = false
    var active = Set<Int>()
    func register(_ key: AppConfig.HotKey) throws -> Int {
        count += 1; if reject { throw SourceError("Fixture shortcut refused") }; active.insert(count); return count
    }
    func unregister(_ token: Int) { active.remove(token) }
}
@MainActor enum SettingsVerification {
    static func run(_ profile: TestProfile) async {
        var report: [String: Any] = ["mode": "fixtures", "settings_check": true, "native_actions": 0, "native_hotkey_registrations": 0,
            "native_login_changes": 0, "native_status_items": 0, "protected_folder_probes": 0, "symbolichotkeys_writes": 0,
            "fake_actions": 0, "visible_profile": "none", "capture_method": "hidden owned preferences content; native toolbar chrome/menu appearance remain supervised"]
        defer { NSApp.terminate(nil) }
        let registrar = SettingsRegistrar(), login = FixtureLoginService(), probes = Mutex(0)
        do {
            let store = try ConfigStore(directory: profile.directory); defer { store.stopWatching() }
            var config = store.current; config.hotKey = AppConfig.HotKey()
            config.folders = [AppConfig.Folder(path: "/Fixture/Projects", depth: 10), .init(path: "/Fixture/Desktop", depth: 10), .init(path: "/Fixture/Documents", depth: 10), .init(path: "/Fixture/Downloads", depth: 10)]
            try store.save(config)
            let keys = HotKeyRegistration(registrar: registrar)
            let access = FolderAccessController(directory: profile.directory, probe: { folder in
                probes.withLock { $0 += 1 }; return folder == .desktop ? .allowed : folder == .documents ? .denied : .notFound
            })
            var spotlight = SpotlightShortcut.enabled(keyCode: 49, modifiers: 1 << 20)
            let model = SettingsModel(store: store, hotkey: keys, access: access, login: login, readSpotlight: { spotlight }, home: "/Fixture")
            let settings = SettingsWindow(model: model, presentationAllowed: false), setup = SetupWindow(model: model, presentationAllowed: false)
            let menu = MenuController(presentationAllowed: false)
            let session = LauncherSession(config: config, usage: { UsageSnapshot() })
            let panel = PanelController(session: session, icons: IconLoader(fixtureOnly: true), presentationAllowed: false)
            var routes: [String] = []
            func showSettings(_ tab: SettingsWindow.Tab? = nil) { panel.hide(); settings.show(tab: tab); routes.append("settings:" + settings.tab.rawValue) }
            menu.onOpen = { routes.append("open") }; menu.onSettings = { showSettings() }; menu.onQuit = { routes.append("quit") }
            setup.onChooseFolders = { showSettings(.folders) }; panel.onSettings = { showSettings() }
            model.onChange = { settings.refresh(); setup.refresh(); menu.update(visible: model.config.showMenuBarIcon, activeKey: keys.active) }
            store.onChange = { _, _ in model.configChanged() }; access.onChange = { settings.refresh(); setup.refresh() }
            model.retryHotkey(); model.onChange?()
            var roots = config.folders.map { FileRoot(path: $0.path, depth: $0.depth) }
            for i in roots.indices { roots[i].status = i == 0 ? .indexed : .waitingForAccess }
            model.index = SettingsIndexState(count: 13412, updated: Date().addingTimeInterval(-120), roots: roots)
            try check(!model.shortcutReady && model.spotlightNotice, "Spotlight conflict presentation")
            try check(SetupWindow.shouldShow(configExisted: false, override: nil) && !SetupWindow.shouldShow(configExisted: true, override: nil) && SetupWindow.shouldShow(configExisted: true, override: "setup"), "First-run eligibility")
            for _ in 0..<3 { model.refresh() }
            try check(probes.withLock { $0 } == 0, "Window refresh probed protected folders")
            let initialCount = registrar.count
            spotlight = .disabled; model.refresh(); try check(model.shortcutReady && registrar.count == initialCount, "Refresh re-registered an active shortcut")
            spotlight = .enabled(keyCode: 49, modifiers: 1 << 20); model.refresh()
            var keyboardRequests = 0
            settings.onKeyboardShortcuts = { keyboardRequests += 1 }
            (try control("keyboard", in: settings.window) as! NSButton).performClick(nil)
            try check(keyboardRequests == 1, "Keyboard link route")
            for dark in [false,true] {
                for tab in SettingsWindow.Tab.allCases { settings.setTab(tab); try settings.capture(to: profile.directory.appendingPathComponent("settings-\(tab.rawValue.lowercased())-\(dark ? "dark" : "light").jpg"), dark: dark) }
                try setup.capture(to: profile.directory.appendingPathComponent("setup-incomplete-\(dark ? "dark" : "light").jpg"), dark: dark)
                try checkSetupLayout(setup)
            }
            try check(menu.menu.items.map(\.title) == ["Open Apparate", "Settings…", "", "Quit Apparate"], "Menu order/titles")
            try check(menu.menu.items[0].keyEquivalent == " " && menu.menu.items[0].keyEquivalentModifierMask == .command && menu.menu.items[1].keyEquivalent == "," && menu.menu.items[3].keyEquivalent == "q", "Menu equivalents")
            menu.menu.performActionForItem(at: 0); menu.menu.performActionForItem(at: 1); menu.menu.performActionForItem(at: 3)
            try check(routes == ["open", "settings:Folders", "quit"], "Menu routes")
            settings.setTab(.general)
            let icon = try control("menu-icon", in: settings.window) as! NSButton
            icon.performClick(nil); try check(!model.config.showMenuBarIcon && !menu.itemInstalled && menu.nativeItemCount == 0, "Hide status item")
            setup.chooseFolders(); try check(settings.tab == .folders && routes.last == "settings:Folders", "Choose Folders route")
            try panel.beginHiddenShowing()
            let comma = event(",", code: 43, flags: .command)
            try check(panel.keyEquivalent(comma) && !session.model.visible && !panel.activityHeld, "Panel settings route leaked showing/activity")
            try check(menu.applicationMenu.items[2].submenu?.items[0].keyEquivalent == "w", "Close menu missing")
            try check(menu.applicationMenu.items[0].submenu?.items.last?.keyEquivalent == "q", "Quit menu missing")
            var closed = 0, windowKey = config.hotKey; windowKey.keyCode = 13
            try check(menu.performWindowCommand(windowKey, close: { closed += 1 }) && closed == 1, "Assigned global Cmd-W swallowed window close")
            windowKey.keyCode = 12
            try check(menu.performWindowCommand(windowKey, close: {}) && routes.last == "quit", "Assigned global Cmd-Q swallowed quit")
            windowKey.keyCode = 43
            try check(menu.performWindowCommand(windowKey, close: {}) && routes.last == "settings:Folders", "Assigned global Cmd-comma swallowed Settings")
            settings.setTab(.general); settings.startRecording(); _ = settings.record(event("", code: 53))
            try check(!settings.recording && keys.active == model.config.hotKey, "Recorder Esc")
            settings.startRecording(); settings.setTab(.search); try check(!settings.recording, "Recorder tab cleanup")
            settings.startRecording(); settings.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification)); try check(!settings.recording, "Recorder focus cleanup")
            settings.setTab(.general); settings.startRecording(); registrar.reject = true
            _ = settings.record(event("k", code: 40, flags: [.command,.option])); registrar.reject = false
            try check(model.config.hotKey == config.hotKey && keys.active == config.hotKey && registrar.active.count == 1, "Refused shortcut changed active key")
            settings.startRecording(); _ = settings.record(event("k", code: 40, flags: [.command,.option]))
            try check(model.config.hotKey.keyCode == 40 && model.shortcutReady && menu.menu.items[0].keyEquivalent == "k", "Recorded shortcut not saved")
            let count = registrar.count; settings.startRecording(); settings.recordCurrentShortcut()
            try check(!settings.recording && registrar.count == count, "Current shortcut was re-registered")
            settings.setTab(.search)
            let url = try control("url", in: settings.window) as! NSTextField
            try edit(url, value: "bad-url", window: settings.window)
            try check(model.error != nil && model.config.searchURL == config.searchURL, "Invalid native URL edit saved")
            try settings.capture(to: profile.directory.appendingPathComponent("settings-validation-dark.jpg"), dark: true)
            try edit(url, value: SearchPreset.kagi.url, window: settings.window)
            try check(model.preset == .kagi && model.error == nil, "Valid native URL edit did not save")
            settings.window.makeFirstResponder(url)
            guard let editor = url.currentEditor() as? NSTextView else { throw SettingsCheckFailure(description: "Missing native field editor") }
            editor.insertText("unsaved", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            try check(model.config.searchURL == SearchPreset.kagi.url && url.stringValue == SearchPreset.kagi.url, "Native Esc did not restore saved value")
            let prefixTable = try control("prefix-table", in: settings.window) as! NSTableView
            prefixTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try edit(try cell(prefixTable, column: 0, row: 0), value: "/", window: settings.window)
            try check(model.config.prefixes == config.prefixes && model.error != nil, "Invalid native prefix saved")
            (try control("prefix-remove", in: settings.window) as! NSButton).performClick(nil)
            try check(model.config.prefixes["settings"] == nil, "Native prefix removal")
            settings.beginPrefix(.settings)
            try edit(try cell(prefixTable, column: 0, row: 0), value: "!", window: settings.window)
            try check(model.config.prefixes["settings"] == "!", "Native prefix draft not saved")
            let preset = try control("preset", in: settings.window) as! NSPopUpButton
            preset.selectItem(withTitle: "Custom"); preset.sendAction(preset.action!, to: preset.target)
            try check(model.config.searchURL == SearchPreset.kagi.url && url.currentEditor() != nil, "Custom lost URL or focus")
            settings.window.makeFirstResponder(nil)
            settings.setTab(.folders)
            var picked = 0, rebuilds = 0
            settings.onPickFolders = { _, completion in picked += 1; completion(picked == 1 ? [] : ["/Fixture/Projects/./", "/Fixture/Extra"]) }
            let add = try control("folder-add", in: settings.window) as! NSButton
            add.performClick(nil); try check(model.config.folders.count == 4, "Picker cancellation changed config")
            add.performClick(nil); try check(model.config.folders.count == 5 && model.config.folders[0].depth == 10, "Picker duplicates or new folder")
            let folderTable = try control("folder-table", in: settings.window) as! NSTableView
            folderTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try edit(try cell(folderTable, column: 1, row: 0), value: "31", window: settings.window)
            try check(model.config.folders[0].depth == 10 && model.error != nil, "Invalid native depth saved")
            try edit(try cell(folderTable, column: 1, row: 0), value: "12", window: settings.window)
            try check(model.config.folders[0].depth == 12 && model.error == nil, "Native depth did not save")
            var reordered = model.config; reordered.folders.reverse(); try store.save(reordered)
            try check(folderTable.selectedRow == 4, "Folder selection followed ordinal after external reorder")
            (try control("folder-remove", in: settings.window) as! NSButton).performClick(nil)
            try check(!model.config.folders.contains { $0.path == "/Fixture/Projects" }, "Remove targeted wrong folder")
            try check(folderTable.selectedRow == -1, "Removed folder selection moved to another identity")
            model.onRebuild = { rebuilds += 1 }
            let rebuild = try control("rebuild", in: settings.window) as! NSButton
            rebuild.performClick(nil); model.index.indexing = true; rebuild.performClick(nil)
            try check(rebuilds == 1 && !rebuild.isEnabled, "Rebuild was reentrant")
            model.index.indexing = false
            let allow = try control("allow", in: settings.window) as! NSButton
            try check(!allow.isHidden && probes.withLock { $0 } == 0, "Retry access missing or implicit probe")
            allow.performClick(nil)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while (!access.busy && probes.withLock({ $0 }) == 0) || access.busy {
                try check(ContinuousClock.now < deadline, "Fixture access check timed out"); await Task.yield()
            }
            try check(probes.withLock { $0 } == 3 && !model.accessReady && model.accessText.contains("Denied") && model.accessText.contains("Not found"), "Partial permission status")
            try setup.capture(to: profile.directory.appendingPathComponent("setup-partial-light.jpg"), dark: false)
            try checkSetupLayout(setup)
            setup.finish(); try check(!setup.window.isVisible, "Done failed on incomplete setup")
            setup.checkAccess(); setup.finish()
            for _ in 0..<4 { await Task.yield() }
            try check(probes.withLock { $0 } == 3, "Closing before a scheduled check starts must cancel it")
            settings.setTab(.general)
            login.state = .requiresApproval; model.refresh()
            let loginButton = try control("login", in: settings.window) as! NSButton
            try check(loginButton.state == .mixed, "Approval state hidden")
            try settings.capture(to: profile.directory.appendingPathComponent("settings-login-approval-light.jpg"), dark: false)
            loginButton.performClick(nil); try check(login.changes == [false] && model.loginState == .notRegistered, "Approval-pending unregister")
            login.failure = true; model.setLogin(true); try check(model.loginState == .notRegistered && model.error != nil, "Login failure faked success")
            let valid = try Data(contentsOf: store.file), broken = Data("{broken".utf8)
            try broken.write(to: store.file, options: .atomic); store.reload()
            try check(!model.editable && !loginButton.isEnabled, "Broken config did not disable controls")
            var reveals = 0; settings.onRevealConfig = { reveals += 1 }
            (try control("reveal", in: settings.window) as! NSButton).performClick(nil)
            try check(reveals == 1 && (try? Data(contentsOf: store.file)) == broken, "Broken-file recovery path")
            try settings.capture(to: profile.directory.appendingPathComponent("settings-broken-config-dark.jpg"), dark: true)
            try valid.write(to: store.file, options: .atomic); store.reload(); try check(model.editable, "Config repair")
            settings.startRecording(); settings.close(); try check(!settings.recording, "Recorder close cleanup")
            panel.hide(); setup.hide()
            try settings.verifyHidden(); try setup.verifyHidden(); try panel.verifyHidden()
            try check(menu.nativeItemCount == 0 && !NSApp.isActive, "Test installed native UI")
            report["fake_registrations"] = registrar.count; report["fake_login_changes"] = login.changes.count; report["fake_picker_calls"] = picked
            report["fake_access_probes"] = probes.withLock { $0 }; report["fake_reveals"] = reveals
            report["fake_keyboard_links"] = keyboardRequests
            report["menu_graph"] = menu.menu.items.map { ["title": $0.title, "key_equivalent": $0.keyEquivalent] }
            report["routes"] = routes; report["toolbar_tabs"] = SettingsWindow.Tab.allCases.map(\.rawValue)
            report["ready"] = true; report["errors"] = 0; report["result"] = "Passed"; report["focus_guards_checked"] = true
        } catch {
            report["ready"] = false; report["errors"] = 1; report["result"] = "Failed"; report["failure"] = String(describing: error)
            report["fake_registrations"] = registrar.count; report["focus_guards_checked"] = !NSApp.isActive
        }
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: profile.directory.appendingPathComponent("diagnostics.json"), options: .atomic) }
        catch { NSLog("Settings verification receipt could not be saved.") }
    }
    private static func control(_ id: String, in window: NSWindow) throws -> NSControl {
        func find(_ view: NSView) -> NSControl? {
            if view.identifier?.rawValue == id { return view as? NSControl }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let content = window.contentView, let result = find(content) else { throw SettingsCheckFailure(description: "Missing control " + id) }
        return result
    }
    private static func event(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    private static func cell(_ table: NSTableView, column: Int, row: Int) throws -> NSTextField {
        guard let field = (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField else { throw SettingsCheckFailure(description: "Missing table editor") }
        return field
    }
    private static func checkSetupLayout(_ setup: SetupWindow) throws {
        let title = try control("setup-shortcut-title", in: setup.window)
        // NSTextField's frame includes text insets; allow those, not a stretched mark column.
        let x = title.convert(.zero, to: setup.window.contentView).x
        try check((40...56).contains(x), "Setup status column stretched: title x \(x)")
    }
    private static func edit(_ field: NSTextField, value: String, window: NSWindow) throws {
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw SettingsCheckFailure(description: "Missing native editor") }
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }
}
