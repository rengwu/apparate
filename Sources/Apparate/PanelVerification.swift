import AppKit
import ApparateCore
import ApparateFixtures
import CryptoKit
import Synchronization

private struct PanelCheckFailure: Error { let message: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PanelCheckFailure(message: message) }
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
        report["physical_footprint_bytes"] = ProcessMetrics.footprint()
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
        for dark in [false, true] { panel.setAppearance(dark: dark); try panel.capture(to: profile.directory.appendingPathComponent("loading-\(dark ? "dark" : "light").png")) }
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
                let filename = name + (dark ? "-dark.png" : "-light.png")
                try panel.capture(to: profile.directory.appendingPathComponent(filename)); renders.append(filename)
                try require(panel.rows.geometryIsValid(), "Native row frame differs from the shared contract")
                if name == "empty" { try require(panel.footerText.isEmpty && panel.rows.contents.isEmpty, "Empty query did not clear") }
                if name == "no-results" { try require(panel.emptyText == "No results", "Scoped empty state missing") }
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
        session.scroll(5); panel.rows.activate(point: NSPoint(x: 20, y: 3 * 28 + 4))
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
            for dark in [false, true] { panel.setAppearance(dark: dark); try panel.capture(to: profile.directory.appendingPathComponent("\(entry.item.id.replacingOccurrences(of: ":", with: "-"))-\(dark ? "dark" : "light").png")) }
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
        let loadMS = durationMS(loadStart.duration(to: .now)), loadedFootprint = ProcessMetrics.footprint()
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
        let afterShows = ProcessMetrics.footprint()
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
        let afterTyping = ProcessMetrics.footprint()
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
