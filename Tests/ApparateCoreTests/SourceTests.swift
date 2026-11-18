import Foundation
import ApparateCore
import Synchronization
import Darwin

func writePlist(_ value: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url, options: .atomic)
}
@discardableResult func bundleFixture(_ url: URL, info: [String: Any], names: [String: [String: String]] = [:]) throws -> URL {
    try writePlist(info, to: url.appendingPathComponent("Contents/Info.plist"))
    for (language, names) in names { try writePlist(names, to: url.appendingPathComponent("Contents/Resources/\(language).lproj/InfoPlist.strings")) }
    return url
}
func termsFixture(_ bundle: URL, language: String, records: [[String: String]], anchor: String = "anchor", file: String = "Terms") throws {
    try writePlist([anchor: ["localizableStrings": records]], to: bundle.appendingPathComponent("Contents/Resources/\(language).lproj/\(file).searchTerms"))
}
func entryFixture(_ name: String, id: String? = nil, target: ActionTarget? = nil) -> CatalogEntry {
    CatalogEntry(item: fixture(name, id: id), target: target ?? .application(URL(fileURLWithPath: "/fixture/\(name).app")))
}
func loadFixture(_ name: String, paths: [String] = []) throws -> CatalogLoad {
    try CatalogLoad(snapshot: CatalogSnapshot(entries: [entryFixture(name)]), watchPaths: paths)
}
@MainActor final class WatcherFake: CatalogWatching {
    var callback: (@MainActor @Sendable (CatalogEvent) -> Void)?
    var starts: [[String]] = [], stops = 0, succeeds = true
    func start(paths: [String], changed: @escaping @MainActor @Sendable (CatalogEvent) -> Void) -> Bool { starts.append(paths); callback = changed; return succeeds }
    func stop() { stops += 1 }
    func send(_ event: CatalogEvent = .changed) { callback?(event) }
}
actor ScanGate {
    var calls = 0
    var pending: [Int: CheckedContinuation<CatalogLoad, Error>] = [:]
    func load() async throws -> CatalogLoad {
        calls += 1; let call = calls
        return try await withCheckedThrowingContinuation { pending[call] = $0 }
    }
    func finish(_ call: Int, _ value: CatalogLoad) { pending.removeValue(forKey: call)?.resume(returning: value) }
    func fail(_ call: Int) { pending.removeValue(forKey: call)?.resume(throwing: SourceError("Fixture read failure")) }
}
func waitCalls(_ gate: ScanGate, _ count: Int) async throws {
    for _ in 0..<300 {
        if await gate.calls >= count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure(description: "Scan call \(count) did not arrive")
}

@MainActor func sourceTests(_ h: Harness) async {
    await h.test("apps: localized names, alternates, canonical links, one-level nesting and removal") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Applications"), outside = dir.appendingPathComponent("Other/Real.app")
        let named = try bundleFixture(root.appendingPathComponent("Name.app"), info: ["CFBundleName": "Internal", "CFBundleDisplayName": "Display"], names: ["fr": ["CFBundleDisplayName": "Français"]])
        try bundleFixture(root.appendingPathComponent("Simple.app"), info: ["CFBundleName": "Simple Name"])
        try bundleFixture(root.appendingPathComponent("Filename.app"), info: [:])
        try bundleFixture(root.appendingPathComponent("Utilities/Nested.app"), info: ["CFBundleName": "Nested"])
        try bundleFixture(root.appendingPathComponent("Utilities/Too/Deep.app"), info: ["CFBundleName": "Deep"])
        try bundleFixture(named.appendingPathComponent("Contents/Hidden.app"), info: ["CFBundleName": "Hidden"])
        try bundleFixture(outside, info: ["CFBundleName": "Real"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias.app"), withDestinationURL: outside)
        let scan = try AppSource.scan(roots: [root, outside.deletingLastPathComponent()], additionalApps: [], languages: ["fr-CA"])
        try expect(scan.entries.count == 5, "Expected five, got \(scan.entries.count)")
        let localized = scan.entries.first { $0.item.name == "Français" }!
        try expect(Set(localized.item.alternateNames) == ["Internal", "Name"])
        try expect(scan.entries.contains { $0.item.name == "Filename" })
        try expect(scan.entries.filter { $0.item.name == "Real" }.count == 1)
        try expect(scan.watchPaths.contains(outside.resolvingSymlinksInPath().path))
        try expect(localized.target == .application(named.resolvingSymlinksInPath()))
        try FileManager.default.removeItem(at: named)
        let after = try AppSource.scan(roots: [root], additionalApps: [])
        try expect(!after.entries.contains { $0.item.id == localized.item.id })
        try expect(after.entries.count == 4)
    }
    await h.test("app cache: metadata touches, localized changes, replacement, aliases and locale changes") {
        let dir = try temporaryDirectory().resolvingSymlinksInPath(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Applications"), app = root.appendingPathComponent("Fixture.app")
        try bundleFixture(app, info: ["CFBundleName": "Original"], names: ["en": ["CFBundleName": "English"], "fr": ["CFBundleName": "Français"]])
        var cache = AppSourceCache()
        func scan(_ languages: [String] = ["fr"]) throws -> AppScan {
            try AppSource.scan(roots: [root], additionalApps: [], languages: languages, cache: &cache)
        }
        let first = try scan(), warm = try scan()
        try expect(first.metadataReads == 1 && warm.metadataReads == 0 && warm.reusedBundles == 1 && first.entries == warm.entries)
        for i in 0..<4 {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(i))], ofItemAtPath: app.path)
            var value = UInt8(i)
            try expect(setxattr(app.path, "com.apparate.fixture", &value, 1, 0, 0) == 0)
            let touched = try scan()
            try expect(touched.metadataReads == 0 && touched.reusedBundles == 1 && touched.entries == first.entries)
        }
        let strings = app.appendingPathComponent("Contents/Resources/fr.lproj/InfoPlist.strings")
        let oldDate = try FileManager.default.attributesOfItem(atPath: strings.path)[.modificationDate]!
        try writePlist(["CFBundleName": "Nouveau"], to: strings)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: strings.path)
        let edited = try scan()
        try expect(edited.metadataReads == 1 && edited.entries.first?.item.name == "Nouveau")
        let english = try scan(["en"])
        try expect(english.metadataReads == 1 && english.entries.first?.item.name == "English")
        let japaneseFallback = try scan(["ja"])
        try expect(japaneseFallback.entries.first?.item.name == "English")
        try writePlist(["CFBundleName": "日本語"], to: app.appendingPathComponent("Contents/Resources/ja.lproj/InfoPlist.strings"))
        let added = try scan(["ja"])
        try expect(added.metadataReads == 1 && added.entries.first?.item.name == "日本語")
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Resources/ja.lproj"))
        let removed = try scan(["ja"])
        try expect(removed.metadataReads == 1 && removed.entries.first?.item.name == "English")
        let plist = app.appendingPathComponent("Contents/Info.plist")
        try Data("broken".utf8).write(to: plist)
        let malformed = try scan()
        try expect(malformed.entries.isEmpty && malformed.skippedBundles == 1 && malformed.metadataReads == 1)
        try writePlist(["CFBundleName": "Recovered"], to: plist)
        let repaired = try scan()
        try expect(repaired.metadataReads == 1 && repaired.entries.first?.item.alternateNames.contains("Recovered") == true)
        // Replace the whole bundle with preserved resource attributes.
        let copy = dir.appendingPathComponent("Replacement.app")
        try FileManager.default.copyItem(at: app, to: copy)
        try FileManager.default.removeItem(at: app)
        try FileManager.default.moveItem(at: copy, to: app)
        try expect(try scan().metadataReads == 1)
        let target = try bundleFixture(dir.appendingPathComponent("Outside/Target.app"), info: ["CFBundleName": "Target"])
        try FileManager.default.removeItem(at: app)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: target)
        let linked = try scan()
        try expect(linked.metadataReads == 1 && linked.entries.first?.item.name == "Target" && linked.entries.first?.item.alternateNames == ["Fixture"])
        try expect(try scan().reusedBundles == 1)
        try FileManager.default.removeItem(at: app)
        try expect(try scan().entries.isEmpty)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: target)
        try expect(try scan().metadataReads == 1, "Removed bundles must not remain cached")
    }
    await h.test("app cache: selected localization fast path and malformed fallback dependencies") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try bundleFixture(dir.appendingPathComponent("Fixture.app"), info: ["CFBundleName": "Baseline"], names: ["fr": [:], "en": ["CFBundleName": "English"]])
        let selected = app.appendingPathComponent("Contents/Resources/fr.lproj/InfoPlist.strings")
        let other = app.appendingPathComponent("Contents/Resources/en.lproj/InfoPlist.strings")
        var cache = AppSourceCache()
        func scan() throws -> AppScan { try AppSource.scan(roots: [], additionalApps: [app], languages: ["fr"], cache: &cache) }
        let first = try scan()
        try expect(first.entries.first?.item.name == "Baseline")
        try writePlist(["CFBundleName": "Changed English"], to: other)
        let unused = try scan()
        try expect(unused.metadataReads == 0 && unused.entries == first.entries, "A valid empty selected dictionary uses Info.plist, not another translation")
        try Data("malformed".utf8).write(to: selected)
        let fallback = try scan()
        try expect(fallback.metadataReads == 1 && fallback.entries == [try AppSource.bundleEntry(at: app, languages: ["fr"])])
        try expect(try scan().reusedBundles == 1)
        try writePlist(["CFBundleName": "Another English"], to: other)
        try expect(try scan().metadataReads == 1, "Fallback must observe other localization resources")
        try writePlist(["CFBundleName": "Français"], to: selected)
        let repaired = try scan()
        try expect(repaired.metadataReads == 1 && repaired.entries.first?.item.name == "Français")
    }
    await h.test("catalog: unchanged fresh snapshots do not publish; changed targets still publish") {
        let watcher = WatcherFake(), gate = ScanGate()
        let controller = CatalogController(paths: [], watcher: watcher, loader: { try await gate.load() })
        var publications = 0; controller.onChange = { _ in publications += 1 }
        controller.start(); defer { controller.stop() }
        try await waitCalls(gate, 1); await gate.finish(1, try loadFixture("Stable"))
        try await eventually { publications == 1 }
        controller.removeMissing("absent")
        try expect(publications == 1)
        for call in 2...4 {
            watcher.send(); try await waitCalls(gate, call)
            await gate.finish(call, try loadFixture("Stable"))
            try await eventually { controller.completedScans == call }
            try expect(publications == 1)
        }
        watcher.send(); try await waitCalls(gate, 5)
        let changed = entryFixture("Stable", target: .application(URL(fileURLWithPath: "/fixture/replaced.app")))
        await gate.finish(5, try CatalogLoad(snapshot: CatalogSnapshot(entries: [changed]), watchPaths: []))
        try await eventually { publications == 2 }
        try expect(controller.snapshot?.entries[changed.item.id] == changed)
    }
    await h.test("catalog metadata churn: real directory events rescan with reuse and zero publications") {
        let dir = try temporaryDirectory().resolvingSymlinksInPath(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Applications")
        let app = try bundleFixture(root.appendingPathComponent("Fixture.app"), info: ["CFBundleName": "Before"])
        let cache = Mutex(AppSourceCache())
        let controller = CatalogController(paths: [root.path], loader: {
            try await Task.detached {
                let scan = try cache.withLock { try AppSource.scan(roots: [root], additionalApps: [], cache: &$0) }
                var metrics = CatalogMetrics(); metrics.appMetadataReads = scan.metadataReads; metrics.reusedApps = scan.reusedBundles
                return try CatalogLoad(snapshot: CatalogSnapshot(entries: scan.entries), watchPaths: scan.watchPaths, metrics: metrics)
            }.value
        })
        var publications = 0; controller.onChange = { _ in publications += 1 }
        controller.start(); defer { controller.stop() }
        try await eventually({ controller.snapshot != nil }, timeout: 6)
        try await Task.sleep(for: .milliseconds(500))
        let initialPublications = publications, reads = controller.metadataReads, trace = controller.watchDiagnostics
        for i in 0..<3 {
            let scans = controller.completedScans
            var value = UInt8(i)
            if i != 1 { try expect(setxattr(app.path, "com.apparate.fixture", &value, 1, 0, 0) == 0) }
            if i != 0 { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(i))], ofItemAtPath: app.path) }
            try await eventually({ controller.completedScans > scans }, timeout: 6)
            try expect(publications == initialPublications && controller.metadataReads == reads && controller.metrics.reusedApps == 1)
        }
        let events = controller.watchDiagnostics.since(trace)
        try expect(events.relevantEvents > 0 && events.bundleEvents + events.rootEvents > 0)
        // This trace contains counts and flags only, including for the owned fixture.
        let flags = Dictionary(uniqueKeysWithValues: events.flags.map { (String(format: "0x%08x", $0.key), $0.value) })
        let data = try JSONSerialization.data(withJSONObject: ["batches": events.batches, "events": events.events,
            "bundle_events": events.bundleEvents, "root_events": events.rootEvents, "flags": flags,
            "metadata_reads": controller.metadataReads - reads, "publications": publications - initialPublications], options: [.sortedKeys])
        print("CATALOG_TOUCH_TRACE " + String(decoding: data, as: UTF8.self))
        try bundleFixture(app, info: ["CFBundleName": "After"])
        try await eventually({ controller.snapshot?.entries.values.first?.item.name == "After" }, timeout: 6)
        try expect(publications == initialPublications + 1 && controller.metadataReads > reads)
    }
    await h.test("settings: one matched locale, English fallback, duplicate keywords and malformed records") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let info: [String: Any] = ["CFBundleIdentifier": "fixture.settings", "CFBundleName": "Pane", "EXAppExtensionAttributes": ["SettingsExtensionAttributes": ["searchTermsFileName": "Terms", "legacyPrefPaneBundleName": "Retired.prefPane"]]]
        let pane = try bundleFixture(dir.appendingPathComponent("Pane.appex"), info: info, names: ["fr": ["CFBundleDisplayName": "Réglages"]])
        try termsFixture(pane, language: "en", records: [["title": "English", "index": "one, two"], ["title": "English", "index": "two, three"], ["index": "invalid"]])
        try termsFixture(pane, language: "fr", records: [["title": "Français", "index": "mot, autre"]])
        let fr = try SettingsSource.scan(directory: dir, legacyDirectory: dir, languages: ["fr-CA"])
        try expect(Set(fr.entries.map(\.item.name)) == ["Réglages", "Français"])
        let en = try SettingsSource.scan(directory: dir, legacyDirectory: dir, languages: ["ja-JP"])
        let entry = en.entries.first { $0.item.name == "English" }!
        try expect(entry.item.keywords == ["one", "three", "two"] && en.entries.count == 2)
        try expect(en.malformedResources == 1)
        try expect(entry.target == .settings(bundle: "fixture.settings", anchor: "anchor"))
        // A selected localization with no search terms falls back to English, not all translations.
        try FileManager.default.removeItem(at: pane.appendingPathComponent("Contents/Resources/fr.lproj/Terms.searchTerms"))
        let fallback = try SettingsSource.scan(directory: dir, legacyDirectory: dir, languages: ["fr"])
        try expect(fallback.entries.contains { $0.item.name == "English" } && fallback.entries.count == 2)
        try Data("not a plist".utf8).write(to: pane.appendingPathComponent("Contents/Resources/en.lproj/Terms.searchTerms"))
        let malformed = try SettingsSource.scan(directory: dir, legacyDirectory: dir, languages: ["en"])
        try expect(malformed.entries.count == 1 && malformed.malformedResources == 1)
    }
    await h.test("settings: pane overrides and modern date/time target with legacy resources") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        for (id, name) in [("com.apple.Battery-Settings.extension", "Battery"), ("com.apple.HeadphoneSettings", "Headphones")] {
            let pane = try bundleFixture(dir.appendingPathComponent(name + ".appex"), info: ["CFBundleIdentifier": id, "CFBundleName": "Internal Name", "EXAppExtensionAttributes": ["SettingsExtensionAttributes": ["searchTermsFileName": "Terms"]]])
            try termsFixture(pane, language: "en", records: [["title": name + " option", "index": "fixture"]])
        }
        let legacy = try bundleFixture(dir.appendingPathComponent("DateAndTime.prefPane"), info: ["CFBundleIdentifier": "com.apple.preference.datetime"])
        try termsFixture(legacy, language: "en", records: [["title": "Time zone"]], file: "DateAndTimePref")
        let modernID = "com.apple.Date-Time-Settings.extension"
        let modern = try bundleFixture(dir.appendingPathComponent("DateAndTime Extension.appex"), info: ["CFBundleIdentifier": modernID, "CFBundleName": "Internal date name", "EXAppExtensionAttributes": ["SettingsExtensionAttributes": ["searchTermsFileName": "DateAndTimePref", "legacyPrefPaneBundleName": "DateAndTime.prefPane"]]], names: ["en": ["CFBundleDisplayName": "Localized Date"]])
        let scan = try SettingsSource.scan(directory: dir, legacyDirectory: dir, languages: ["en"])
        try expect(scan.entries.count == 6)
        for name in ["Battery", "Headphones"] {
            try expect(scan.entries.first { $0.item.name == name }?.icon == .file(SettingsSource.systemSettingsIcon))
        }
        try expect(scan.malformedResources == 0)
        try expect(scan.entries.first { $0.item.name == "Localized Date" }?.target == .settings(bundle: modernID, anchor: nil))
        try expect(scan.entries.first { $0.item.name == "Time zone" }?.target == .settings(bundle: modernID, anchor: "anchor"))
        try expect(!scan.entries.contains { $0.item.name == "Date & Time" || $0.item.name == "Wrong resource" })
        try expect(scan.entries.filter { $0.target == .settings(bundle: modernID, anchor: nil) }.count == 1)
        try expect(!scan.entries.contains { if case .settings(let bundle, _) = $0.target { return bundle == "com.apple.preference.datetime" }; return false })
        // Modern resources win if both exist; legacy is a resource fallback, never a second target.
        try termsFixture(modern, language: "en", records: [["title": "Modern time zone"]], file: "DateAndTimePref")
        let own = try SettingsSource.scan(directory: dir, legacyDirectory: dir, languages: ["en"])
        try expect(own.entries.first { $0.item.name == "Modern time zone" }?.target == .settings(bundle: modernID, anchor: "anchor"))
        try expect(!own.entries.contains { $0.item.name == "Time zone" } && own.entries.count == 6 && own.malformedResources == 0)

    }
    await h.test("settings cache: persisted round trip, OS/language/schema invalidation and corrupt/write-failure fallback") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let pane = try bundleFixture(dir.appendingPathComponent("Pane.appex"), info: ["CFBundleIdentifier": "fixture.pane", "CFBundleName": "Pane", "EXAppExtensionAttributes": ["SettingsExtensionAttributes": ["searchTermsFileName": "Terms", "legacyPrefPaneBundleName": ""]]])
        try termsFixture(pane, language: "en", records: [["title": "Option", "index": "one, two"]])
        var reads = 0
        let loader = { reads += 1; return try SettingsSource.scan(directory: dir, legacyDirectory: dir, languages: ["en"]) }
        let first = try SettingsCache.load(directory: dir, build: "BuildA", languages: ["en"], loader: loader)
        let second = try SettingsCache.load(directory: dir, build: "BuildA", languages: ["en"], loader: loader)
        try expect(!first.hit && second.hit && !first.writeFailed && reads == 1 && first.scan.entries == second.scan.entries)
        let os = try SettingsCache.load(directory: dir, build: "BuildB", languages: ["en"], loader: loader)
        let language = try SettingsCache.load(directory: dir, build: "BuildB", languages: ["fr", "en"], loader: loader)
        try expect(!os.hit && !language.hit && reads == 3)
        let file = dir.appendingPathComponent("settings-cache.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        document["version"] = 1 // The pre-review cache must not preserve duplicate legacy targets.
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        let version = try SettingsCache.load(directory: dir, build: "BuildB", languages: ["fr", "en"], loader: loader)
        try expect(!version.hit && reads == 4)
        try Data("broken".utf8).write(to: file)
        let repaired = try SettingsCache.load(directory: dir, build: "BuildB", languages: ["fr", "en"], loader: loader)
        try expect(!repaired.hit && !repaired.writeFailed && reads == 5)
        let unwritable = try SettingsCache.load(directory: dir.appendingPathComponent("absent"), build: "BuildA", languages: ["en"], loader: loader)
        try expect(!unwritable.hit && unwritable.writeFailed && unwritable.scan.entries.count == 2)
    }
    await h.test("catalog: watch before scan, changes mid-scan, coalescing, failed-read retention and recovery") {
        let watcher = WatcherFake(), gate = ScanGate()
        let controller = CatalogController(paths: [], watcher: watcher, loader: { try await gate.load() })
        var publications: [String] = [], errors = 0
        controller.onChange = { publications.append($0.entries.values.first!.item.name) }
        controller.onError = { _ in errors += 1 }
        controller.start(); defer { controller.stop() }
        try expect(watcher.starts.count == 1)
        try await waitCalls(gate, 1)
        for _ in 0..<10 { watcher.send() }
        await gate.finish(1, try loadFixture("Old"))
        try await waitCalls(gate, 2)
        await gate.finish(2, try loadFixture("Current"))
        try await eventually { publications == ["Current"] }
        // Let the coalescing timer settle; it must not cause a redundant completed scan.
        try await Task.sleep(for: .milliseconds(180))
        let calls = await gate.calls
        if calls > 2 { await gate.finish(3, try loadFixture("Current")) }
        try expect(calls == 2, "A settled event burst triggered a redundant scan")
        watcher.send(.rescanRequired); try await waitCalls(gate, 3); await gate.fail(3)
        try await eventually { errors == 1 }
        try expect(controller.snapshot?.entries.values.first?.item.name == "Current")
        watcher.send(.failed); try await waitCalls(gate, 4)
        try expect(watcher.starts.count == 3)
        await gate.finish(4, try loadFixture("Recovered"))
        try await eventually { publications.last == "Recovered" }
    }
    await h.test("catalog: newly discovered targets are watched before verifying scan; failed watch is visible") {
        let watcher = WatcherFake(), gate = ScanGate(); watcher.succeeds = false
        let controller = CatalogController(paths: [], watcher: watcher, loader: { try await gate.load() })
        var errors = 0; controller.onError = { _ in errors += 1 }
        controller.start(); defer { controller.stop() }
        try await waitCalls(gate, 1); await gate.finish(1, try loadFixture("First", paths: ["/fixture/target"]))
        try await waitCalls(gate, 2)
        try expect(controller.snapshot == nil && watcher.starts.last == ["/fixture/target"])
        await gate.finish(2, try loadFixture("Verified", paths: ["/fixture/target"]))
        try await eventually { controller.snapshot != nil }
        try expect(!controller.watchHealthy && errors == 2)
    }
    await h.test("missing app root: no recursive parent watch or sibling-churn scans, creation switches to FSEvents") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("Home"), root = home.appendingPathComponent("Applications")
        let sibling = home.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let watcher = AppFolderWatcher()
        let controller = CatalogController(paths: [root.path], watcher: watcher, loader: {
            try await Task.detached {
                let scan = try AppSource.scan(roots: [root], additionalApps: [])
                return try CatalogLoad(snapshot: CatalogSnapshot(entries: scan.entries), watchPaths: scan.watchPaths)
            }.value
        })
        controller.start(); defer { controller.stop() }
        try await eventually { controller.snapshot != nil }
        try expect(watcher.recursivePaths.isEmpty && watcher.creationWatchPaths.count == 1)
        let scans = controller.completedScans
        for i in 0..<40 { try Data("fixture".utf8).write(to: sibling.appendingPathComponent("cache-\(i)")) }
        // Direct sibling creation wakes only the vnode and must not launch a scan either.
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Unrelated"), withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(450))
        try expect(controller.completedScans == scans && watcher.recursivePaths.isEmpty)
        // An empty root must switch monitoring before its first app is created inside it.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await eventually({ !watcher.recursivePaths.isEmpty && watcher.creationWatchPaths.isEmpty }, timeout: 6)
        try expect(!watcher.recursivePaths.contains(home.path))
        try bundleFixture(root.appendingPathComponent("Created.app"), info: ["CFBundleName": "Created"])
        try await eventually({ controller.snapshot?.entries.values.first?.item.name == "Created" }, timeout: 6)
        try expect(controller.watchHealthy)
    }
    await h.test("FSEvents: fixture app creation, external alias target edit and removal refresh live snapshots") {
        let dir = try temporaryDirectory().resolvingSymlinksInPath(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Applications"), target = dir.appendingPathComponent("External/Tool.app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bundleFixture(target, info: ["CFBundleName": "Before"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked.app"), withDestinationURL: target)
        let controller = CatalogController(paths: [root.path], loader: {
            try await Task.detached {
                let scan = try AppSource.scan(roots: [root], additionalApps: [])
                return try CatalogLoad(snapshot: CatalogSnapshot(entries: scan.entries), watchPaths: scan.watchPaths)
            }.value
        })
        @MainActor func waitFor(_ phase: String, _ condition: () -> Bool) async throws {
            do { try await eventually(condition, timeout: 6) }
            catch { throw TestFailure(description: "FSEvents did not observe " + phase) }
        }
        controller.start(); defer { controller.stop() }
        try await waitFor("one-item snapshot") { controller.snapshot?.entries.count == 1 }
        try bundleFixture(target, info: ["CFBundleName": "After"])
        try await waitFor("external target edit") { controller.snapshot?.entries.values.contains { $0.item.name == "After" } == true }
        let added = try bundleFixture(root.appendingPathComponent("Added.app"), info: ["CFBundleName": "Added"])
        try await waitFor("new application") { controller.snapshot?.entries.count == 2 }
        try FileManager.default.removeItem(at: added)
        try await waitFor("one-item snapshot") { controller.snapshot?.entries.count == 1 }
        // Replacing a watched root must rearm against its new identity.
        try FileManager.default.moveItem(at: root, to: dir.appendingPathComponent("MovedApplications"))
        try await waitFor("root moved away") { controller.snapshot?.entries.isEmpty == true }
        try bundleFixture(root.appendingPathComponent("Replacement.app"), info: ["CFBundleName": "Replacement"])
        try await waitFor("root recreated") { controller.snapshot?.entries.values.first?.item.name == "Replacement" }
        try expect(controller.watchHealthy)
    }
}
