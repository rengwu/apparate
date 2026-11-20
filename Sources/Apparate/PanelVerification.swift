import AppKit
import CoreText
import ApparateCore
import ApparateFixtures
import CryptoKit
import Synchronization

private struct PanelCheckFailure: Error { let message: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PanelCheckFailure(message: message) }
}
@MainActor private final class IconRasterGate {
    var requests: [Int] = []
    private var pending: [Int: CheckedContinuation<Data?, Never>] = [:]
    func read(_ pixels: Int) async -> Data? {
        requests.append(pixels)
        return await withCheckedContinuation { pending[pixels] = $0 }
    }
    func finish(_ pixels: Int, data: Data?) { pending.removeValue(forKey: pixels)?.resume(returning: data) }
    func cancel() { for continuation in pending.values { continuation.resume(returning: nil) }; pending.removeAll() }
}
private final class PanelSearchTrace: Sendable {
    let values = Mutex<[UInt64: SearchTrace]>([:])
    let signal = DispatchSemaphore(value: 0)
    let processCPUAtFinish = Mutex<[UInt64: UInt64]>([:])
    func record(_ trace: SearchTrace) {
        processCPUAtFinish.withLock { $0[trace.generation] = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) }
        values.withLock { $0[trace.generation] = trace }; signal.signal()
    }
    func wait(for generation: UInt64, milliseconds: Int) -> Bool {
        let deadline = DispatchTime.now() + .milliseconds(milliseconds)
        while values.withLock({ $0[generation] == nil }) {
            if signal.wait(timeout: deadline) == .timedOut { return false }
        }
        return true
    }
}

/// Runs only behind the explicit isolated test profile. No visible windows or global events.
@MainActor enum PanelVerification {
    static func run(_ profile: TestProfile) async {
        var report: [String: Any] = ["schema": 1, "driver_task_priority": Task.currentPriority.rawValue, "thermal_state": ProcessInfo.processInfo.thermalState.rawValue, "mode": "fixtures", "panel_check": profile.panelCheck!,
            "renderer": "drawn", "activity_enabled": profile.activityEnabled, "delivery": profile.delivery.rawValue, "opaque": profile.opaque, "warm_up": profile.warmUp,
            "wait_ms": profile.waitMS, "native_actions": 0, "native_hotkey_registrations": 0, "protected_folder_probes": 0,
            "visible_profile": "none", "capture_method": "app-owned hidden bitmap; no WindowServer composition",
            "timing_scope": "injected field-editor text through production coordinator/session/layout and explicit off-screen raster; not a screen commit or presentation timestamp"]
        let effects = TestEffects()
        defer { NSApp.terminate(nil) }
        do {
            let config = try ConfigStore.decode(Data(contentsOf: profile.directory.appendingPathComponent("config.json")))
            let registration = HotKeyRegistration(registrar: effects); try registration.replace(with: config.hotKey)
            defer { registration.stop() }
            report["fake_registrations"] = effects.registrationCount
            if profile.panelCheck == "functional" { try await functional(profile, report: &report) }
            else { try await measure(profile, report: &report) }
            report["ready"] = true; report["errors"] = 0; report["result"] = "Passed"
        } catch {
            report["ready"] = false; report["errors"] = 1; report["result"] = "Failed"
            report["failure"] = (error as? PanelCheckFailure)?.message ?? String(describing: error)
        }
        report["fake_actions"] = 0
        do { report["physical_footprint_bytes"] = try ProcessMetrics.footprint() } catch { report["errors"] = 1; report["result"] = "Failed"; report["physical_footprint_bytes"] = NSNull() }
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: profile.directory.appendingPathComponent("diagnostics.json"), options: .atomic) }
        catch { NSLog("Panel check receipt could not be written.") }
    }
    private static func settle(_ session: LauncherSession, timeoutMS: Double = 2000) async throws {
        let start = ContinuousClock.now
        while session.model.pending && durationMS(start.duration(to: .now)) < timeoutMS { try await Task.sleep(for: .milliseconds(1)) }
        try require(!session.model.pending, "Timed out waiting for a complete query result")
    }
    private static func key(_ value: String, code: UInt16, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                        context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: repeatKey, keyCode: code)!
    }
    private static func searchGeometry(_ panel: PanelController, state: String) throws -> [String: Any] {
        let editor = try panel.hiddenEditor()
        guard let manager = editor.layoutManager, let container = editor.textContainer, let font = editor.font else {
            throw PanelCheckFailure(message: "Search editor layout is unavailable")
        }
        manager.ensureLayout(for: container)
        let baseline: CGFloat
        if manager.numberOfGlyphs > 0 {
            baseline = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + manager.location(forGlyphAt: 0).y
        } else {
            baseline = manager.extraLineFragmentRect.minY + manager.defaultBaselineOffset(for: font)
        }
        let center = editor.convert(NSPoint(x: 0, y: editor.textContainerOrigin.y + baseline - font.capHeight / 2), to: panel.contentView)
        let fromTop = panel.contentView.bounds.height - center.y
        try require(abs(fromTop - 20) <= 0.5, "Search cap height is not centered in the 40 pt row (\(state))")
        return ["state": state, "height": panel.panelFrame.height, "font_cap_height": font.capHeight,
                "cap_center_from_top": fromTop, "cap_center_error": fromTop - 20,
                "marked": editor.hasMarkedText()]
    }
    private static func labelGeometry(_ panel: PanelController) throws -> [[String: Any]] {
        try panel.contentView.subviews.compactMap { view in
            guard let label = view as? NSTextField, !label.isEditable, !label.isHidden, let font = label.font else { return nil }
            let baseline = label.frame.maxY - label.firstBaselineOffsetFromTop
            let target: CGFloat = label.stringValue == panel.footerText ? 14 : (panel.panelFrame.height - 41) / 2
            try require(abs(baseline + font.capHeight / 2 - target) <= 0.5, "Panel label cap height is not centered (\(label.stringValue))")
            return ["text": label.stringValue, "cap_center_from_bottom": baseline + font.capHeight / 2,
                    "cap_center_from_top": panel.contentView.bounds.height - baseline - font.capHeight / 2,
                    "font_cap_height": font.capHeight, "height": panel.panelFrame.height, "target_from_bottom": target]
        }
    }
    private static func functional(_ profile: TestProfile, report: inout [String: Any]) async throws {
        let session = LauncherSession(config: AppConfig(), usage: { UsageSnapshot() })
        let panel = PanelController(session: session, icons: IconLoader(fixtureOnly: true), presentationAllowed: false,
                                    opaque: profile.opaque, warmUp: profile.warmUp, activityEnabled: profile.activityEnabled, initialAppearance: .darkAqua)
        defer { panel.hide() }
        var actions: [String] = [], quits = 0
        session.onAction = { actions.append($0.entry.item.id) }; panel.onQuit = { quits += 1 }
        try require(!panel.activityHeld && panel.activityBegins == 0, "Warm-up acquired an activity")
        try panel.beginHiddenShowing()
        try panel.beginHiddenShowing()
        try require(panel.activityHeld == profile.activityEnabled && panel.activityBegins == (profile.activityEnabled ? 1 : 0), "Repeated showing leaked an activity")
        try require(panel.footerText.isEmpty && panel.rows.contents.isEmpty, "Empty launch state must be blank")
        try panel.injectText("waiting")
        try require(panel.emptyText == "Searching…" && panel.footerText.isEmpty, "Initial loading state missing")
        report["loading_label_geometry"] = try labelGeometry(panel)
        for dark in [false, true] { panel.setAppearance(dark: dark); try panel.capture(to: profile.directory.appendingPathComponent("loading-\(dark ? "dark" : "light").jpg")) }
        try panel.injectText("?web before catalog"); try await settle(session)
        try require(!session.isCatalogReady && panel.emptyText == nil && panel.footerText == "↩ Open", "Completed explicit web result still appears to await the catalog")
        report["explicit_web_before_catalog"] = true
        try panel.injectText("waiting")
        session.setCatalog(try TestProfile.fixtureCatalog()); try await settle(session)
        let cases: [(String, String)] = [("empty", ""), ("matches", "term"), ("alternate", "code"), ("no-results", ".zzzz"), ("web", "zzzz"), ("restart", "restart")]
        var renders: [String] = []
        for dark in [false, true] {
            panel.setAppearance(dark: dark)
            for (name, query) in cases {
                try panel.injectText(query); try await settle(session)
                if name == "restart" { session.act(.open) }
                let filename = name + (dark ? "-dark.jpg" : "-light.jpg")
                try panel.capture(to: profile.directory.appendingPathComponent(filename)); renders.append(filename)
                try require(panel.rows.geometryIsValid(), "Native row frame differs from the shared contract")
                if name == "empty" { try require(panel.footerText.isEmpty && panel.rows.contents.isEmpty, "Empty query did not clear") }
                if name == "no-results" {
                    try require(panel.emptyText == "No results", "Scoped empty state missing")
                    report["empty_label_geometry"] = try labelGeometry(panel)
                }
                if name == "restart" {
                    try require(panel.rows.contents.first?.location == "Press Return again" && panel.footerText == "↩ Confirm Restart   esc Cancel", "Restart state is not in location/footer")
                    try require(panel.escape() && panel.text == "restart" && !session.model.restartArmed, "First Esc must disarm only")
                }
            }
        }
        let fixtureRows = (0..<50).map { i -> CatalogEntry in
            let name = String(format: "Result %02d", i)
            return CatalogEntry(item: SearchItem(id: "fixture:\(i)", kind: .file, name: name, path: "/Fixture/Projects/Group/" + name),
                                target: .file(URL(fileURLWithPath: "/Fixture/Projects/Group/" + name)), icon: .symbol("doc"))
        }
        session.setCatalog(try CatalogSnapshot(entries: fixtureRows + CatalogEntry.commands))
        try panel.injectText("result"); try await settle(session)
        let fixedTop = panel.panelFrame.maxY
        var sizes: [[String: Any]] = [], searchCenters: [[String: Any]] = []
        for count in [0, 1, 3, 9] {
            session.setCatalog(try CatalogSnapshot(entries: Array(fixtureRows.prefix(count))))
            try panel.injectText(count == 0 ? "" : "result"); try await settle(session)
            try require(panel.panelFrame.height == PanelLayout.height(rows: count) && panel.panelFrame.maxY == fixedTop, "Panel resize moved its top edge or has wrong height")
            for dark in [false, true] {
                panel.setAppearance(dark: dark)
                try panel.capture(to: profile.directory.appendingPathComponent("size-\(count)-\(dark ? "dark" : "light").jpg"))
                try panel.capture(to: profile.directory.appendingPathComponent("search-\(count)-\(dark ? "dark" : "light").png"))
            }
            searchCenters.append(try searchGeometry(panel, state: count == 0 ? "placeholder" : "typed-\(count)-rows"))
            if count == 0 {
                let editor = try panel.hiddenEditor()
                editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
                try require(editor.hasMarkedText() && panel.panelFrame.height == 41, "Marked strip fixture changed geometry")
                for dark in [false, true] {
                    panel.setAppearance(dark: dark)
                    try panel.capture(to: profile.directory.appendingPathComponent("search-marked-strip-\(dark ? "dark" : "light").png"))
                }
                searchCenters.append(try searchGeometry(panel, state: "marked-strip"))
                editor.unmarkText(); try panel.injectText("")
            }
            // Decode the actual owned raster, including the strip and smallest result.
            panel.observationRun = 42
            try panel.injectText(""); try panel.injectText(count == 0 ? "" : "result"); try await settle(session)
            let image = try panel.render(), scale = Double(image.pixelsWide) / 640
            let marker = MarkerPixels.decode(width: image.pixelsWide, height: image.pixelsHigh, originX: 588 * scale, originY: 16 * scale, scale: scale) { x,y in
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (128,128,128) }
                return (UInt8((color.redComponent * 255).rounded()), UInt8((color.greenComponent * 255).rounded()), UInt8((color.blueComponent * 255).rounded()))
            }
            try require(marker == panel.rows.observationMarker && marker != nil, "Compact raster marker did not decode")
            panel.observationRun = nil
            sizes.append(["rows": count, "height": panel.panelFrame.height, "top": fixedTop, "marker_decoded": true])
            if count > 0 { try panel.verifyPendingPresentation(); try await settle(session) }
        }
        report["dynamic_geometry"] = sizes
        report["footer_label_geometry"] = try labelGeometry(panel)
        session.setCatalog(try CatalogSnapshot(entries: fixtureRows + CatalogEntry.commands))
        try panel.injectText("result"); try await settle(session)
        let frameChanges = panel.layoutFrameChanges
        for query in ["resul", "res", "result"] { try panel.injectText(query); try await settle(session) }
        try require(panel.layoutFrameChanges == frameChanges, "Same-height result update touched window geometry")
        report["same_height_window_frame_calls"] = panel.layoutFrameChanges - frameChanges
        let editor = try panel.hiddenEditor()
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try require(session.model.selectedID == session.model.rows[1].entry.item.id, "Native Down did not move selection")
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        try require(session.model.selectedID == session.model.rows[0].entry.item.id, "Native Up did not move selection")
        let firstID = session.model.rows[0].entry.item.id, firstElement = panel.rows.accessibilityElements[firstID]!
        try require(panel.rows.accessibilityRows()?.count == 50 && panel.rows.accessibilityVisibleRows()?.count == 9, "AX must expose 50 rows and 9 visible")
        session.move(49); _ = try panel.render()
        try require(panel.rows.geometryIsValid(), "Native scrolled viewport differs from the shared contract")
        try require(session.model.firstVisibleRow == 41 && panel.rows.contents[49].number == 9, "Viewport did not reach row 50")
        try require(panel.keyEquivalent(key("9", code: 25, flags: .command)), "Number shortcut was not handled")
        try require(actions.last == session.model.rows[49].entry.item.id, "⌘9 opened the wrong viewport row")
        let lastElement = panel.rows.accessibilityElements[session.model.rows[49].entry.item.id]!
        try require(lastElement.isAccessibilitySelected() && lastElement.accessibilityLabel()?.contains("50 of 50") == true, "AX selection/position missing")
        firstElement.setAccessibilitySelected(true)
        try require(session.model.firstVisibleRow == 0 && session.model.selectedID == firstID, "AX selection must reveal an offscreen row")
        try require(panel.rows.accessibilityElements[firstID] === firstElement, "AX identity changed across selection")
        try require(firstElement.accessibilityPerformPress() && actions.last == firstID, "AX press did not activate")
        session.scroll(5); panel.rows.activate(point: NSPoint(x: 20, y: panel.rows.rowTop + 3 * 28 + 4))
        try require(actions.last == session.model.rows[8].entry.item.id, "Click after scrolling used the wrong row")
        let priorCount = actions.count
        try panel.injectText("restart"); try await settle(session)
        _ = panel.keyEquivalent(key("1", code: 18, flags: .command)); _ = panel.keyEquivalent(key("1", code: 18, flags: .command))
        try require(session.model.restartArmed && actions.count == priorCount, "Number shortcuts confirmed Restart")
        session.act(.open, isRepeat: true); try require(actions.count == priorCount, "Repeat confirmed Restart")
        session.act(.open); try require(actions.last == "command:restart", "Fresh Return did not confirm Restart")
        try require(panel.escape() && panel.text.isEmpty && panel.rows.contents.isEmpty, "Esc did not immediately clear")
        try require(panel.escape() && !session.model.visible, "Esc on empty did not close")
        try require(!panel.activityHeld && panel.activityBegins == panel.activityEnds, "Esc leaked activity")
        try panel.beginHiddenShowing(); try panel.injectText("result"); try await settle(session)
        let markedEditor = try panel.hiddenEditor(), beforeMarkedActions = actions.count
        markedEditor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: markedEditor.string.utf16.count))
        try require(markedEditor.hasMarkedText(), "Native editor has no marked text")
        for dark in [false, true] {
            panel.setAppearance(dark: dark)
            try panel.capture(to: profile.directory.appendingPathComponent("search-marked-\(dark ? "dark" : "light").png"))
        }
        searchCenters.append(try searchGeometry(panel, state: "marked"))
        report["search_centers"] = searchCenters
        for command in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            try require(!panel.control(NSTextField(), textView: markedEditor, doCommandBy: command), "Marked command escaped the input method")
        }
        try require(actions.count == beforeMarkedActions && !session.model.restartArmed, "Marked text caused an action")
        try require(panel.keyEquivalent(key("q", code: 12, flags: .command)) && quits == 1, "⌘Q must work during native composition")
        markedEditor.unmarkText(); try panel.injectText("")
        report["native_editor_arrows_and_marked_command_guard"] = true
        let long = [
            CatalogEntry(item: SearchItem(id: "layout:1", kind: .file, name: "A👩🏽‍💻e\u{301}東京.md", path: "/Fixture/Projects/" + String(repeating: "long-directory/", count: 12) + "A.md"), target: .file(URL(fileURLWithPath: "/Fixture/Projects/" + String(repeating: "long-directory/", count: 12) + "A.md")), icon: .symbol("doc")),
            CatalogEntry(item: SearchItem(id: "layout:2", kind: .file, name: String(repeating: "Long title ", count: 16), path: "/Fixture/long"), target: .file(URL(fileURLWithPath: "/Fixture/long")), icon: .symbol("doc")),
            CatalogEntry(item: SearchItem(id: "layout:3", kind: .file, name: String(repeating: "Long title ", count: 16), path: "/Fixture/" + String(repeating: "long-directory/", count: 12) + "long"), target: .file(URL(fileURLWithPath: "/Fixture/" + String(repeating: "long-directory/", count: 12) + "long")), icon: .symbol("doc"))]
        var layoutRows: [[String: Any]] = []
        for entry in long {
            let index = try CatalogSnapshot(entries: [entry]); session.setCatalog(index)
            try panel.injectText(entry.item.id == "layout:1" ? "ae東" : "long"); try await settle(session)
            let drawing = panel.rows.drawing(at: 0)
            try require(drawing.iconFrame == NSRect(x: 9, y: 4, width: 20, height: 20), "Icon geometry differs")
            try require(drawing.titleFrame.maxX <= drawing.hintFrame.minX - 9, "Title overlaps hint")
            if entry.item.id == "layout:1" { try require(drawing.locationTruncated && !drawing.titleTruncated, "Long location should yield before title") }
            else { try require(drawing.locationFrame.isEmpty && drawing.titleTruncated, "Long title must eliminate location before truncation") }
            layoutRows.append(["fixture": entry.item.id, "title_truncated": drawing.titleTruncated, "location_truncated": drawing.locationTruncated,
                               "highlight_utf16_ranges": drawing.highlightedRanges.map { [$0.location, $0.length] }])
            for dark in [false, true] { panel.setAppearance(dark: dark); try panel.capture(to: profile.directory.appendingPathComponent("\(entry.item.id.replacingOccurrences(of: ":", with: "-"))-\(dark ? "dark" : "light").jpg")) }
        }
        try panel.verifyPendingPresentation(); try await settle(session); try panel.verifyHidden()
        session.hide()
        try require(!panel.activityHeld && panel.activityBegins == panel.activityEnds, "Session close leaked activity")
        try panel.beginHiddenShowing(); panel.hide(); panel.hide()
        try require(!panel.activityHeld && panel.activityBegins == panel.activityEnds, "Repeated hide leaked activity")
        report["activity_begins"] = panel.activityBegins; report["activity_ends"] = panel.activityEnds
        report["activity_lifecycle_checked"] = true
        report["layout"] = layoutRows; report["renders"] = renders
        report["ax_rows"] = 50; report["ax_visible_rows"] = 9; report["ax_stable_identity"] = true
        report["fake_quit_callbacks"] = quits; report["fake_model_actions"] = actions.count
        report["selection_notification_sink_count"] = panel.accessibilityNotifications
        report["native_accessibility_notifications"] = 0; report["focus_guards_checked"] = true
        report["location_layouts"] = try await locationLayouts(profile)
        report["path_navigation"] = try await pathNavigation(profile)
        report["indexed_dot_names"] = try await indexedDotNames(profile)
        report["tight_path_ranking"] = try await tightPathRanking(profile)
        report["result_completion"] = try await resultCompletion(profile)
        report["right_folder_completion"] = try await rightFolderCompletion(profile)
        report["larger_below_icons"] = try await largerBelowIcons(profile)
        report["open_with"] = try await openWithMode(profile)
    }
    private static func openWithMode(_ profile: TestProfile) async throws -> [String: Any] {
        func app(_ name: String) -> CatalogEntry {
            let path = "/Fixture/" + name + ".app"
            return CatalogEntry(item: SearchItem(id: "app:" + path, kind: .app, name: name), target: .application(URL(fileURLWithPath: path)), icon: .symbol("app"))
        }
        let file = CatalogEntry(item: SearchItem(id: "file:notes", kind: .file, name: "notes.md", path: "/Fixture/notes.md"), target: .file(URL(fileURLWithPath: "/Fixture/notes.md")), icon: .symbol("doc"))
        let folder = CatalogEntry(item: SearchItem(id: "folder:notes", kind: .folder, name: "Notes Folder", path: "/Fixture/Notes"), target: .file(URL(fileURLWithPath: "/Fixture/Notes")), icon: .symbol("folder"))
        let last = app("Zeta Editor"), current = app("Default Editor"), claimed = app("Alpha Editor"), other = app("Other Editor 東京")
        let session = LauncherSession(config: AppConfig(), openWith: OpenWithService { entry,_ in
            OpenWithDiscovery(contentType: entry.item.kind == .folder ? "public.folder" : "public.text", claimed: [claimed, current], defaultApplication: current, lastApplication: last)
        }, usage: { UsageSnapshot() })
        session.setCatalog(try CatalogSnapshot(entries: [file, folder, other]))
        let panel = PanelController(session: session, icons: IconLoader(fixtureOnly: true), presentationAllowed: false)
        defer { panel.hide() }; try panel.beginHiddenShowing(); try panel.injectText("notes.md"); try await settle(session)
        let editor = try panel.hiddenEditor(), selected = session.model.selectedID, first = session.model.firstVisibleRow
        var actions: [ActionRequest] = []
        session.onAction = { request in actions.append(request); panel.hide() }
        try require(panel.footerText.contains("⇧↩ Open With…"), "File footer has no Open With key")
        var renders: [String] = []
        func capture(_ state: String) throws {
            for dark in [false, true] {
                panel.setAppearance(dark: dark)
                let name = "open-with-\(state)-\(dark ? "dark" : "light").jpg"
                try panel.capture(to: profile.directory.appendingPathComponent(name)); renders.append(name)
            }
        }
        try capture("file")
        try panel.sendHiddenKey(key("\r", code: 36, flags: .shift)); try await settle(session)
        try require(session.isOpenWith && panel.text.isEmpty && editor.string.isEmpty && panel.placeholderText == "Open notes.md with…", "Open With did not replace the field/placeholder")
        try require(panel.rows.contents.map(\.title) == ["Zeta Editor", "Default Editor", "Alpha Editor"] && panel.rows.contents.map(\.location) == ["Last used", "Default", ""], "Open With ordering/labels differ")
        try require(panel.footerText == "↩ Open with Zeta Editor   esc Back", "Open With footer differs")
        try capture("list")
        try panel.injectText("editor"); try await settle(session)
        try require(panel.rows.contents.last?.title == "Other Editor 東京", "Unclaimed catalog tail missing")
        try capture("filtered")
        try panel.injectText("東京"); try await settle(session); try capture("unicode")
        let before = editor.string
        editor.doCommand(by: #selector(NSResponder.insertTab(_:))); editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        _ = panel.keyEquivalent(key("\r", code: 36, flags: .command)); _ = panel.keyEquivalent(key("c", code: 8, flags: .command))
        try require(editor.string == before && actions.isEmpty && session.isOpenWith, "Mode no-op keys activated/changed text")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try require(!session.isOpenWith && panel.text == "notes.md" && editor.string == "notes.md" && session.model.selectedID == selected && session.model.firstVisibleRow == first && panel.placeholderText == "Search", "Native Esc did not restore exact state")
        // Custom local key goes through the same NSPanel sendEvent route; no global input.
        var config = AppConfig(); config.openWithKey.keyCode = 40; config.openWithKey.modifiers = 2304; config.openWithKey.display = "⌥⌘K"
        session.setConfig(config); try await settle(session)
        try require(panel.footerText.contains("⌥⌘K Open With…"), "Changed shortcut missing from footer")
        try panel.sendHiddenKey(key("k", code: 40, flags: [.command, .option])); try await settle(session)
        try panel.injectText("other"); try await settle(session)
        _ = panel.keyEquivalent(key("1", code: 18, flags: .command))
        try require(actions.count == 1 && actions[0].entry == file && actions[0].openWith?.application == other.target.fileURL && !session.model.visible, "Numbered Open With did not route original file/chosen app and hide")
        try panel.beginHiddenShowing(); try panel.injectText("folder"); try await settle(session)
        try panel.sendHiddenKey(key("k", code: 40, flags: [.command, .option])); try await settle(session); try capture("folder")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try require(actions.count == 2 && actions[1].entry == folder && actions[1].openWith?.contentType == "public.folder", "Folder Return failed")
        try panel.beginHiddenShowing(); try panel.injectText("notes.md"); try await settle(session)
        try panel.sendHiddenKey(key("k", code: 40, flags: [.command, .option])); try await settle(session)
        panel.rows.activate(point: NSPoint(x: 20, y: PanelLayout.rowTop + 14))
        try require(actions.count == 3 && actions[2].entry == file && !session.model.visible, "Open With row click failed")
        try panel.beginHiddenShowing(); try panel.injectText("notes.md"); try await settle(session)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try panel.sendHiddenKey(key("k", code: 40, flags: [.command, .option]))
        try require(editor.hasMarkedText() && !session.isOpenWith && actions.count == 3, "Open With shortcut escaped composition")
        editor.unmarkText(); try panel.verifyHidden()
        let emptySession = LauncherSession(config: AppConfig(), openWith: OpenWithService { _,_ in OpenWithDiscovery(contentType: nil, claimed: []) }, usage: { UsageSnapshot() })
        emptySession.setCatalog(try CatalogSnapshot(entries: [file]))
        let emptyPanel = PanelController(session: emptySession, icons: IconLoader(fixtureOnly: true), presentationAllowed: false)
        defer { emptyPanel.hide() }; try emptyPanel.beginHiddenShowing(); try emptyPanel.injectText("notes.md"); try await settle(emptySession)
        try emptyPanel.sendHiddenKey(key("\r", code: 36, flags: .shift)); try await settle(emptySession)
        try require(emptyPanel.emptyText == "No applications" && emptyPanel.panelFrame.height == 82 && emptySession.model.selected == nil, "Empty app list presentation differs")
        for dark in [false, true] {
            emptyPanel.setAppearance(dark: dark)
            let name = "open-with-empty-\(dark ? "dark" : "light").jpg"
            try emptyPanel.capture(to: profile.directory.appendingPathComponent(name)); renders.append(name)
        }
        _ = emptyPanel.escape(); try require(emptyPanel.text == "notes.md" && !emptySession.isOpenWith, "Empty app list cannot go Back")
        try emptyPanel.verifyHidden()
        return ["renders": renders, "native_local_key_route": true, "exact_back": true, "no_op_keys": ["Tab", "Shift-Tab", "Command-Return", "Command-C"],
                "fake_opens": actions.count, "real_workspace_discovery": 0, "real_opens": 0, "folder_type": "public.folder", "custom_shortcut": "⌥⌘K", "marked_trigger_consumed": true]
    }
    private static func rightFolderCompletion(_ profile: TestProfile) async throws -> [String: Any] {
        let home = "/Fixture/Home", folder = home + "/Projects/quinecms-demo-site", unicode = "Folder 👩🏽‍💻e\u{301}東京"
        let directories = [home: ["Projects", unicode, "notes.md"], home + "/Projects": ["quinecms", "quinecms-demo-site"],
            home + "/Projects/quinecms": [], folder: ["README.md"], home + "/" + unicode: ["README.md"]]
        let reader = PathReading(files: FileReading(metadata: { FileMetadata(type: directories[$0] == nil ? .file : .directory) }, children: { directories[$0] ?? [] }), canonical: { $0 })
        func entry(_ name: String, path: String, kind: ItemKind) -> CatalogEntry {
            CatalogEntry(item: SearchItem(id: path, kind: kind, name: name, path: path), target: .file(URL(fileURLWithPath: path)), icon: .file(path))
        }
        let app = CatalogEntry(item: SearchItem(id: "app", kind: .app, name: "Fixture Editor"), target: .application(URL(fileURLWithPath: "/Fixture/Editor.app")), icon: .symbol("app"))
        let entries = [entry("quinecms", path: home + "/Projects/quinecms", kind: .folder), entry("quinecms-demo-site", path: folder, kind: .folder),
            entry(unicode, path: home + "/" + unicode, kind: .folder), entry("notes.md", path: home + "/notes.md", kind: .file), app,
            CatalogEntry(item: SearchItem(id: "setting", kind: .setting, name: "Displays"), target: .settings(bundle: "fixture", anchor: nil), icon: .symbol("display"))] + CatalogEntry.commands
        let session = LauncherSession(config: AppConfig(), pathReader: reader, pathHome: home, openWith: OpenWithService { _,_ in OpenWithDiscovery(contentType: "public.folder", claimed: [app]) }, usage: { UsageSnapshot() })
        session.setCatalog(try CatalogSnapshot(entries: entries))
        let panel = PanelController(session: session, icons: IconLoader(fixtureOnly: true), presentationAllowed: false)
        var actions = 0; session.onAction = { _ in actions += 1 }
        defer { panel.hide() }; try panel.beginHiddenShowing(); try panel.injectText("")
        let editor = try panel.hiddenEditor()
        guard let undo = editor.undoManager else { throw PanelCheckFailure(message: "Right editor has no undo manager") }
        let right = #selector(NSResponder.moveRight(_:))
        func ready(_ text: String) async throws {
            try panel.injectText(text); try await settle(session)
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        }
        func history(_ expected: String) async throws {
            let deadline = ObservationClock.after(ObservationClock.now, milliseconds: 2000)
            while session.model.query != expected && ObservationClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            try require(editor.string == expected && session.model.query == expected, "Right completion/history query mismatch: \(editor.string)")
            try await settle(session)
        }
        var cases: [[String: Any]] = [], renders: [String] = []
        for (name, query, chosen, expected) in [("ordinary", "quinecm", folder, "~/Projects/quinecms-demo-site/"),
            ("scoped", "'quinecm", folder, "~/Projects/quinecms-demo-site/"),
            ("path", "~/Projects/quinecms-d", folder, "~/Projects/quinecms-demo-site/"),
            ("unicode", unicode, home + "/" + unicode, "~/" + unicode + "/")] {
            try await ready(query)
            if name != "path" { session.select(id: chosen) }
            try require(session.completion == expected, "Right fixture selected wrong folder")
            let footer = panel.footerText
            if name == "ordinary" || name == "unicode" {
                for dark in [false, true] {
                    panel.setAppearance(dark: dark)
                    let file = "right-\(name)-before-\(dark ? "dark" : "light").jpg"
                    try panel.capture(to: profile.directory.appendingPathComponent(file)); renders.append(file)
                }
            }
            undo.removeAllActions(); editor.breakUndoCoalescing()
            if name == "ordinary" { try panel.sendHiddenKey(key("\u{f703}", code: 124, flags: [.function, .numericPad])) }
            else { editor.doCommand(by: right) }
            try await history(expected)
            let currentEditor = try panel.hiddenEditor()
            try require(currentEditor === editor && editor.selectedRange() == NSRange(location: expected.utf16.count, length: 0), "Right changed editor or selected completion")
            try require(session.model.rows.first?.entry.item.name == "README.md" && panel.footerText == footer, "Right did not list contents or changed footer")
            if name == "ordinary" || name == "unicode" {
                for dark in [false, true] {
                    panel.setAppearance(dark: dark)
                    let file = "right-\(name)-after-\(dark ? "dark" : "light").jpg"
                    try panel.capture(to: profile.directory.appendingPathComponent(file)); renders.append(file)
                }
            }
            try require(undo.canUndo, "Right has no native undo")
            editor.doCommand(by: NSSelectorFromString("undo:")); try await history(query)
            try require(undo.canRedo, "Right has no native redo")
            editor.doCommand(by: NSSelectorFromString("redo:")); try await history(expected)
            cases.append(["case": name, "query": query, "completion": expected, "query_utf16": query.utf16.count, "native_undo_redo": true])
        }
        var caretChecks: [[String: Any]] = []
        func movement(_ name: String, from start: NSRange, to expected: NSRange, command: Selector? = nil, event: NSEvent? = nil) throws {
            editor.setSelectedRange(start); undo.removeAllActions()
            let text = editor.string, revision = session.model.revision
            if let event { try panel.sendHiddenKey(event) } else { editor.doCommand(by: command ?? right) }
            let actual = editor.selectedRange()
            try require(editor.string == text && session.model.revision == revision && actual == expected && !undo.canUndo,
                        "Right fallthrough \(name) differs: \(actual), expected \(expected), text \(editor.string)")
            caretChecks.append(["case": name, "before": [start.location, start.length], "after": [actual.location, actual.length]])
        }
        try await ready("quinecm"); session.select(id: folder)
        try movement("folder-middle", from: NSRange(location: 2, length: 0), to: NSRange(location: 3, length: 0))
        try movement("folder-selection", from: NSRange(location: 1, length: 3), to: NSRange(location: 4, length: 0))
        try movement("shift-right", from: NSRange(location: 2, length: 0), to: NSRange(location: 2, length: 1), event: key("\u{f703}", code: 124, flags: [.shift, .function, .numericPad]))
        try movement("option-right", from: NSRange(location: 2, length: 0), to: NSRange(location: 7, length: 0), event: key("\u{f703}", code: 124, flags: [.option, .function, .numericPad]))
        try movement("command-right", from: NSRange(location: 2, length: 0), to: NSRange(location: 7, length: 0), event: key("\u{f703}", code: 124, flags: [.command, .function, .numericPad]))
        try movement("modified-selection-command", from: NSRange(location: 2, length: 0), to: NSRange(location: 2, length: 1), command: #selector(NSResponder.moveRightAndModifySelection(_:)))
        for (name, query) in [("file", "notes"), ("app", "fixture"), ("setting", ".disp"), ("command", "lock"), ("web", "?fixture")] {
            try await ready(query)
            try movement(name + "-end", from: NSRange(location: query.utf16.count, length: 0), to: NSRange(location: query.utf16.count, length: 0))
            try movement(name + "-middle", from: NSRange(location: 1, length: 0), to: NSRange(location: 2, length: 0))
        }
        try await ready(""); try movement("no-selection", from: NSRange(location: 0, length: 0), to: NSRange(location: 0, length: 0))
        try await ready("quinecm"); session.select(id: folder)
        try panel.injectText("quinecms-d"); try require(session.model.pending, "Right pending fixture already accepted")
        try movement("pending", from: NSRange(location: 10, length: 0), to: NSRange(location: 10, length: 0)); try await settle(session)
        editor.string = "unreconciled"; try movement("unreconciled-editor", from: NSRange(location: 12, length: 0), to: NSRange(location: 12, length: 0))
        try await ready("quinecm"); session.select(id: folder)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        let marked = editor.string, markedRange = editor.markedRange()
        try require(!panel.control(NSTextField(), textView: editor, doCommandBy: right) && editor.string == marked && editor.markedRange() == markedRange, "Right delegate escaped marked text")
        editor.unmarkText(); try await ready("quinecm"); session.select(id: folder)
        try panel.sendHiddenKey(key("\r", code: 36, flags: .shift)); try await settle(session)
        try panel.injectText("fixture"); try await settle(session)
        try movement("open-with-end", from: NSRange(location: 7, length: 0), to: NSRange(location: 7, length: 0))
        try movement("open-with-middle", from: NSRange(location: 2, length: 0), to: NSRange(location: 3, length: 0))
        try require(session.isOpenWith && actions == 0, "Right activated an item or escaped Open With")
        try panel.verifyHidden()
        return ["cases": cases, "fallthrough": caretChecks, "renders": renders, "marked_delegate_fallthrough": true, "actions": actions,
                "owned_key_route": true, "history_scope": "Fixture input history cleared before completion; physical event grouping and actual IME remain untested"]
    }
    private static func resultCompletion(_ profile: TestProfile) async throws -> [String: Any] {
        let home = "/Fixture/Home", folder = "/Fixture/Home/Projects/quinecms-demo-site", unicode = "A👩🏽‍💻e\u{301}東京.md"
        let directories = [home: ["Projects", unicode], home + "/Projects": ["quinecms", "quinecms-demo-site"],
            home + "/Projects/quinecms": [], folder: ["README.md"]]
        let reader = PathReading(files: FileReading(metadata: { path in FileMetadata(type: directories[path] == nil ? .file : .directory) },
            children: { directories[$0] ?? [] }, ignoreContents: { _ in nil }, ignoresCase: { _ in false }), canonical: { $0 })
        let folders = ["quinecms", "quinecms-demo-site"].map { name in
            let path = home + "/Projects/" + name
            return CatalogEntry(item: SearchItem(id: "folder:" + path, kind: .folder, name: name, path: path), target: .file(URL(fileURLWithPath: path)), icon: .file(path))
        }
        let catalog = try CatalogSnapshot(entries: folders + [
            CatalogEntry(item: SearchItem(id: "file:unicode", kind: .file, name: unicode, path: home + "/" + unicode), target: .file(URL(fileURLWithPath: home + "/" + unicode)), icon: .file(home + "/" + unicode)),
            CatalogEntry(item: SearchItem(id: "app:fixture", kind: .app, name: "Fixture Editor"), target: .application(URL(fileURLWithPath: "/Fixture/Editor.app")), icon: .symbol("app")),
            CatalogEntry(item: SearchItem(id: "setting:displays", kind: .setting, name: "Displays"), target: .settings(bundle: "fixture", anchor: nil), icon: .symbol("display"))] + CatalogEntry.commands)
        var config = AppConfig(); config.prefixes["apps"] = "@"; config.prefixes["commands"] = "!"
        let session = LauncherSession(config: config, pathReader: reader, pathHome: home, pathAccess: FileAccessPolicy(protectedPaths: [:]), usage: { UsageSnapshot() })
        session.setCatalog(catalog)
        var actions = 0; session.onAction = { _ in actions += 1 }
        let panel = PanelController(session: session, icons: IconLoader(fixtureOnly: true), presentationAllowed: false)
        defer { panel.hide() }; try panel.beginHiddenShowing(); try panel.injectText("")
        let editor = try panel.hiddenEditor()
        guard let undo = editor.undoManager else { throw PanelCheckFailure(message: "Completion editor undo manager missing") }
        func history(_ expected: String) async throws {
            let deadline = ObservationClock.after(ObservationClock.now, milliseconds: 2000)
            while session.model.query != expected && ObservationClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            try require(editor.string == expected && session.model.query == expected, "Native completion history did not restore query")
            try await settle(session)
        }
        var cases: [[String: Any]] = []
        for (name, query, expected) in [("folder", "quinecm", "~/Projects/quinecms-demo-site/"),
            ("scoped-folder", "'quinecm", "~/Projects/quinecms-demo-site/"), ("file", "'東京", "~/" + unicode),
            ("app", "@fixt", "@Fixture Editor"), ("setting", ".disp", ".Displays"), ("command", "!loc", "!Lock Screen")] {
            try panel.injectText(query); try await settle(session)
            if name.contains("folder") { session.select(id: "folder:" + folder) }
            var renders: [String] = []
            func capture(_ state: String) throws {
                for dark in [false, true] {
                    panel.setAppearance(dark: dark)
                    let file = "completion-\(name)-\(state)-\(dark ? "dark" : "light").jpg"
                    try panel.capture(to: profile.directory.appendingPathComponent(file)); renders.append(file)
                }
            }
            try capture("before")
            // Isolate the completion's native history action. Hidden injected inputs
            // can share an event group; physical key-event grouping stays untested.
            undo.removeAllActions(); editor.breakUndoCoalescing()
            editor.doCommand(by: #selector(NSResponder.insertTab(_:))); try await history(expected)
            let currentEditor = try panel.hiddenEditor()
            try require(currentEditor === editor && editor.selectedRange() == NSRange(location: expected.utf16.count, length: 0), "Tab moved focus or selected the query")
            if name.contains("folder") { try require(session.model.rows.first?.entry.item.name == "README.md", "Folder Tab did not list contents") }
            try capture("after")
            try require(undo.canUndo, "Tab has no native undo action")
            editor.doCommand(by: NSSelectorFromString("undo:")); try await history(query)
            try require(undo.canRedo, "Tab undo has no redo")
            editor.doCommand(by: NSSelectorFromString("redo:")); try await history(expected)
            cases.append(["kind": name, "query": query, "completion": expected, "undo_restored": query, "redo_restored": expected, "renders": renders])
        }
        var noOps: [String] = []
        func noOp(_ name: String, _ command: Selector) throws {
            let before = editor.string, selection = editor.selectedRange(), revision = session.model.revision
            undo.removeAllActions()
            editor.doCommand(by: command)
            let currentEditor = try panel.hiddenEditor()
            try require(currentEditor === editor && editor.string == before && editor.selectedRange() == selection && session.model.revision == revision && !undo.canUndo, "Tab no-op changed editor/history: \(name)")
            noOps.append(name)
        }
        try noOp("identical", #selector(NSResponder.insertTab(_:)))
        try noOp("shift-tab", #selector(NSResponder.insertBacktab(_:)))
        try panel.injectText(""); try noOp("no-selection", #selector(NSResponder.insertTab(_:)))
        try panel.injectText("?fixture"); try await settle(session); try noOp("web", #selector(NSResponder.insertTab(_:)))
        try panel.injectText("quinecm"); try await settle(session)
        try panel.injectText("quinecms-d"); try require(session.model.pending, "Pending guard fixture unexpectedly completed synchronously")
        try noOp("pending", #selector(NSResponder.insertTab(_:))); try await settle(session)
        editor.string = "unreconciled fixture edit"
        try noOp("unreconciled-editor", #selector(NSResponder.insertTab(_:)))
        try panel.injectText("quinecm"); try await settle(session)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try noOp("marked-tab", #selector(NSResponder.insertTab(_:)))
        try noOp("marked-backtab", #selector(NSResponder.insertBacktab(_:)))
        try require(editor.hasMarkedText(), "Tab committed or discarded marked text")
        editor.unmarkText(); try require(actions == 0, "Completion activated a result"); try panel.verifyHidden()
        return ["cases": cases, "consumed_no_ops": noOps, "native_undo_redo": true, "history_scope": "Completion action isolated after clearing fixture input history; physical event grouping untested", "actions": actions, "real_filesystem_reads": 0]
    }
    private static func tightPathRanking(_ profile: TestProfile) async throws -> [String: Any] {
        let root = "/Fixture/Home/Projects", project = root + "/apparate"
        let shallow = project + "/build", deep = project + "/docs/wiki/build"
        let directories = [root: ["apparate"], project: ["build", "docs"], project + "/docs": ["wiki"],
                           project + "/docs/wiki": ["build"], shallow: [], deep: []]
        let reader = FileReading(metadata: { _ in FileMetadata(type: .directory) }, children: { directories[$0] ?? [] },
                                 ignoreContents: { _ in nil }, ignoresCase: { _ in false })
        let files = try await Task.detached {
            try await FileCrawler(reader: reader).crawl(folders: [.init(path: root)], respectGitignore: true, skipHiddenFiles: true, access: FileAccessPolicy(protectedPaths: [:])).snapshot
        }.value
        var cases: [[String: Any]] = []
        for opens in [1.0, 5.0] {
            let usage = UsageSnapshot(counts: ["folder:" + deep: opens])
            var config = AppConfig(); config.resultLocation = .below
            let session = LauncherSession(config: config, requiresFiles: true, usage: { usage })
            session.setFiles(files); session.setCatalog(try CatalogSnapshot(entries: []))
            let panel = PanelController(session: session, icons: IconLoader(fixtureOnly: true), presentationAllowed: false)
            defer { panel.hide() }
            try panel.beginHiddenShowing(); try panel.injectText("apparate/build"); try await settle(session)
            let rows = session.model.rows
            try require(rows.count == 2 && rows.first?.entry.item.path == (opens == 1 ? shallow : deep), "Tight path usage crossover")
            try require(rows.allSatisfy { $0.result.highlights == [0, 1, 2, 3, 4] }, "Path ranking changed name highlights")
            var renders: [String] = []
            for dark in [false, true] {
                panel.setAppearance(dark: dark)
                let file = "tight-path-\(Int(opens))-opens-\(dark ? "dark" : "light").jpg"
                try panel.capture(to: profile.directory.appendingPathComponent(file)); renders.append(file)
            }
            try panel.verifyHidden()
            cases.append(["deeper_opens": opens, "paths": rows.map { $0.entry.item.path! }, "text_scores": rows.map(\.result.textScore),
                          "usage_boosts": rows.map(\.result.usageBoost), "highlights": rows.map(\.result.highlights), "renders": renders])
        }
        return ["cases": cases, "real_filesystem_reads": 0, "native_actions": 0]
    }
    private static func indexedDotNames(_ profile: TestProfile) async throws -> [String: Any] {
        let home = "/Fixture/Home"
        let directories = [home: [".config", ".env", "vite.config.js", "Projects"], home + "/.config": ["settings.json"],
            home + "/Projects": ["Repo"], home + "/Projects/Repo": [".config", ".git", "config.json"],
            home + "/Projects/Repo/.config": ["sentinel.txt"], home + "/Projects/Repo/.git": ["objects"]]
        let listed = Mutex<[String]>([])
        let reader = PathReading(files: FileReading(metadata: { path in
            FileMetadata(type: directories[path] == nil ? .file : .directory)
        }, children: { path in listed.withLock { $0.append(path) }; return directories[path] ?? [] }, ignoreContents: { _ in nil }, ignoresCase: { _ in false }), canonical: { $0 })
        let files = try await Task.detached {
            try await FileCrawler(reader: reader.files).crawl(folders: [.init(path: home, depth: 1), .init(path: home + "/Projects")], respectGitignore: true, access: FileAccessPolicy(protectedPaths: [:])).snapshot
        }.value
        try require(!listed.withLock { $0.contains { $0.split(separator: "/").contains { $0.hasPrefix(".") } } }, "Indexer descended into a dot directory")
        var config = AppConfig(); config.skipHiddenFiles = false // Section-6 dot-inclusive regression fixture.
        let session = LauncherSession(config: config, requiresFiles: true, pathReader: reader, pathHome: home, pathAccess: FileAccessPolicy(protectedPaths: [:]), usage: { UsageSnapshot() })
        session.setFiles(files)
        session.setCatalog(try CatalogSnapshot(entries: [CatalogEntry(item: SearchItem(id: "fixture:config-setting", kind: .setting, name: "Configuration"), target: .settings(bundle: "fixture", anchor: nil))]))
        let panel = PanelController(session: session, icons: IconLoader(fixtureOnly: true), presentationAllowed: false)
        defer { panel.hide() }; try panel.beginHiddenShowing()
        var cases: [[String: Any]] = []
        for (name, query) in [("config-dot", "'.config"), ("config-ordinary", "config"), ("env", "'.env"),
            ("internal-path", "'Projects/.config"), ("settings-prefix", ".config"), ("direct-path", "~/.config/")] {
            try panel.injectText(query); try await settle(session)
            let rows = session.model.rows
            switch name {
            case "config-dot": try require(rows.first?.entry.item.path == home + "/.config" && rows.first?.result.highlights == Array(0..<7), "Home .config must rank first with highlights")
            case "config-ordinary": try require(!rows.isEmpty && rows.allSatisfy { !$0.entry.item.name.hasPrefix(".") }, "Ordinary query leaked dot entries")
            case "env": try require(rows.first?.entry.item.name == ".env", "Dot file missing")
            case "internal-path": try require(rows.first?.entry.item.path == home + "/Projects/Repo/.config", "Internal dot path missing")
            case "settings-prefix": try require(rows.first?.entry.item.kind == .setting, "Settings prefix changed")
            default: try require(rows.first?.entry.item.name == "settings.json", "Direct path navigation changed")
            }
            var renders: [String] = []
            for dark in [false, true] {
                panel.setAppearance(dark: dark)
                let file = "indexed-dot-\(name)-\(dark ? "dark" : "light").jpg"
                try panel.capture(to: profile.directory.appendingPathComponent(file)); renders.append(file)
            }
            cases.append(["query": query, "names": rows.map(\.entry.item.name), "highlights": rows.map(\.result.highlights), "renders": renders])
        }
        try panel.verifyHidden()
        return ["cases": cases, "dot_count": files.dotEntryCount, "indexed_count": files.count, "real_filesystem_reads": 0, "dot_directory_descent": false]
    }
    private static func pathNavigation(_ profile: TestProfile) async throws -> [String: Any] {
        // Synthetic filesystem only: no actual home, disk root or protected directory reads.
        let home = "/Fixture/Home"
        let listings: [String: [String]] = [home: ["Library", ".ssh", ".config", "node_modules", "note.txt", "Documents", "Unreadable"],
            home + "/Library": ["Application Support", "Preferences"], home + "/Library/Application Support": ["A👩🏽‍💻e\u{301}東京.md"],
            home + "/.config": ["settings.json"], home + "/.ssh": [], home + "/node_modules": [], home + "/Unreadable": []]
        let reader = PathReading(files: FileReading(metadata: { path in
            if listings[path] != nil { return FileMetadata(type: .directory) }
            if listings.values.flatMap({ $0 }).contains(URL(fileURLWithPath: path).lastPathComponent) { return FileMetadata(type: .file) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }, children: { path in
            if path == home + "/Unreadable" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
            return listings[path] ?? []
        }), canonical: { $0 })
        let session = LauncherSession(config: AppConfig(), requiresFiles: true, pathReader: reader, pathHome: home,
            pathAccess: FileAccessPolicy(protectedPaths: [home + "/Documents": .denied]), usage: { UsageSnapshot() })
        let icons = IconLoader(fixtureOnly: true)
        let panel = PanelController(session: session, icons: icons, presentationAllowed: false)
        defer { panel.hide() }; try panel.beginHiddenShowing(); try panel.injectText("")
        let editor = try panel.hiddenEditor()
        guard let undo = editor.undoManager else { throw PanelCheckFailure(message: "Field editor undo manager missing") }
        try panel.injectText("?~/Library/App"); try await settle(session)
        try require(!session.isCatalogReady && session.completion == "~/Library/Application Support/", "Path mode waited on the catalog or honored a scope prefix")
        editor.doCommand(by: #selector(NSResponder.insertTab(_:))); try await settle(session)
        let completed = "~/Library/Application Support/"
        try require(panel.text == completed && session.model.query == completed, "Tab did not replace the field through its delegate")
        try require(session.model.rows.first?.entry.item.name == "A👩🏽‍💻e\u{301}東京.md", "Tab did not list the chosen folder")
        try require(undo.canUndo, "Tab has no native undo")
        editor.doCommand(by: NSSelectorFromString("undo:"))
        let restored = editor.string
        try require(restored != completed, "Native undo did not change the completion")
        let began = ContinuousClock.now
        while session.model.query != restored && durationMS(began.duration(to: .now)) < 2_000 { try await Task.sleep(for: .milliseconds(1)) }
        try await settle(session)
        try require(panel.text == restored && session.model.query == restored, "Native undo text and search query disagree")
        // Direct hidden inputs may share one event undo group. This checks AppKit's
        // actual restored text/results; physical key-event undo granularity stays live.
        try panel.injectText("~/note.txt"); try await settle(session)
        try require(panel.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))) && editor.string == "~/note.txt", "Identical file completion must be a consumed no-op")
        var actions: [ActionOperation] = []
        session.onAction = { request in if request.entry.target.fileURL?.path == home + "/note.txt" { actions.append(request.operation) } }
        let returnEventType = NSApp.currentEvent?.type.rawValue ?? 0
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        _ = panel.keyEquivalent(key("\r", code: 36, flags: .command))
        _ = panel.keyEquivalent(key("c", code: 8, flags: .command))
        try require(actions == [.open, .reveal, .copyPath], "Path row did not route all three native filesystem actions")
        try panel.injectText("~/Library/App"); try await settle(session)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try require(panel.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))) && editor.hasMarkedText(), "Tab must preserve marked text and stay in the field")
        editor.unmarkText()
        var renders: [String] = [], rowChecks: [[String: Any]] = []
        for (name, query, message) in [("home", "~/", nil), ("dot", "~/.ss", nil), ("folder", "~/Library/App", nil),
            ("completed", "~/Library/Application Support/", nil), ("file", "~/note.txt", nil),
            ("unicode", "~/Library/Application Support/東京", nil),
            ("missing", "~/Missing/", "Folder not found"), ("unreadable", "~/Unreadable/", "Could not read this folder"),
            ("not-folder", "~/note.txt/", "This path is not a folder"), ("no-match", "~/zzzzqqq", "No results"),
            ("protected", "~/Documents/", "Folder access is needed. Open Settings → Folders → Allow Access…")] {
            try panel.injectText(query); try await settle(session)
            try require(panel.emptyText == message, "Path message differs for \(name)")
            for (index, row) in session.model.rows.enumerated() {
                let content = panel.rows.contents[index], drawing = panel.rows.drawing(at: index)
                let expectedKind: ItemKind = listings[row.entry.item.path!] != nil ? .folder : .file
                let symbol = expectedKind == .folder ? "folder" : "doc"
                try require(row.entry.item.kind == expectedKind && content.itemKind == expectedKind, "Path row kind differs for \(name)")
                try require(icons.resolvedIcon(content.icon, kind: content.itemKind) == .symbol(symbol), "Fixture icon differs for \(name)")
                let expectedOffsets: [Int]
                switch name {
                case "dot", "folder": expectedOffsets = [0, 1, 2]
                case "file": expectedOffsets = Array(content.title.indices.enumerated().map(\.offset))
                case "unicode": expectedOffsets = [3, 4]
                default: expectedOffsets = []
                }
                try require(content.highlights == expectedOffsets, "Path name highlight offsets differ for \(name): \(content.highlights)")
                let expectedRanges = PanelText.highlightRanges(content.title, offsets: expectedOffsets)
                try require(drawing.highlightedRanges == expectedRanges, "Path drawing dropped the name highlights")
                var fontRuns: [[String: Any]] = []
                for run in CTLineGetGlyphRuns(drawing.title) as! [CTRun] {
                    let range = CTRunGetStringRange(run), attributes = CTRunGetAttributes(run) as NSDictionary
                    let font = attributes[kCTFontAttributeName] as! CTFont
                    let weight = (CTFontCopyTraits(font) as NSDictionary)[kCTFontWeightTrait] as! Double
                    for offset in range.location..<(range.location + range.length) {
                        let highlighted = expectedRanges.contains { NSLocationInRange(offset, $0) }
                        try require(highlighted ? weight > 0.2 : weight < 0.1, "Path font weight differs for \(name) at \(offset): \(weight)")
                    }
                    fontRuns.append(["utf16_range": [range.location, range.length], "weight": weight])
                }
                rowChecks.append(["state": name, "title": content.title, "kind": content.kind, "fixture_symbol": symbol,
                    "highlight_offsets": content.highlights, "highlight_utf16_ranges": drawing.highlightedRanges.map { [$0.location, $0.length] }, "font_runs": fontRuns])
            }
            for dark in [false, true] {
                panel.setAppearance(dark: dark)
                let file = "path-\(name)-\(dark ? "dark" : "light").jpg"
                try panel.capture(to: profile.directory.appendingPathComponent(file)); renders.append(file)
            }
        }
        try panel.verifyHidden()
        return ["native_tab_and_undo": true, "native_undo_restored_empty": restored.isEmpty, "native_filesystem_action_routes": 3, "return_current_event_type": returnEventType, "marked_tab_guard": true,
            "catalog_independent": true, "real_actions": 0, "real_filesystem_reads": 0, "rows": rowChecks, "renders": renders]
    }
    private static func largerBelowIcons(_ profile: TestProfile) async throws -> [String: Any] {
        func until(_ predicate: () -> Bool) async throws {
            let deadline = ObservationClock.after(ObservationClock.now, milliseconds: 2000)
            while !predicate() && ObservationClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            try require(predicate(), "Icon fixture timed out")
        }
        // An owned vector source exercises the production PNG rasterizer without Workspace.
        let source = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: rect.insetBy(dx: 8, dy: 8), xRadius: 24, yRadius: 24).fill()
            NSColor.white.setFill(); NSRect(x: 28, y: 56, width: 72, height: 16).fill(); NSRect(x: 56, y: 28, width: 16, height: 72).fill()
            return true
        }
        guard let small = IconLoader.rasterize(source, pixels: 40), let large = IconLoader.rasterize(source, pixels: 64) else { throw PanelCheckFailure(message: "Fixture rasterization failed") }
        let data = [40: small, 64: large]
        func checkImage(_ image: NSImage?, size: PanelIconSize) throws {
            guard let image else { throw PanelCheckFailure(message: "Missing loaded icon") }
            try require(image.size == NSSize(width: size.points, height: size.points), "Wrong icon point size")
            try require(image.representations.contains { $0.pixelsWide == size.pixels && $0.pixelsHigh == size.pixels }, "Wrong icon raster resolution")
        }
        let file = CatalogEntry(item: SearchItem(id: "icon-file", kind: .file, name: "Icon file", path: "/Fixture/icon.md"), target: .file(URL(fileURLWithPath: "/Fixture/icon.md")), icon: .file("/Fixture/icon.md"))
        var races: [[String: Any]] = []
        for scenario in ["loaded-small", "late-small", "late-large"] {
            let gate = IconRasterGate(), icons = IconLoader(fileRaster: { _, pixels in await gate.read(pixels) })
            defer { gate.cancel() }
            var config = AppConfig(); config.resultLocation = scenario == "late-large" ? .below : .inline
            let initial = config.resultLocation.iconSize
            let session = LauncherSession(config: config, usage: { UsageSnapshot() })
            session.setCatalog(try CatalogSnapshot(entries: [file]))
            let panel = PanelController(session: session, icons: icons, presentationAllowed: false)
            defer { panel.hide() }; try panel.beginHiddenShowing(); try panel.injectText("icon"); try await settle(session)
            try await until { gate.requests == [initial.pixels] }
            if scenario == "loaded-small" {
                gate.finish(initial.pixels, data: data[initial.pixels]); try await until { icons.pendingFileLoads == 0 }
                try checkImage(panel.rows.loadedIcon(at: 0), size: initial)
            }
            config.resultLocation = initial == .compact ? .below : .inline; session.setConfig(config)
            let final = config.resultLocation.iconSize
            try require(panel.rows.loadedIcon(at: 0) == nil, "Layout switch drew the previous-size icon")
            try await until { gate.requests.count == 2 }
            if scenario != "loaded-small" {
                gate.finish(initial.pixels, data: data[initial.pixels]); try await until { icons.pendingFileLoads == 1 }
                try require(panel.rows.loadedIcon(at: 0) == nil, "Late wrong-size icon was installed")
            }
            gate.finish(final.pixels, data: data[final.pixels]); try await until { icons.pendingFileLoads == 0 }
            try checkImage(panel.rows.loadedIcon(at: 0), size: final)
            for mode in [ResultLocation.inline, .below, .right, .below] {
                config.resultLocation = mode; session.setConfig(config)
                try checkImage(panel.rows.loadedIcon(at: 0), size: mode.iconSize)
            }
            try require(gate.requests.count == 2, "Size-keyed cache missed or coalesced different sizes")
            try panel.verifyHidden()
            races.append(["scenario": scenario, "raster_requests": gate.requests, "old_image_cleared_synchronously": true, "wrong_size_late_result_rejected": scenario != "loaded-small", "warm_switch_sizes_correct": true])
        }
        let entries: [CatalogEntry] = [
            CatalogEntry(item: SearchItem(id: "icon-app", kind: .app, name: "Icon App"), target: .application(URL(fileURLWithPath: "/Fixture/Editor.app")), icon: .file("/Fixture/Editor.app")), file,
            CatalogEntry(item: SearchItem(id: "icon-folder", kind: .folder, name: "Icon Folder"), target: .file(URL(fileURLWithPath: "/Fixture/Folder")), icon: .symbol("folder")),
            CatalogEntry(item: SearchItem(id: "icon-setting", kind: .setting, name: "Icon Setting"), target: .settings(bundle: "fixture", anchor: nil), location: "Display", icon: .file("/Fixture/Display.prefPane")),
            CatalogEntry(item: SearchItem(id: "icon-command", kind: .command, name: "Icon Command"), target: .command(.trash), icon: .symbol("trash"))
        ] + (0..<4).map { i in CatalogEntry(item: SearchItem(id: "icon-extra-\(i)", kind: .file, name: "Icon Notes \(i)"), target: .file(URL(fileURLWithPath: "/Fixture/Notes/\(i).md")), icon: .symbol("doc")) }
        var config = AppConfig(); config.resultLocation = .below
        let icons = IconLoader(fileRaster: { _, pixels in data[pixels] }), session = LauncherSession(config: config, usage: { UsageSnapshot() })
        let panel = PanelController(session: session, icons: icons, presentationAllowed: false)
        defer { panel.hide() }; try panel.beginHiddenShowing()
        var renders: [String] = [], heights: [Double] = []
        for count in [1, 3, 9] {
            session.setCatalog(try CatalogSnapshot(entries: Array(entries.prefix(count))))
            try panel.injectText("icon"); try await settle(session)
            try await until { icons.pendingFileLoads == 0 && panel.rows.visibleIndices.allSatisfy { panel.rows.loadedIcon(at: $0) != nil } }
            try require(panel.rows.contents.count == count && panel.panelFrame.height == PanelLayout.height(rows: count, location: .below), "Below mixed-row height changed")
            if count > 1 { session.move(1) }
            heights.append(panel.panelFrame.height)
            for i in panel.rows.visibleIndices {
                let content = panel.rows.contents[i], drawing = panel.rows.drawing(at: i)
                try require(drawing.iconFrame == NSRect(x: 9, y: 4, width: 32, height: 32) && drawing.titleFrame.minX == 50, "Below icon/text column differs")
                if content.location.isEmpty { try require(drawing.titleFrame.midY == 20, "Single-line Below title moved") }
                else { try require(drawing.locationFrame.minX == 50 && drawing.titleFrame.minY == 4 && drawing.locationFrame.minY == 21, "Below text vertical positions changed") }
                if case .file = content.icon { try checkImage(panel.rows.loadedIcon(at: i), size: .large) }
                try require(drawing.titleFrame.maxX <= drawing.hintFrame.minX - 9, "Below title overlaps hint")
            }
            for dark in [false, true] {
                panel.setAppearance(dark: dark); let name = "below-icons-\(count)-\(dark ? "dark" : "light").jpg"
                try panel.capture(to: profile.directory.appendingPathComponent(name)); renders.append(name)
            }
        }
        try panel.injectText("?icon fixture"); try await settle(session)
        try require(panel.rows.contents.count == 1 && panel.rows.contents[0].itemKind == .web && panel.rows.drawing(at: 0).iconFrame.width == 32, "Below web icon differs")
        for dark in [false, true] {
            panel.setAppearance(dark: dark); let name = "below-icons-web-\(dark ? "dark" : "light").jpg"
            try panel.capture(to: profile.directory.appendingPathComponent(name)); renders.append(name)
        }
        try panel.verifyHidden()
        return ["races": races, "raster_pixels": [40, 64], "below_points": 32, "below_text_x": 50, "heights": heights, "renders": renders, "workspace_icon_reads": 0]
    }
    private static func locationLayouts(_ profile: TestProfile) async throws -> [[String: Any]] {
        let entries = (0..<50).map { i in
            CatalogEntry(item: SearchItem(id: "location:\(i)", kind: .file, name: String(format: "Result %02d", i)),
                target: .file(URL(fileURLWithPath: "/Fixture/Projects/Group/Result \(i)")), icon: .symbol("doc"))
        }
        var results: [[String: Any]] = []
        for mode in ResultLocation.allCases {
            var config = AppConfig(); config.resultLocation = mode
            let session = LauncherSession(config: config, usage: { UsageSnapshot() })
            let panel = PanelController(session: session, icons: IconLoader(fixtureOnly: true), presentationAllowed: false)
            defer { panel.hide() }
            try panel.beginHiddenShowing()
            let top = panel.panelFrame.maxY
            var sizes: [Double] = []
            for count in [0, 1, 3, 9] {
                session.setCatalog(try CatalogSnapshot(entries: Array(entries.prefix(count))))
                try panel.injectText(count == 0 ? "" : "result"); try await settle(session)
                try require(panel.panelFrame.height == PanelLayout.height(rows: count, location: mode) && panel.panelFrame.maxY == top, "Location mode geometry/top edge mismatch")
                try require(panel.rows.geometryIsValid(), "Location mode native viewport geometry mismatch")
                for dark in [false, true] {
                    panel.setAppearance(dark: dark)
                    try panel.capture(to: profile.directory.appendingPathComponent("location-\(mode.rawValue)-\(count)-\(dark ? "dark" : "light").jpg"))
                }
                _ = try searchGeometry(panel, state: mode.rawValue); _ = try labelGeometry(panel)
                panel.observationRun = 42
                try panel.injectText(""); try panel.injectText(count == 0 ? "" : "result"); try await settle(session)
                let image = try panel.render(), scale = Double(image.pixelsWide) / 640
                let marker = MarkerPixels.decode(width: image.pixelsWide, height: image.pixelsHigh, originX: 588 * scale, originY: 16 * scale, scale: scale) { x,y in
                    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (128,128,128) }
                    return (UInt8((color.redComponent * 255).rounded()), UInt8((color.greenComponent * 255).rounded()), UInt8((color.blueComponent * 255).rounded()))
                }
                try require(marker != nil && marker == panel.rows.observationMarker, "Location mode raster marker did not decode")
                panel.observationRun = nil; sizes.append(panel.panelFrame.height)
                if count > 0 { try panel.verifyPendingPresentation(); try await settle(session) }
            }
            session.setCatalog(try CatalogSnapshot(entries: entries)); try panel.injectText("result"); try await settle(session)
            session.move(49)
            let selected = session.model.selectedID!, element = panel.rows.accessibilityElements[selected]!
            let first = session.model.firstVisibleRow, revision = session.model.revision
            for next in ResultLocation.allCases {
                config.resultLocation = next; session.setConfig(config)
                try require(session.model.revision == revision && session.model.selectedID == selected && session.model.firstVisibleRow == first, "Live layout lost session state")
                try require(panel.rows.accessibilityElements[selected] === element, "Layout change replaced AX identity")
                let rect = element.accessibilityFrameInParentSpace()
                try require(rect.height == next.rowHeight && rect.minY == 47 + 8 * next.rowHeight, "AX row frame retained old row height")
                var opened: String?
                session.onAction = { opened = $0.entry.item.id }
                panel.rows.activate(point: NSPoint(x: 20, y: 47 + 8.5 * next.rowHeight))
                try require(opened == selected, "Click after resize/scroll opened wrong row")
                opened = nil; _ = panel.keyEquivalent(key("9", code: 25, flags: .command))
                try require(opened == selected, "Numbered action after resize/scroll opened wrong row")
            }
            config.resultLocation = mode; session.setConfig(config)
            // A presentation-only change reflows the previous complete rows while pending.
            try panel.injectText("resul")
            let pendingRevision = session.model.revision, previous = panel.rows.contents
            config.resultLocation = mode == .below ? .right : .below; session.setConfig(config)
            try require(session.model.pending && session.model.revision == pendingRevision && panel.rows.contents == previous, "Pending layout change changed query or complete rows")
            try require(panel.panelFrame.height == PanelLayout.height(rows: 9, location: config.resultLocation) && panel.panelFrame.maxY == top, "Pending layout did not resize immediately")
            try await settle(session); config.resultLocation = mode; session.setConfig(config)
            let longTitle = String(repeating: "Long title ", count: 16)
            let fixtures: [(String, CatalogEntry, String)] = [
                ("long-location", CatalogEntry(item: SearchItem(id: "long-path", kind: .file, name: "A👩🏽‍💻e\u{301}東京.md"), target: .file(URL(fileURLWithPath: "/Fixture/" + String(repeating: "long-directory/", count: 12) + "A.md")), icon: .symbol("doc")), "ae東"),
                ("long-title", CatalogEntry(item: SearchItem(id: "long-title", kind: .file, name: longTitle), target: .file(URL(fileURLWithPath: "/Fixture/short/file")), icon: .symbol("doc")), "long"),
                ("both-long", CatalogEntry(item: SearchItem(id: "both-long", kind: .file, name: longTitle), target: .file(URL(fileURLWithPath: "/Fixture/" + String(repeating: "long-directory/", count: 12) + "file")), icon: .symbol("doc")), "long")]
            for (name, entry, query) in fixtures {
                session.setCatalog(try CatalogSnapshot(entries: [entry])); try panel.injectText(query); try await settle(session)
                let drawing = panel.rows.drawing(at: 0)
                try require(drawing.titleFrame.maxX <= drawing.hintFrame.minX - 9, "Location layout overlaps hint")
                if name == "long-location" { try require(drawing.locationTruncated && !drawing.titleTruncated && !drawing.highlightedRanges.isEmpty, "Long location stole title/highlighting") }
                else {
                    try require(drawing.titleTruncated, "Long title not truncated")
                    try require(mode == .below ? drawing.location != nil : drawing.location == nil, "Location/title priority wrong")
                }
                for dark in [false, true] {
                    panel.setAppearance(dark: dark)
                    try panel.capture(to: profile.directory.appendingPathComponent("location-\(mode.rawValue)-\(name)-\(dark ? "dark" : "light").jpg"))
                }
            }
            session.setCatalog(try TestProfile.fixtureCatalog())
            for query in ["keyboard", "restart"] {
                try panel.injectText(query); try await settle(session)
                let row = panel.rows.contents[0], drawing = panel.rows.drawing(at: 0)
                if query == "keyboard" { try require(row.location == "Keyboard" && drawing.location != nil, "Settings pane location lost") }
                else { try require(row.location.isEmpty && drawing.titleFrame.midY == mode.rowHeight / 2, "Command title not centered") }
                for dark in [false, true] {
                    panel.setAppearance(dark: dark)
                    try panel.capture(to: profile.directory.appendingPathComponent("location-\(mode.rawValue)-\(query)-\(dark ? "dark" : "light").jpg"))
                }
                if query == "restart" {
                    session.act(.open)
                    try require(panel.rows.contents[0].location == "Press Return again" && panel.rows.drawing(at: 0).location != nil, "Restart confirmation location disappeared")
                    let previous = panel.rows.contents, footer = panel.footerText
                    try panel.injectText("restar")
                    config.resultLocation = mode == .below ? .right : .below; session.setConfig(config)
                    try require(panel.rows.contents == previous && panel.footerText == footer, "Pending reflow changed the previous complete confirmation")
                    try await settle(session)
                }
            }
            try panel.verifyHidden()
            results.append(["mode": mode.rawValue, "heights": sizes, "marker_decoded": true, "live_change_pending_selection_ax_click_number": true])
        }
        return results
    }
    private static func digest(_ rows: [SearchResult]) -> String {
        let text = rows.map { "\($0.item.id)|\($0.tier.rawValue)|\($0.textScore.bitPattern)|\($0.usageBoost.bitPattern)|\($0.source)|\($0.highlights)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func statistics(_ samples: [Double]) -> [String: Any] {
        let values = samples.sorted()
        guard !values.isEmpty else { return ["samples": 0] }
        return ["samples": values.count, "median_ms": values[values.count / 2],
                "p95_ms": values[max(0, Int(ceil(Double(values.count) * 0.95)) - 1)], "max_ms": values.last!]
    }
    private static func measure(_ profile: TestProfile, report: inout [String: Any]) async throws {
        let loadStart = ContinuousClock.now
        let count = profile.panelCount
        let files = try await Task.detached(priority: .utility) {
            let fixture = SyntheticFiles(count: count)
            return try await FileCrawler(reader: fixture.reader).crawl(folders: [.init(path: fixture.root, depth: 10)],
                respectGitignore: true, access: FileAccessPolicy(observations: [])).snapshot
        }.value
        let loadMS = durationMS(loadStart.duration(to: .now)), loadedFootprint = try ProcessMetrics.footprint()
        let catalog = try TestProfile.fixtureCatalog()
        let trace = PanelSearchTrace(), coordinator = SearchCoordinator(observe: { trace.record($0) })
        coordinator.delivery = profile.delivery
        let session = LauncherSession(config: AppConfig(), requiresFiles: true, coordinator: coordinator, usage: { UsageSnapshot() })
        session.setCatalog(catalog); session.setFiles(files)
        let panelStart = ContinuousClock.now
        let panel = PanelController(session: session, icons: IconLoader(fixtureOnly: true), presentationAllowed: false,
                                    opaque: profile.opaque, warmUp: profile.warmUp, activityEnabled: profile.activityEnabled, initialAppearance: .darkAqua)
        let panelMS = durationMS(panelStart.duration(to: .now))
        report["appearance"] = panel.appearanceName; report["uses_vibrancy"] = panel.usesVibrancy
        report["reduce_transparency"] = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        defer { panel.hide() }
        var shows: [Double] = []
        for _ in 0..<30 {
            let start = ContinuousClock.now
            try panel.beginHiddenShowing()
            try autoreleasepool { _ = try panel.render() }
            shows.append(durationMS(start.duration(to: .now)))
            panel.hide(); await Task.yield()
        }
        let afterShows = try ProcessMetrics.footprint()
        try panel.beginHiddenShowing()
        // Editor setup belongs to showing, before the first physical key in production.
        let editorStart = ContinuousClock.now
        try panel.injectText("")
        let fieldEditor = try panel.hiddenEditor()
        report["input_setup_ms"] = durationMS(editorStart.duration(to: .now))
        report["field_editor_configuration"] = ["completion": fieldEditor.isAutomaticTextCompletionEnabled,
            "spelling": fieldEditor.isContinuousSpellCheckingEnabled, "grammar": fieldEditor.isGrammarCheckingEnabled,
            "correction": fieldEditor.isAutomaticSpellingCorrectionEnabled, "replacement": fieldEditor.isAutomaticTextReplacementEnabled,
            "data_detection": fieldEditor.isAutomaticDataDetectionEnabled, "link_detection": fieldEditor.isAutomaticLinkDetectionEnabled,
            "rich_text": fieldEditor.isRichText, "writing_tools": fieldEditor.writingToolsBehavior.rawValue]
        // Let the asynchronous per-showing usage read complete, without timing it as a key.
        try await Task.sleep(for: .milliseconds(20))
        let origin = ContinuousClock.now
        func time(_ instant: ContinuousClock.Instant = .now) -> Double { durationMS(origin.duration(to: instant)) }
        var records: [UInt64: [String: Any]] = [:], order: [UInt64] = [], submitted: [UInt64: UInt64] = [:]
        var textCallbacks: [UInt64: Double] = [:], mainCallbacks: [UInt64: Double] = [:], renderingFailure = false
        var mainCPU: [UInt64: UInt64] = [:]
        var inputBegan = 0.0
        panel.onTextBegin = { inputBegan = time() }
        coordinator.onDelivery = {
            mainCallbacks[$0] = time($1)
            mainCPU[$0] = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        }
        session.onResponse = { records[$0]?["accept_started_ms"] = time() }
        session.onSubmitted = { submitted[$0] = $1 }
        panel.onText = { _, revision in textCallbacks[revision] = time() }
        session.onResults = { revision in records[revision]?["accepted_ms"] = time() }
        panel.onUpdate = { revision, pending, applyMS in
            guard !pending, records[revision] != nil else { return }
            let viewFinished = time()
            records[revision]?["view_finished_ms"] = viewFinished
            records[revision]?["view_apply_ms"] = applyMS
            records[revision]?["view_started_ms"] = viewFinished - applyMS
            if records[revision]?["explicit_raster"] as? Bool == true {
                let started = time()
                do { try autoreleasepool { _ = try panel.render() } }
                catch { renderingFailure = true }
                records[revision]?["raster_started_ms"] = started; records[revision]?["raster_finished_ms"] = time()
            }
            records[revision]?["status"] = "completed"
            records[revision]?["result_hash"] = digest(session.model.rows.map(\.result))
        }
        let words = ["readme", "config", "network", "calendar", "terminal", "café", "strasse", "東京資料", "Project-0001/report", "code", ".keyboard", "?swift"]
        let prefixes = words.flatMap { word in (1...word.count).map { String(word.prefix($0)) } }
        func phase(_ queries: [String], cadenceMS: Int, label: String, raster: Bool = false) async throws {
            let start = ContinuousClock.now
            for (offset, query) in queries.enumerated() {
                let deadline = start.advanced(by: .milliseconds(offset * cadenceMS))
                if deadline > .now { try await Task.sleep(until: deadline, clock: .continuous) }
                if let old = order.last, records[old]?["status"] as? String == "pending" { records[old]?["status"] = "superseded" }
                let inputTime = time()
                try panel.injectText(query)
                let revision = session.model.revision
                records[revision] = ["sequence": order.count, "phase": label, "explicit_raster": raster, "query": query, "revision": revision,
                    "scheduled_ms": time(deadline), "delivered_ms": inputTime, "text_delegate_started_ms": inputBegan, "text_callback_ms": textCallbacks[revision] ?? time(), "status": "pending"]
                order.append(revision)
                let waitStart = time()
                let ready: Bool
                if profile.waitMS > 0, let generation = submitted[revision] { ready = trace.wait(for: generation, milliseconds: profile.waitMS) }
                else { ready = false }
                records[revision]?["wait_elapsed_ms"] = time() - waitStart
                records[revision]?["worker_ready_after_wait"] = ready
                records[revision]?["input_handler_finished_ms"] = time()
                if raster {
                    try autoreleasepool { _ = try panel.render() }
                    records[revision]?["letter_raster_finished_ms"] = time()
                }
            }
            let end = ContinuousClock.now
            while session.model.pending && durationMS(end.duration(to: .now)) < 2000 { try await Task.sleep(for: .milliseconds(1)) }
            if let last = order.last, records[last]?["status"] as? String == "pending" { records[last]?["status"] = "timeout" }
        }
        try await phase(prefixes, cadenceMS: 40, label: "fixed-40ms")
        try await phase(prefixes, cadenceMS: 40, label: "raster-40ms", raster: true)
        try await phase(["n", "ne", "net", "netw", "netwo", "networ", "network", "networ", "netwo", "netw", "net", "network"], cadenceMS: 1, label: "overlap-1ms")
        let afterTyping = try ProcessMetrics.footprint()
        panel.onUpdate = nil; panel.onTextBegin = nil; coordinator.onDelivery = nil; session.onResponse = nil; session.onResults = nil; session.onSubmitted = nil; panel.onText = nil
        let traces = trace.values.withLock { $0 }, cpuAtFinish = trace.processCPUAtFinish.withLock { $0 }
        for revision in order {
            if let generation = submitted[revision] {
                records[revision]?["search_generation"] = generation
                records[revision]?["main_delivery_ms"] = mainCallbacks[generation]
                if let start = cpuAtFinish[generation], let end = mainCPU[generation] {
                    records[revision]?["main_queue_process_cpu_ms"] = Double(end - start) / 1_000_000
                }
                if let trace = traces[generation] {
                    records[revision]?["worker_submitted_ms"] = time(trace.submitted)
                    records[revision]?["worker_started_ms"] = time(trace.started)
                    records[revision]?["worker_finished_ms"] = time(trace.finished)
                    records[revision]?["worker_cancelled"] = trace.cancelled
                    records[revision]?["worker_cpu_ms"] = Double(trace.cpuNanoseconds) / 1_000_000
                }
            }
        }
        // Untimed correctness oracle for every query, including superseded generations.
        var expected: [String: String] = [:]
        for query in Set(order.compactMap { records[$0]?["query"] as? String }).sorted() {
            let parsed = ParsedQuery(query)
            var rows: [SearchResult]
            if parsed.scope == .web { rows = catalog.index.search(parsed) }
            else {
                let local = catalog.index.search(parsed, includeWebFallback: false)
                let fileRows = files.search(parsed)
                var seen = Set<String>()
                rows = Array((local + fileRows).sorted(by: SearchResult.rankedBefore).filter { seen.insert($0.item.id).inserted }.prefix(50))
                if rows.isEmpty { rows = catalog.index.search(parsed) }
            }
            expected[query] = digest(rows)
        }
        let events = order.compactMap { records[$0] }
        let completed = events.filter { $0["status"] as? String == "completed" }
        let timeouts = events.filter { $0["status"] as? String == "timeout" }.count
        let mismatches = completed.filter { $0["result_hash"] as? String != expected[$0["query"] as! String] }.count
        func latencies(_ key: String, phase: String? = nil) -> [Double] {
            events.filter { phase == nil || $0["phase"] as? String == phase }.compactMap {
                guard let end = $0[key] as? Double, let start = $0["delivered_ms"] as? Double else { return nil }
                return end - start
            }
        }
        let stages = [
            ("input_before_delegate", "text_delegate_started_ms", "delivered_ms"),
            ("delegate_to_submit", "worker_submitted_ms", "text_delegate_started_ms"),
            ("worker_queue", "worker_started_ms", "worker_submitted_ms"),
            ("search", "worker_finished_ms", "worker_started_ms"),
            ("main_queue", "main_delivery_ms", "worker_finished_ms"),
            ("delivery_to_accept", "accept_started_ms", "main_delivery_ms"),
            ("accept", "accepted_ms", "accept_started_ms"),
            ("view", "view_finished_ms", "view_started_ms"),
            ("input_handler", "input_handler_finished_ms", "delivered_ms")]
        report["stages_fixed"] = Dictionary(uniqueKeysWithValues: stages.map { name, end, start in
            (name, statistics(events.filter { $0["phase"] as? String == "fixed-40ms" }.compactMap {
                guard let end = $0[end] as? Double, let start = $0[start] as? Double else { return nil }; return end - start
            }))
        })
        panel.hide()
        try require(!panel.activityHeld && panel.activityBegins == panel.activityEnds, "Activity outlived panel showing")
        report["activity_begins"] = panel.activityBegins; report["activity_ends"] = panel.activityEnds
        report["events"] = events; report["expected_result_hashes"] = expected
        report["corpus"] = ["generator": "M3 SyntheticFiles deterministic-17-31-v1", "file_entries": files.count,
                            "catalog_entries": catalog.entries.count, "groups": 500, "queries": words,
                            "file_index": "production FileCrawler/FileIndexSnapshot; synthetic reader; no SQLite in this UI experiment"]
        let corpusData = try JSONSerialization.data(withJSONObject: report["corpus"]!, options: .sortedKeys)
        report["corpus_sha256"] = SHA256.hash(data: corpusData).map { String(format: "%02x", $0) }.joined()
        report["main_queue_process_cpu_fixed"] = statistics(events.filter { $0["phase"] as? String == "fixed-40ms" }.compactMap { $0["main_queue_process_cpu_ms"] as? Double })
        report["main_queue_non_cpu_lower_bound_fixed"] = statistics(events.filter { $0["phase"] as? String == "fixed-40ms" }.compactMap {
            guard let end = $0["main_delivery_ms"] as? Double, let start = $0["worker_finished_ms"] as? Double, let cpu = $0["main_queue_process_cpu_ms"] as? Double else { return nil }
            return max(0, end - start - cpu)
        })
        report["worker_cpu_fixed"] = statistics(events.filter { $0["phase"] as? String == "fixed-40ms" }.compactMap { $0["worker_cpu_ms"] as? Double })
        report["source_load_ms"] = loadMS; report["panel_initialization_ms"] = panelMS; report["warm_up_ms"] = panel.warmUpMS
        report["hidden_show_samples_ms"] = shows; report["cold_hidden_show_ms"] = shows[0]
        report["warm_hidden_show"] = statistics(Array(shows.dropFirst()))
        report["text_callback"] = statistics(latencies("text_callback_ms"))
        report["letter_raster"] = statistics(latencies("letter_raster_finished_ms"))
        report["input_handler_fixed"] = statistics(latencies("input_handler_finished_ms", phase: "fixed-40ms"))
        report["result_view_fixed"] = statistics(latencies("view_finished_ms", phase: "fixed-40ms"))
        report["result_view_overlap"] = statistics(latencies("view_finished_ms", phase: "overlap-1ms"))
        report["result_raster_fixed"] = statistics(latencies("raster_finished_ms", phase: "raster-40ms"))
        report["view_apply"] = statistics(completed.compactMap { $0["view_apply_ms"] as? Double })
        report["raster_only"] = statistics(completed.compactMap { value in
            guard let end = value["raster_finished_ms"] as? Double, let start = value["raster_started_ms"] as? Double else { return nil }; return end - start
        })
        report["superseded"] = events.filter { $0["status"] as? String == "superseded" }.count
        report["timeouts"] = timeouts; report["result_mismatches"] = mismatches
        report["after_index_footprint_bytes"] = loadedFootprint; report["after_30_hidden_shows_footprint_bytes"] = afterShows
        report["after_typing_footprint_bytes"] = afterTyping
        report["measurement_limits"] = "fixed/overlap phases record view-state updates without forced drawing; raster phase synchronously captures each letter and result and therefore delays main-thread delivery; cached fixture symbols in place of native filesystem icon loading; no physical keyboard, window ordering, WindowServer vibrancy or displayed-frame measurements; endpoint footprints, not peaks"
        try require(!renderingFailure && timeouts == 0 && mismatches == 0, "Rendering, timeout or generation/result correctness failed")
        try require(events.count == prefixes.count * 2 + 12 && files.count == count, "Fixture/sample count mismatch")
        try panel.verifyHidden(); report["focus_guards_checked"] = true
    }
}
