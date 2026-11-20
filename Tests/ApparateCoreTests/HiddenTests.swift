import Foundation
import ApparateCore
import ApparateFixtures
import Synchronization
import Darwin

@MainActor private final class HiddenLoginFixture: LoginServicing {
    var state = LoginState.notRegistered
    func setEnabled(_ enabled: Bool) throws { state = enabled ? .enabled : .notRegistered }
}

@MainActor func hiddenTests(_ h: Harness) async {
    await h.test("hidden: default on, v1 round trips and invalid types") {
        try expect(try AppConfig().skipHiddenFiles && ConfigStore.decode(Data("{}".utf8)).skipHiddenFiles)
        for flag in [false, true] {
            var config = AppConfig(); config.skipHiddenFiles = flag
            try expect(try ConfigStore.decode(JSONEncoder().encode(config)) == config)
        }
        for value in ["null", "0", "1", "\"true\"", "[]", "{}"] {
            do { _ = try ConfigStore.decode(Data("{\"skipHiddenFiles\":\(value)}".utf8)); throw TestFailure(description: "Accepted \(value)") }
            catch is ConfigError { }
        }
    }
    await h.test("hidden: expected-value saves, external changes and write failure") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        var failWrite = false
        let store = try ConfigStore(directory: dir, writeData: { data, url in
            if failWrite { throw SourceError("Fixture disk full") }; try data.write(to: url, options: .atomic)
        }); defer { store.stopWatching() }
        let model = SettingsModel(store: store, hotkey: HotKeyRegistration(registrar: RegistrarFake()), access: FolderAccessController(directory: dir, probe: { _ in .allowed }), login: HiddenLoginFixture(), readSpotlight: { .unknown })
        var external = model.config; external.showMenuBarIcon = false
        try JSONEncoder().encode(external).write(to: store.file, options: .atomic)
        try expect(model.set(\.skipHiddenFiles, from: true, to: false) && !model.config.showMenuBarIcon)
        external = model.config; external.skipHiddenFiles = true
        try JSONEncoder().encode(external).write(to: store.file, options: .atomic)
        try expect(!model.set(\.skipHiddenFiles, from: false, to: true) && model.config.skipHiddenFiles && model.error?.contains("changed") == true)
        let saved = try Data(contentsOf: store.file); failWrite = true
        try expect(!model.set(\.skipHiddenFiles, from: true, to: false) && model.config.skipHiddenFiles)
        try expect(try Data(contentsOf: store.file) == saved)
        let broken = Data("{broken".utf8); try broken.write(to: store.file, options: .atomic); store.reload()
        try expect(!model.editable && !model.set(\.skipHiddenFiles, from: true, to: false))
        try expect(try Data(contentsOf: store.file) == broken)
    }
    await h.test("hidden: pre-metadata exclusion, Finder flag, gitignore and explicit nested roots") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        for name in [".env", ".config/settings.json", ".config/.nested/private.txt", "Repo/.env", "visible.txt", "flagged.txt", "ignored.txt", "node_modules/no.txt"] { try makeFile(dir, name) }
        try makeFile(dir, ".gitignore", "ignored.txt\n.config/\n")
        try expect(chflags(dir.appendingPathComponent("flagged.txt").path, UInt32(UF_HIDDEN)) == 0)
        let app = dir.appendingPathComponent(".Hidden.app")
        try bundleFixture(app, info: ["CFBundleName": "Visible App"])
        let reads = Mutex<[String]>([])
        let crawler = FileCrawler(reader: FileReading(metadata: { path in reads.withLock { $0.append(path) }; return try FileReading.readMetadata(path) }))
        let outer = AppConfig.Folder(path: dir.path), dot = AppConfig.Folder(path: dir.path + "/.config"), nested = AppConfig.Folder(path: dir.path + "/.config/.nested")
        let scan = try await crawler.crawl(folders: [outer], respectGitignore: true, skipHiddenFiles: true, access: fixtureAccess)
        try expect(scan.snapshot.count == 4 && scan.snapshot.applicationCount == 0 && scan.snapshot.dotEntryCount == 0)
        try expect(scan.snapshot.contains(path: dir.path + "/flagged.txt") && scan.snapshot.search(ParsedQuery("'.env")).isEmpty)
        try expect(!reads.withLock { $0.contains { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".") } }, "Skipped entries were statted")
        let explicit = try await crawler.crawl(folders: [outer, dot, nested], respectGitignore: true, skipHiddenFiles: true, access: fixtureAccess)
        for name in [".config", ".config/settings.json", ".config/.nested", ".config/.nested/private.txt"] { try expect(explicit.snapshot.contains(path: dir.path + "/" + name), name) }
        try expect(explicit.snapshot.dotEntryCount == 2 && explicit.snapshot.search(ParsedQuery("'.config")).first?.item.path == dot.path)
        try expect(explicit.snapshot.search(ParsedQuery("config")).isEmpty)
        let removed = explicit.snapshot.restricting(to: [dir.path])
        try expect(removed.dotEntryCount == 0 && removed.search(ParsedQuery("private")).isEmpty)
        let rebuilt = try await crawler.crawl(folders: [outer], respectGitignore: false, skipHiddenFiles: true, access: fixtureAccess, previous: removed)
        try expect(rebuilt.snapshot.count == 5 && rebuilt.snapshot.contains(path: dir.path + "/ignored.txt"))
    }
    await h.test("hidden: policy changes remove stale dots even on failed listings and cache reload") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Root")
        for name in [".env", ".config/settings.txt", "keep.txt"] { try makeFile(root, name) }
        try bundleFixture(root.appendingPathComponent(".Hidden.app"), info: ["CFBundleName": "Visible App"])
        let folders = [AppConfig.Folder(path: root.path), .init(path: root.path + "/.config")]
        let old = try await FileCrawler().crawl(folders: folders, respectGitignore: false, access: fixtureAccess)
        let pending = old.snapshot.restricting(to: Set(folders.map(\.path)), skipHiddenFiles: true)
        try expect(pending.count == 4 && pending.applicationCount == 0 && pending.dotEntryCount == 1, "Pending counts: \(pending.count), \(pending.applicationCount), \(pending.dotEntryCount)")
        try expect(pending.search(ParsedQuery("'.env")).isEmpty)
        let deny = FileCrawler(reader: FileReading(children: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }))
        let failed = try await deny.crawl(folders: folders, respectGitignore: false, skipHiddenFiles: true, access: fixtureAccess, previous: pending)
        try expect(failed.snapshot.count == 4 && failed.snapshot.applicationCount == 0 && failed.snapshot.dotEntryCount == 1, "Failed counts: \(failed.snapshot.count), \(failed.snapshot.applicationCount), \(failed.snapshot.dotEntryCount)")
        try expect(failed.snapshot.contains(path: root.path + "/.config/settings.txt") && failed.dirtyPaths.count == 2, "Failed-listing entries/dirty roots")
        let store = try FileIndexStore(directory: dir.appendingPathComponent("Store"))
        try await store.save(failed, signature: "hidden-fixture", checkpoints: [], replacing: true)
        let loaded = try await store.load()!
        try expect(loaded.snapshot.skipHiddenFiles && loaded.snapshot.count == 4 && loaded.snapshot.dotEntryCount == 1, "Reload counts")
        try expect(loaded.snapshot.search(ParsedQuery("'.config")) == failed.snapshot.search(ParsedQuery("'.config")))
        // Changed roots use the copy-previous fallback, not the shared builder.
        let unavailable = FileCrawler(reader: FileReading(metadata: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }))
        let changed = try await unavailable.crawl(folders: [folders[0]], respectGitignore: false, skipHiddenFiles: true, access: fixtureAccess, previous: old.snapshot)
        try expect(changed.snapshot.count == 2 && changed.snapshot.dotEntryCount == 0 && changed.snapshot.applicationCount == 0, "Changed roots: \(changed.snapshot.count), \(changed.snapshot.dotEntryCount), \(changed.snapshot.applicationCount)")
        try await store.save(changed, signature: "hidden-changed-root", checkpoints: [], replacing: true)
        let changedReload = try await store.load()!
        try expect(changedReload.snapshot.count == 2)
    }
    await h.test("hidden: incremental renames, dot apps, ignored churn and rule-file edits") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile(dir, "normal.txt"); try makeFile(dir, "keep.txt")
        let crawler = FileCrawler()
        var scan = try await crawler.crawl(folders: [.init(path: dir.path)], respectGitignore: true, skipHiddenFiles: true, access: fixtureAccess)
        try makeFile(dir, ".config/sentinel"); try makeFile(dir, ".env")
        try bundleFixture(dir.appendingPathComponent(".Hidden.app"), info: ["CFBundleName": "Visible App"])
        let hidden = try await crawler.update(scan.snapshot, changes: [.init(path: dir.path + "/.config", recursive: true), .init(path: dir.path + "/.env"), .init(path: dir.path + "/.Hidden.app")], respectGitignore: true, access: fixtureAccess)
        try expect(hidden.snapshot.count == scan.snapshot.count && hidden.snapshot.dotEntryCount == 0, "Hidden churn: \(hidden.snapshot.count), \(hidden.snapshot.dotEntryCount)")
        // Creating an entry changes parent metadata; replaying it must be quiet.
        let replay = try await crawler.update(hidden.snapshot, changes: [.init(path: dir.path + "/.env")], respectGitignore: true, access: fixtureAccess)
        try expect(replay.preparedChunks == 0)
        try FileManager.default.moveItem(atPath: dir.path + "/normal.txt", toPath: dir.path + "/.renamed")
        scan = try await crawler.update(hidden.snapshot, changes: [.init(path: dir.path)], respectGitignore: true, access: fixtureAccess)
        try expect(scan.snapshot.count == 2 && !scan.snapshot.contains(path: dir.path + "/.renamed"))
        try FileManager.default.moveItem(atPath: dir.path + "/.renamed", toPath: dir.path + "/normal.txt")
        scan = try await crawler.update(scan.snapshot, changes: [.init(path: dir.path)], respectGitignore: true, access: fixtureAccess)
        try expect(scan.snapshot.count == 3)
        try makeFile(dir, ".gitignore", "normal.txt\n")
        scan = try await crawler.update(scan.snapshot, changes: [.init(path: dir.path + "/.gitignore")], respectGitignore: true, access: fixtureAccess)
        try expect(scan.snapshot.count == 2 && !scan.snapshot.contains(path: dir.path + "/normal.txt") && !scan.snapshot.contains(path: dir.path + "/.gitignore"))
        try FileManager.default.removeItem(atPath: dir.path + "/.gitignore")
        scan = try await crawler.update(scan.snapshot, changes: [.init(path: dir.path + "/.gitignore")], respectGitignore: true, access: fixtureAccess)
        try expect(scan.snapshot.count == 3)
        let off = try await crawler.update(scan.snapshot, changes: [], respectGitignore: true, skipHiddenFiles: false, access: fixtureAccess)
        try expect(off.snapshot.dotEntryCount == 3 && off.snapshot.applicationCount == 1, "Off counts: \(off.snapshot.dotEntryCount), \(off.snapshot.applicationCount)")
    }
    await h.test("hidden: rule-5 migration and toggles rebuild once; matching caches and unchanged settings do not") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Root"), data = dir.appendingPathComponent("Store")
        try makeFile(root, ".env"); try makeFile(root, "visible.txt")
        try bundleFixture(root.appendingPathComponent(".Hidden.app"), info: ["CFBundleName": "Visible App"])
        var config = try ConfigStore.decode(Data("{}".utf8)); config.folders = [.init(path: root.path)]
        let store = try FileIndexStore(directory: data), encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let signature = "file-rules-5:true:" + Locale.preferredLanguages.joined(separator: ",") + ":" + String(decoding: try encoder.encode(config.folders), as: UTF8.self)
        let old = try await crawlFixture(root)
        try await store.save(old, signature: signature, checkpoints: [], replacing: true)
        let watcher = FixtureFileWatcher(), controller = FileIndexController(config: config, store: store, access: fixtureAccess, watcher: watcher)
        controller.start(); defer { controller.stop() }
        try await eventually { !controller.isIndexing && controller.snapshot != nil }
        try expect(controller.metrics.completedScans == 1 && !controller.metrics.loadedFromDisk && controller.snapshot?.count == 2)
        controller.setConfig(config); try await Task.sleep(for: .milliseconds(150))
        try expect(controller.metrics.completedScans == 1)
        config.skipHiddenFiles = false; controller.setConfig(config)
        try await eventually { !controller.isIndexing }
        try expect(controller.metrics.completedScans == 2 && controller.snapshot?.count == 4 && controller.snapshot?.applicationCount == 1)
        config.skipHiddenFiles = true; controller.setConfig(config)
        try expect(controller.isIndexing && controller.snapshot?.count == 2 && controller.snapshot?.applicationCount == 0 && controller.snapshot?.search(ParsedQuery("'.env")).isEmpty == true)
        try await eventually { !controller.isIndexing }
        try expect(controller.metrics.completedScans == 3 && controller.snapshot?.count == 2)
        // Superseded queued builds cannot publish a different policy.
        config.skipHiddenFiles = false; controller.setConfig(config)
        config.skipHiddenFiles = true; controller.setConfig(config)
        try await eventually { !controller.isIndexing }
        try expect(controller.metrics.completedScans == 4 && controller.snapshot?.count == 2)
        let before = controller.metrics
        watcher.emit(root.path + "/.env", root: root.path)
        try await eventually { controller.metrics.completedScans == before.completedScans + 1 }
        try expect(controller.metrics.publications == before.publications && controller.metrics.completedUpdates == before.completedUpdates)
        controller.stop()
        let restart = FileIndexController(config: config, store: try FileIndexStore(directory: data), access: fixtureAccess, watcher: FixtureFileWatcher())
        restart.start(); defer { restart.stop() }
        try await eventually { !restart.isIndexing && restart.snapshot != nil }
        try expect(restart.metrics.loadedFromDisk && restart.metrics.completedScans == 0 && restart.snapshot?.count == 2 && restart.snapshot?.skipHiddenFiles == true)
    }
    await h.test("hidden: real explicit dot-root events still index ordinary children") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Root"), dot = root.appendingPathComponent(".config")
        try makeFile(dot, "initial.txt")
        var config = AppConfig(); config.folders = [.init(path: root.path), .init(path: dot.path)]
        let watcher = RecordingFileWatcher(), controller = FileIndexController(config: config, store: try FileIndexStore(directory: dir.appendingPathComponent("Store")), access: fixtureAccess, watcher: watcher)
        controller.start(); defer { controller.stop() }
        try await eventually({ !controller.isIndexing && controller.snapshot?.contains(path: dot.path + "/initial.txt") == true }, timeout: 8)
        try expect(Set(watcher.recursivePaths) == [root.path, dot.path])
        try makeFile(dot, "new.txt"); try makeFile(dot, ".secret")
        try await eventually({ controller.snapshot?.contains(path: dot.path + "/new.txt") == true }, timeout: 8)
        try expect(controller.snapshot?.dotEntryCount == 1 && controller.snapshot?.contains(path: dot.path + "/.secret") == false)
        try makeFile(dot, ".gitignore", "new.txt\n")
        try await eventually({ controller.snapshot?.contains(path: dot.path + "/new.txt") == false }, timeout: 8)
        try expect(controller.snapshot?.contains(path: dot.path + "/.gitignore") == false)
    }
    await h.test("hidden: off preserves section-6 digests; typed paths retain their dot filter") {
        let fixture = SyntheticFiles(count: 20_000, includeDots: true), crawler = FileCrawler(reader: fixture.reader)
        let folders = [AppConfig.Folder(path: fixture.root)]
        let legacy = try await crawler.crawl(folders: folders, respectGitignore: true, access: fixtureAccess)
        let off = try await crawler.crawl(folders: folders, respectGitignore: true, skipHiddenFiles: false, access: fixtureAccess)
        try expect(off.snapshot.count == 20_000 && off.snapshot.dotEntryCount == 2950 && off.listedDirectories == 501)
        for text in ["readme", "'readme", "'.env", "'.config", "'Project-0001/.env", "'Project-0001/"] {
            try expect(off.snapshot.search(ParsedQuery(text)) == legacy.snapshot.search(ParsedQuery(text)), text)
        }
        let on = try await crawler.crawl(folders: folders, respectGitignore: true, skipHiddenFiles: true, access: fixtureAccess)
        try expect(on.snapshot.count == 17_050 && on.snapshot.dotEntryCount == 0 && on.listedDirectories == 501)
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile(dir, ".config/visible.txt"); try makeFile(dir, ".config/.env")
        let paths = PathSearchCoordinator(reader: .restricted(to: dir.path))
        for flag in [false, true] {
            var config = AppConfig(); config.skipHiddenFiles = flag
            for (query, expected) in [("~/.config", [".config"]), ("~/.config/", ["visible.txt"]), ("~/.config/.env", [".env"])] {
                var response: PathSearchResponse?
                paths.invalidate(clear: true)
                paths.submit(PathQuery(ParsedQuery(query, config: config).text, home: dir.path)!, access: fixtureAccess, usage: UsageSnapshot()) { response = $0 }
                try await eventually { response != nil }
                try expect(response!.rows.map { $0.result.item.name } == expected, query)
            }
        }
    }
}
