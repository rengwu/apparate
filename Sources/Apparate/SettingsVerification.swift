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
        let registrar = SettingsRegistrar(), login = FixtureLoginService(status: .notFound), probes = Mutex(0)
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
            store.onChange = { value, _ in session.setConfig(value); model.configChanged() }; access.onChange = { settings.refresh(); setup.refresh() }
            model.retryHotkey(); model.onChange?()
            var roots = config.folders.map { FileRoot(path: $0.path, depth: $0.depth) }
            for i in roots.indices { roots[i].status = i == 0 ? .indexed : .waitingForAccess }
            model.index = SettingsIndexState(count: 13412, updated: Date().addingTimeInterval(-120), roots: roots)
            try check(model.accessText.isEmpty, "Unknown access produced status noise")
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
                for tab in SettingsWindow.Tab.allCases {
                    settings.setTab(tab); try settings.capture(to: profile.directory.appendingPathComponent("settings-\(tab.rawValue.lowercased())-\(dark ? "dark" : "light").jpg"), dark: dark)
                    report["row_alignment_" + tab.rawValue.lowercased()] = try rowAlignment(settings.window)
                }
                try setup.capture(to: profile.directory.appendingPathComponent("setup-incomplete-\(dark ? "dark" : "light").jpg"), dark: dark)
                try checkSetupLayout(setup)
            }
            try check(menu.menu.items.map(\.title) == ["Open Apparate", "Settings…", "", "Quit Apparate"], "Menu order/titles")
            try check(menu.menu.items[0].keyEquivalent == " " && menu.menu.items[0].keyEquivalentModifierMask == .command && menu.menu.items[1].keyEquivalent == "," && menu.menu.items[3].keyEquivalent == "q", "Menu equivalents")
            menu.menu.performActionForItem(at: 0); menu.menu.performActionForItem(at: 1); menu.menu.performActionForItem(at: 3)
            try check(routes == ["open", "settings:Folders", "quit"], "Menu routes")
            settings.setTab(.general)
            let location = try control("result-location", in: settings.window) as! NSSegmentedControl
            try check(location.selectedSegment == 0 && location.segmentCount == 3 && location.accessibilityLabel() == "Location in results", "Location segmented control defaults/label")
            session.setCatalog(try TestProfile.fixtureCatalog()); try panel.beginHiddenShowing(); try panel.injectText("term")
            while session.model.pending { try await Task.sleep(for: .milliseconds(1)) }
            let beforeLayoutRevision = session.model.revision, beforeLayoutSelection = session.model.selectedID
            for (index, value) in ResultLocation.allCases.enumerated() {
                location.selectedSegment = index; location.sendAction(location.action, to: location.target)
                try check(model.config.resultLocation == value && session.resultLocation == value && panel.rows.resultLocation == value, "Native location change did not reach open panel")
                try check(session.model.revision == beforeLayoutRevision && session.model.selectedID == beforeLayoutSelection, "Location change restarted search or lost selection")
                let persisted = try ConfigStore.decode(Data(contentsOf: store.file))
                try check(persisted.resultLocation == value, "Location change was not persisted")
                try captureSettings(settings, "location-" + value.rawValue, profile)
            }
            // An external edit arriving before the displayed control's action is not overwritten.
            var externalLayout = model.config; externalLayout.resultLocation = .inline
            try JSONEncoder().encode(externalLayout).write(to: store.file, options: .atomic)
            location.selectedSegment = 1; location.sendAction(location.action, to: location.target)
            try check(model.error != nil && model.config.resultLocation == .inline && location.selectedSegment == 0, "Stale segmented choice overwrote an external edit")
            model.clearError()
            externalLayout.resultLocation = .right
            try JSONEncoder().encode(externalLayout).write(to: store.file, options: .atomic)
            store.reload()
            try check(location.selectedSegment == 1 && panel.rows.resultLocation == .right, "External location edit did not update control and panel")
            panel.hide()
            report["result_location_control_persistence_live_update_conflict"] = true
            let icon = try control("menu-icon", in: settings.window) as! NSSwitch
            toggle(icon); try check(!model.config.showMenuBarIcon && !menu.itemInstalled && menu.nativeItemCount == 0, "Hide status item")
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
            settings.setTab(.general); settings.startRecording(); try captureSettings(settings, "recording", profile); _ = settings.record(event("", code: 53))
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
            let registrations = registrar.count
            settings.startRecording(openWith: true); try captureSettings(settings, "open-with-recording", profile)
            _ = settings.record(event("a", code: 0, flags: .shift))
            try check(model.error != nil && model.config.openWithKey == .openWithDefault, "Printable Shift key saved")
            try captureSettings(settings, "open-with-conflict", profile)
            settings.startRecording(openWith: true); _ = settings.record(event("z", code: 6, flags: .command))
            try check(model.error != nil && model.config.openWithKey == .openWithDefault, "Undo clash saved")
            settings.startRecording(openWith: true); settings.recordCurrentShortcut()
            try check(model.error != nil && model.config.openWithKey == .openWithDefault, "Launcher key clash saved")
            settings.startRecording(openWith: true); _ = settings.record(event("\r", code: 36, flags: .shift))
            try check(model.error == nil && model.config.openWithKey == .openWithDefault && registrar.count == registrations, "Shift Return recorder/global isolation failed")
            let openButton = try control("open-with-shortcut", in: settings.window) as! NSButton
            try check(openButton.title == "⇧↩" && openButton.accessibilityLabel()?.contains("Open With") == true, "Open With keycap/AX label differs")
            try captureSettings(settings, "open-with", profile)
            report["open_with_recorder"] = ["shift_return": true, "typing_and_editing_clashes_rejected": true, "launcher_clash_rejected": true, "extra_global_registrations": registrar.count - registrations]
            settings.setTab(.search)
            let prefix = try control("prefix:settings", in: settings.window) as! NSTextField
            try check(prefix.alignmentRect(forFrame: prefix.frame).width == 40 && prefix.alignment == .center, "Prefix field is not compact and centered")
            report["prefix_field_geometry"] = ["alignment_width": prefix.alignmentRect(forFrame: prefix.frame).width, "painted_width": prefix.bounds.width, "centered": prefix.alignment == .center]
            let url = try control("url", in: settings.window) as! NSTextField
            try edit(url, value: "bad-url", window: settings.window)
            try check(model.error != nil && model.config.searchURL == config.searchURL, "Invalid native URL edit saved")
            try captureSettings(settings, "validation", profile)
            try edit(url, value: SearchPreset.kagi.url, window: settings.window)
            try check(model.preset == .kagi && model.error == nil, "Valid native URL edit did not save")
            settings.window.makeFirstResponder(url)
            guard let editor = url.currentEditor() as? NSTextView else { throw SettingsCheckFailure(description: "Missing native field editor") }
            editor.insertText("unsaved", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            try check(model.config.searchURL == SearchPreset.kagi.url && url.stringValue == SearchPreset.kagi.url, "Native Esc did not restore saved value")
            try edit(try control("prefix:settings", in: settings.window) as! NSTextField, value: "/", window: settings.window)
            try check(model.config.prefixes == config.prefixes && model.error != nil, "Invalid native prefix saved")
            (try control("prefix-remove:settings", in: settings.window) as! NSButton).performClick(nil)
            try check(model.config.prefixes["settings"] == nil, "Native prefix removal")
            settings.beginPrefix(.settings)
            try edit(try control("prefix:settings", in: settings.window) as! NSTextField, value: "!", window: settings.window)
            try check(model.config.prefixes["settings"] == "!", "Native prefix draft not saved")
            let preset = try control("preset", in: settings.window) as! NSPopUpButton
            preset.selectItem(withTitle: "Custom"); preset.sendAction(preset.action!, to: preset.target)
            try check(model.config.searchURL == SearchPreset.kagi.url && url.currentEditor() != nil, "Custom lost URL or focus")
            settings.window.makeFirstResponder(nil)
            settings.setTab(.folders)
            report["indexing_indicator"] = try indexingIndicator(settings, profile)
            let hidden = try control("skip-hidden", in: settings.window) as! NSSwitch
            let ignore = try control("respect", in: settings.window) as! NSSwitch
            try check(hidden.isEnabled && hidden.state == .on && model.config.skipHiddenFiles, "Skip hidden default must be on")
            try check(hidden.accessibilityLabel() == "Skip hidden files" && hidden.superview?.superview === ignore.superview?.superview, "Hidden switch label/card")
            try captureSettings(settings, "hidden-on", profile)
            toggle(hidden)
            try check(!model.config.skipHiddenFiles && hidden.state == .off && (try? ConfigStore.decode(Data(contentsOf: store.file)).skipHiddenFiles) == false, "Hidden off did not persist")
            try captureSettings(settings, "hidden-off", profile)
            toggle(hidden); try check(model.config.skipHiddenFiles && hidden.state == .on, "Hidden on did not persist")
            var hiddenExternal = model.config; hiddenExternal.skipHiddenFiles = false
            try JSONEncoder().encode(hiddenExternal).write(to: store.file, options: .atomic)
            toggle(hidden)
            try check(!model.config.skipHiddenFiles && hidden.state == .off && model.error?.contains("changed") == true, "Stale hidden switch overwrote an external edit")
            hiddenExternal.skipHiddenFiles = true
            try JSONEncoder().encode(hiddenExternal).write(to: store.file, options: .atomic); store.reload()
            try check(model.config.skipHiddenFiles && hidden.state == .on, "External hidden edit did not refresh")
            model.clearError()
            report["skip_hidden_files"] = ["default_on": true, "native_toggle_persists": true, "expected_value_conflict": true, "external_edit_refresh": true, "same_card": true]
            var picked = 0, rebuilds = 0
            settings.onPickFolders = { _, completion in picked += 1; completion(picked == 1 ? [] : ["/Fixture/Projects/./", "/Fixture/Extra"]) }
            let add = try control("folder-add", in: settings.window) as! NSButton
            add.performClick(nil); try check(model.config.folders.count == 4, "Picker cancellation changed config")
            add.performClick(nil); try check(model.config.folders.count == 5 && model.config.folders[0].depth == 10, "Picker duplicates or new folder")
            try edit(try control("depth:/Fixture/Projects", in: settings.window) as! NSTextField, value: "31", window: settings.window)
            try check(model.config.folders[0].depth == 10 && model.error != nil, "Invalid native depth saved")
            try edit(try control("depth:/Fixture/Projects", in: settings.window) as! NSTextField, value: "12", window: settings.window)
            try check(model.config.folders[0].depth == 12 && model.error == nil, "Native depth did not save")
            let stepper = try control("depth-stepper:/Fixture/Projects", in: settings.window) as! NSStepper
            stepper.integerValue = 13; stepper.sendAction(stepper.action!, to: stepper.target)
            try check(model.config.folders[0].depth == 13, "Native stepper did not save")
            let retainedStepper = try control("depth-stepper:/Fixture/Projects", in: settings.window)
            try check(retainedStepper === stepper, "Depth change replaced a tracking stepper")
            // Exercise the cell that owns NSStepper's increment/decrement actions.
            // This SDK returns false despite changing the value; assert persisted effects.
            let incrementReturn = stepper.cell?.accessibilityPerformIncrement() ?? false
            try check(stepper.integerValue == 14 && model.config.folders[0].depth == 14, "Native stepper increment failed")
            let decrementReturn = stepper.cell?.accessibilityPerformDecrement() ?? false
            try check(stepper.integerValue == 13 && model.config.folders[0].depth == 13, "Native stepper decrement failed")
            report["stepper_cell_action_returns"] = ["increment": incrementReturn, "decrement": decrementReturn]
            let depthField = try control("depth:/Fixture/Projects", in: settings.window)
            try check(depthField.superview === stepper.superview && depthField.superview is PreferencesNumber, "Depth does not share a single filled surface")
            report["native_stepper_increment_decrement"] = true
            var reordered = model.config; reordered.folders.reverse(); try store.save(reordered)
            (try control("folder-remove:/Fixture/Projects", in: settings.window) as! NSButton).performClick(nil)
            try check(!model.config.folders.contains { $0.path == "/Fixture/Projects" }, "Remove targeted wrong folder")
            try check((try? control("folder-remove:/Fixture/Projects", in: settings.window)) == nil, "Removed folder retained a control")
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
            for dark in [false, true] { try setup.capture(to: profile.directory.appendingPathComponent("setup-partial-\(dark ? "dark" : "light").jpg"), dark: dark) }
            model.index.roots = model.index.roots.map { root in var root = root; if root.path == "/Fixture/Documents" { root.status = .denied }; return root }
            try captureSettings(settings, "denied", profile)
            try checkSetupLayout(setup)
            setup.finish(); try check(!setup.window.isVisible, "Done failed on incomplete setup")
            setup.checkAccess(); setup.finish()
            for _ in 0..<4 { await Task.yield() }
            try check(probes.withLock { $0 } == 3, "Closing before a scheduled check starts must cancel it")
            settings.setTab(.general)
            let loginButton = try control("login", in: settings.window) as! NSSwitch
            model.clearError(); model.refresh()
            try check(login.status == .notFound && model.loginState == .notRegistered && loginButton.isEnabled && loginButton.state == .off, "Not-found login must allow registration")
            try captureSettings(settings, "login-not-found", profile)
            toggle(loginButton)
            try check(login.changes == [true] && login.status == .enabled && model.loginState == .enabled && loginButton.state == .on && loginButton.isEnabled && model.error == nil, "Not-found login registration failed")
            try captureSettings(settings, "login-enabled", profile)
            toggle(loginButton)
            try check(login.changes == [true, false] && login.status == .notRegistered && model.loginState == .notRegistered && loginButton.state == .off, "Enabled login unregister failed")
            login.status = .notFound; login.failure = true; model.refresh()
            toggle(loginButton)
            try check(login.changes == [true, false, true] && login.status == .notFound && model.loginState == .notRegistered && loginButton.isEnabled && loginButton.state == .off && model.error == "Fixture login change refused.", "Refused not-found registration faked success")
            try check(visibleLabel(model.error!, in: settings.window.contentView!), "Login refusal is not inline")
            try captureSettings(settings, "login-refused", profile)
            login.failure = false; model.clearError()
            login.supported = false; model.refresh()
            try check(model.loginState == .unavailable && !loginButton.isEnabled && loginButton.state == .off && visibleLabel("Launch at login is unavailable for this app.", in: settings.window.contentView!), "Non-bundle login availability changed")
            try captureSettings(settings, "login-unavailable", profile)
            login.supported = true; login.status = .requiresApproval; model.refresh()
            try check(loginButton.state == .on && loginButton.isEnabled, "Approval state hidden")
            try captureSettings(settings, "login-approval", profile)
            toggle(loginButton); try check(login.changes == [true, false, true, false] && model.loginState == .notRegistered, "Approval-pending unregister")
            login.failure = true; model.setLogin(true); try check(model.loginState == .notRegistered && model.error != nil, "Login failure faked success")
            report["login_not_found"] = ["shared_native_status_mapping": true, "initial_off_enabled": true, "successful_registration_on": true, "refusal_off_inline": true, "non_bundle_disabled": true, "approval_can_unregister": true, "fake_changes": login.changes]
            let valid = try Data(contentsOf: store.file), broken = Data("{broken".utf8)
            try broken.write(to: store.file, options: .atomic); store.reload()
            try check(!model.editable && !loginButton.isEnabled && !location.isEnabled && !hidden.isEnabled, "Broken config did not disable controls")
            var reveals = 0; settings.onRevealConfig = { reveals += 1 }
            (try control("reveal", in: settings.window) as! NSButton).performClick(nil)
            try check(reveals == 1 && (try? Data(contentsOf: store.file)) == broken, "Broken-file recovery path")
            try captureSettings(settings, "broken-config", profile)
            try valid.write(to: store.file, options: .atomic); store.reload(); try check(model.editable, "Config repair")
            let completeDirectory = profile.directory.appendingPathComponent("complete-access")
            try FileManager.default.createDirectory(at: completeDirectory, withIntermediateDirectories: true)
            let completeAccess = FolderAccessController(directory: completeDirectory, probe: { _ in .allowed })
            await completeAccess.check()
            let completeModel = SettingsModel(store: store, hotkey: keys, access: completeAccess, login: login, readSpotlight: { .disabled }, home: "/Fixture")
            let completeSetup = SetupWindow(model: completeModel, presentationAllowed: false)
            try check(completeModel.accessReady && completeModel.accessText.isEmpty && completeModel.shortcutReady, "Complete setup retained redundant status")
            for dark in [false, true] { try completeSetup.capture(to: profile.directory.appendingPathComponent("setup-complete-\(dark ? "dark" : "light").jpg"), dark: dark) }
            try completeSetup.verifyHidden()
            var axLabels: [String: String] = [:]
            for tab in SettingsWindow.Tab.allCases {
                settings.setTab(tab)
                func inspect(_ view: NSView) throws {
                    if let control = view as? NSControl, let id = control.identifier?.rawValue {
                        try check(!(control.accessibilityLabel() ?? "").isEmpty, "Missing AX label: " + id)
                        axLabels[id] = control.accessibilityLabel()
                    }
                    for child in view.subviews { try inspect(child) }
                }
                try inspect(settings.window.contentView!)
            }
            report["native_control_labels"] = axLabels; report["spoken_voiceover"] = "Untested (DEC-050)"
            settings.setTab(.folders)
            let savedFolders = model.config.folders
            var many = model.config
            many.folders = (0..<30).map { .init(path: "/Fixture/Many/Folder-\($0)", depth: 10) }
            try store.save(many)
            try check(settings.window.contentView!.bounds.height <= 680, "Many folders exceed bounded window height")
            guard let scroller = settings.window.contentView?.subviews.first as? NSScrollView, let document = scroller.documentView else { throw SettingsCheckFailure(description: "Missing Settings scroll container") }
            try check(document.frame.height > scroller.contentSize.height, "Many folders cannot scroll")
            let last = try control("folder-remove:/Fixture/Many/Folder-29", in: settings.window)
            document.scrollToVisible(last.convert(last.bounds, to: document))
            try check(document.visibleRect.intersects(last.convert(last.bounds, to: document)), "Last folder cannot be reached")
            many.folders = savedFolders; try store.save(many)
            report["many_folders_scroll_checked"] = true
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
    private static func indexingIndicator(_ settings: SettingsWindow, _ profile: TestProfile) throws -> [String: Any] {
        let model = settings.model, store = model.store, saved = model.index, originalChange = store.onChange
        defer { store.onChange = originalChange; model.index = saved }
        func view(_ id: String) throws -> NSView {
            func find(_ candidate: NSView) -> NSView? {
                if candidate.identifier?.rawValue == id { return candidate }
                return candidate.subviews.lazy.compactMap(find).first
            }
            guard let found = find(settings.window.contentView!) else { throw SettingsCheckFailure(description: "Missing view " + id) }
            return found
        }
        let content = settings.window.contentView!, indicator = try view("indexing-indicator"), spinner = try view("indexing-spinner") as! NSProgressIndicator
        let add = try control("folder-add", in: settings.window), allow = try control("allow", in: settings.window)
        let folderCard = try view("folder-card") as! PreferencesCard
        try check(spinner.style == .spinning && spinner.controlSize == .small && spinner.isIndeterminate && spinner.accessibilityLabel() == "Indexing", "Native spinner style/AX")
        func folderRows() -> [PreferencesRow] { folderCard.arrangedSubviews.compactMap { $0 as? PreferencesRow } }
        func frames() throws -> [String: [Double]] {
            content.layoutSubtreeIfNeeded()
            var values: [String: [Double]] = [:]
            func record(_ name: String, _ view: NSView) {
                let rect = view.convert(view.bounds, to: content)
                values[name] = [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)
            }
            for id in ["folder-card", "folder-actions", "folder-add", "allow", "indexing-indicator", "respect", "skip-hidden", "rebuild"] { record(id, try view(id)) }
            record("skip-card", try view("respect").superview!.superview!)
            record("index-card", try view("rebuild").superview!.superview!)
            for row in folderRows() { record("row:" + row.title.stringValue, row) }
            values["content"] = [Double(content.frame.width), Double(content.frame.height)]
            return values
        }
        func set(_ states: [FileRootStatus], indexing: Bool) {
            var next = saved; next.indexing = indexing
            next.roots = model.config.folders.enumerated().map { i, folder in
                var root = FileRoot(path: model.normalized(folder.path), depth: folder.depth); root.status = states[i]; return root
            }
            model.index = next
        }
        func checkProgress(_ indexing: Bool) throws {
            try check(indicator.isHidden == !indexing && spinner.isAccessibilityHidden() == !indexing, "Progress visibility/AX did not follow indexing")
            try check((try? control("rebuild", in: settings.window).isEnabled) == !indexing, "Progress/Rebuild state disagreement")
            try check(folderRows().allSatisfy { $0.detail.stringValue != "Indexing…" }, "Per-row indexing text remains")
            let buttonFrame = add.convert(add.bounds, to: content), progressFrame = indicator.convert(indicator.bounds, to: content)
            let spinnerFrame = spinner.convert(spinner.bounds, to: content)
            try check(abs(progressFrame.minX - buttonFrame.maxX - 8) < 0.01 && abs(spinnerFrame.midY - buttonFrame.midY) < 0.01, "Progress spacing/centering")
            let actions = try view("folder-actions")
            try check(abs(actions.frame.height - add.frame.height) < 0.01, "Action row height is not fixed by Add Folders")
        }
        try check(model.config.folders.count == 4, "Indexing fixture requires four folders")
        set(Array(repeating: .indexed, count: 4), indexing: false)
        try checkProgress(false)
        let idle = try frames(), retainedRows = folderRows()
        try captureSettings(settings, "indexing-idle", profile)
        set(Array(repeating: .indexing, count: 4), indexing: true)
        try checkProgress(true)
        let busy = try frames()
        try check(idle == busy, "All-indexing transition shifted frames")
        try check(zip(retainedRows, folderRows()).allSatisfy { $0 === $1 }, "Progress-only change rebuilt folder controls")
        try captureSettings(settings, "indexing-all", profile)
        set(Array(repeating: .indexed, count: 4), indexing: false)
        let finished = try frames()
        try check(finished == idle, "Indexing finish shifted frames")
        set([.indexed, .denied, .notFound, .unavailable], indexing: false)
        let mixedIdle = try frames()
        try captureSettings(settings, "indexing-mixed-idle", profile)
        set([.indexing, .denied, .notFound, .unavailable], indexing: true)
        try checkProgress(true)
        let mixedBusy = try frames()
        try check(mixedBusy == mixedIdle && folderRows().map(\.detail.stringValue) == ["", "Denied", "Not found", "Unavailable"], "Mixed indexing changed errors/frames")
        try captureSettings(settings, "indexing-mixed", profile)
        set([.indexed, .waitingForAccess, .indexed, .indexed], indexing: false)
        let waitingIdle = try frames()
        set([.indexing, .waitingForAccess, .indexed, .indexed], indexing: true)
        let waitingBusy = try frames()
        try check(waitingBusy == waitingIdle && folderRows()[1].detail.stringValue == "Waiting for access", "Waiting row shifted on indexing")
        var toggles = 0
        store.onChange = { value, errors in
            originalChange?(value, errors)
            toggles += 1; set(Array(repeating: .indexing, count: 4), indexing: true)
        }
        for id in ["respect", "skip-hidden"] {
            let button = try control(id, in: settings.window) as! NSSwitch
            for _ in 0..<2 {
                set(Array(repeating: .indexed, count: 4), indexing: false)
                let before = try frames(); toggle(button)
                try checkProgress(true)
                let after = try frames()
                try check(after == before, "Switch-triggered indexing shifted frames: " + id)
            }
        }
        try check(toggles == 4, "Native skip switches did not invoke the indexing fixture")
        settings.setTab(.general); settings.setTab(.folders); try checkProgress(true)
        try settings.verifyHidden()
        return ["idle_frames": idle, "all_indexing_frames": busy, "mixed_idle_frames": mixedIdle, "mixed_indexing_frames": mixedBusy,
                "waiting_frames_unchanged": true, "native_switch_transitions": toggles, "same_folder_controls": true, "spinner_ax_label": spinner.accessibilityLabel()!,
                "index_card_unchanged": true, "animation": "Static hidden native spinner; visible animation and spoken VoiceOver remain supervised", "allow_visible": !allow.isHidden]
    }
    private static func visibleLabel(_ text: String, in view: NSView) -> Bool {
        guard !view.isHidden else { return false }
        if let field = view as? NSTextField, field.stringValue == text { return true }
        return view.subviews.contains { visibleLabel(text, in: $0) }
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
    private static func rowAlignment(_ window: NSWindow) throws -> [[String: Any]] {
        var samples: [[String: Any]] = []
        func visit(_ view: NSView) throws {
            if let row = view as? PreferencesRow, row.detail.isHidden {
                let title = row.title.convert(row.title.bounds, to: row), control = row.rowControl.convert(row.rowControl.bounds, to: row)
                let delta = abs(title.midY - control.midY)
                try check(delta <= 0.5, "Single-line title is off-center: \(row.title.stringValue), \(delta) pt")
                samples.append(["title": row.title.stringValue, "title_height": title.height, "center_delta_pt": delta])
            }
            for child in view.subviews { try visit(child) }
        }
        if let content = window.contentView { try visit(content) }
        return samples
    }
    private static func toggle(_ control: NSSwitch) {
        control.state = control.state == .on ? .off : .on
        control.sendAction(control.action!, to: control.target)
    }
    private static func captureSettings(_ settings: SettingsWindow, _ name: String, _ profile: TestProfile) throws {
        for dark in [false, true] { try settings.capture(to: profile.directory.appendingPathComponent("settings-\(name)-\(dark ? "dark" : "light").jpg"), dark: dark) }
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
