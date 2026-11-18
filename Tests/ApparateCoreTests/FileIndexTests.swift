import Foundation
import ApparateCore
import ApparateFixtures
import CoreServices
import SQLite3
import Synchronization
import Darwin

func makeFile(_ directory: URL, _ path: String, _ contents: String = "fixture") throws {
    let file = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: file)
}
let fixtureAccess = FileAccessPolicy(protectedPaths: [:])
func crawlFixture(_ directory: URL, depth: Int = 10, respect: Bool = true, reader: FileReading = FileReading()) async throws -> FileCrawlResult {
    try await FileCrawler(reader: reader).crawl(folders: [.init(path: directory.path, depth: depth)], respectGitignore: respect, access: fixtureAccess)
}
@MainActor final class FixtureFileWatcher: FileWatching {
    var receive: (@MainActor @Sendable (FileWatchBatch) -> Void)?
    var starts = 0, stopped = false, healthy = true
    var uuid: String? = "fixture-device", device: Int32 = 10
    func start(paths: [String], checkpoints: [FileCheckpoint], access: FileAccessPolicy,
               receive: @escaping @MainActor @Sendable (FileWatchBatch) -> Void) -> FileWatchStart {
        starts += 1; stopped = false; self.receive = receive
        let cp = paths.map { path in FileCheckpoint(path: path, device: device, uuid: uuid, eventID: checkpoints.first { $0.path == path }?.eventID ?? 10) }
        return FileWatchStart(checkpoints: cp, rescanPaths: cp.filter { c in !checkpoints.contains { $0.path == c.path && $0.device == c.device && $0.uuid == c.uuid && c.uuid != nil } }.map(\.path), healthy: healthy)
    }
    func stop() { stopped = true; receive = nil }
    func emit(_ path: String, root: String, id: UInt64 = 11, recursive: Bool = false, rearm: Bool = false) {
        receive?(FileWatchBatch(checkpoint: FileCheckpoint(path: root, device: device, uuid: uuid, eventID: id), changes: [FileChange(path: path, recursive: recursive)], rearm: rearm))
    }
}

@MainActor final class RecordingFileWatcher: FileWatching {
    let base = FileFolderWatcher()
    var batches: [FileWatchBatch] = []
    var recursivePaths: [String] { base.recursivePaths }
    var creationWatchPaths: [String] { base.creationWatchPaths }
    func start(paths: [String], checkpoints: [FileCheckpoint], access: FileAccessPolicy, receive: @escaping @MainActor @Sendable (FileWatchBatch) -> Void) -> FileWatchStart {
        base.start(paths: paths, checkpoints: checkpoints, access: access) { [weak self] batch in self?.batches.append(batch); receive(batch) }
    }
    func stop() { base.stop() }
}

@MainActor func fileIndexTests(_ h: Harness) async {
    await h.test("files: unchanged rebuild reuses prepared chunks; real changes retain old snapshot") {
        let fixture = SyntheticFiles(count: 2_000), folders = [AppConfig.Folder(path: "/Fixture/Projects")]
        let crawler = FileCrawler(reader: fixture.reader)
        let first = try await crawler.crawl(folders: folders, respectGitignore: true, access: fixtureAccess)
        let unchanged = try await crawler.crawl(folders: folders, respectGitignore: true, access: fixtureAccess, previous: first.snapshot)
        try expect(unchanged.preparedChunks == 0 && unchanged.snapshot.count == 2_000)
        try expect(ObservationClock.digest(unchanged.snapshot.search(ParsedQuery("readme"))) == ObservationClock.digest(first.snapshot.search(ParsedQuery("readme"))))
        fixture.change.withLock { $0 = 1 }
        let changed = try await crawler.crawl(folders: folders, respectGitignore: true, access: fixtureAccess, previous: unchanged.snapshot)
        try expect(changed.preparedChunks > 0 && changed.preparedChunks < first.preparedChunks)
        try expect(changed.snapshot.count == 2_001 && changed.snapshot.search(ParsedQuery("new-entry")).count == 1)
        try expect(first.snapshot.search(ParsedQuery("new-entry")).isEmpty)
        let stable = try await crawler.crawl(folders: folders, respectGitignore: true, access: fixtureAccess, previous: changed.snapshot)
        try expect(stable.preparedChunks == 0)
    }
    await h.test("files: depth, packages, hidden flags, links and duplicate names") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile(dir, "a/b/deep.txt"); try makeFile(dir, "a/same.txt"); try makeFile(dir, "other/same.txt")
        try makeFile(dir, ".hidden/no.txt"); try makeFile(dir, "node_modules/no.txt"); try makeFile(dir, "Example.app/Contents/no.txt")
        try makeFile(dir, "flagged.txt"); try expect(chflags(dir.appendingPathComponent("flagged.txt").path, UInt32(UF_HIDDEN)) == 0)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("linked").path, withDestinationPath: dir.appendingPathComponent("a").path)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("dangling").path, withDestinationPath: dir.appendingPathComponent("absent").path)
        let scan = try await crawlFixture(dir, depth: 2)
        for name in ["a", "a/b", "a/same.txt", "other/same.txt", "Example.app", "linked", "dangling"] { try expect(scan.snapshot.contains(path: dir.appendingPathComponent(name).path), name) }
        for name in ["a/b/deep.txt", ".hidden", "node_modules", "flagged.txt", "Example.app/Contents", "linked/same.txt"] { try expect(!scan.snapshot.contains(path: dir.appendingPathComponent(name).path), name) }
        let rows = scan.snapshot.search(ParsedQuery("same")); try expect(rows.count == 2 && Set(rows.map(\.item.id)).count == 2)
        try expect(scan.snapshot.search(ParsedQuery("users/")).isEmpty)
        try expect(!scan.snapshot.search(ParsedQuery(dir.lastPathComponent + "/same")).isEmpty)
        try expect(filePresence(dir.appendingPathComponent("dangling")) == .present)
    }
    await h.test("files: independent overlapping roots, union depths and stable path IDs") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile(dir, ".gitignore", "repo/\n"); try makeFile(dir, "repo/.gitignore", "omit.txt\n")
        try makeFile(dir, "repo/src/keep.txt"); try makeFile(dir, "repo/omit.txt")
        let inner = dir.appendingPathComponent("repo")
        let both = try await FileCrawler().crawl(folders: [.init(path: dir.path, depth: 1), .init(path: inner.path, depth: 5)], respectGitignore: true, access: fixtureAccess)
        try expect(both.snapshot.count == 4)
        let path = inner.appendingPathComponent("src/keep.txt").path
        try expect(both.snapshot.contains(path: path) && !both.snapshot.contains(path: inner.appendingPathComponent("omit.txt").path))
        let before = both.snapshot.search(ParsedQuery("keep")).first!.item.id
        try expect(!both.snapshot.search(ParsedQuery(dir.lastPathComponent + "/keep")).isEmpty)
        let only = try await FileCrawler().crawl(folders: [.init(path: inner.path, depth: 5)], respectGitignore: true, access: fixtureAccess, previous: both.snapshot)
        try expect(only.snapshot.search(ParsedQuery("keep")).first?.item.id == before)
        try expect(only.snapshot.search(ParsedQuery(dir.lastPathComponent + "/keep")).isEmpty)
        try expect(both.snapshot.restricting(to: [dir.path]).count == 1)
    }
    await h.test("files: discovered apps use bundle names, app ranking and targets, deduplicate and persist") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root"), app = root.appendingPathComponent("FixtureEditor.app")
        try makeFile(app, "Contents/Info.plist", "")
        let plist: [String: Any] = ["CFBundleIdentifier": "fixture.editor", "CFBundleName": "InternalEditor", "CFBundleDisplayName": "Fixture Editor", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try makeFile(app, "Contents/Resources/fr.lproj/InfoPlist.strings", "\"CFBundleDisplayName\" = \"Éditeur Fixture\";")
        try makeFile(app, "Contents/private-name.txt"); try makeFile(root, "FixtureEditor-notes.txt")
        let listed = Mutex<[String]>([])
        let reader = FileReading(children: { path in listed.withLock { $0.append(path) }; return try FileReading.readChildren(path) },
                                 application: { path in try! AppSource.bundleEntry(at: URL(fileURLWithPath: path), languages: ["fr"]) })
        let scan = try await crawlFixture(root, reader: reader)
        try expect(scan.snapshot.applicationCount == 1 && !listed.withLock { $0.contains { $0.hasPrefix(app.path) } })
        let rows = scan.snapshot.search(ParsedQuery("FixtureEditor"))
        try expect(rows.first?.item.kind == .app && rows.first?.item.name == "Éditeur Fixture" && rows.first?.source == .alternate(0))
        try expect(!scan.snapshot.contains(path: app.appendingPathComponent("Contents/private-name.txt").path))
        let entry = try AppSource.bundleEntry(at: app, languages: ["fr"])
        let session = LauncherSession(config: AppConfig(), requiresFiles: true, usage: { UsageSnapshot() })
        var actions: [ActionRequest] = []; session.onAction = { actions.append($0) }
        session.setCatalog(try CatalogSnapshot(entries: [entry])); session.setFiles(scan.snapshot); session.show(); session.edit("FixtureEditor")
        try await eventually { !session.model.pending }
        try expect(session.model.rows.filter { $0.entry.item.id == entry.item.id }.count == 1)
        session.act(.open); try expect(actions.first?.entry.target == .application(app.resolvingSymlinksInPath().standardizedFileURL))
        let store = try FileIndexStore(directory: dir.appendingPathComponent("data"))
        try await store.save(scan, signature: "fixture-app", checkpoints: [], replacing: true)
        let loaded = try await store.load()!
        try expect(loaded.snapshot.search(ParsedQuery("InternalEditor")) == scan.snapshot.search(ParsedQuery("InternalEditor")))
        try makeFile(app, "Contents/Resources/fr.lproj/InfoPlist.strings", "\"CFBundleDisplayName\" = \"Changed Editor\";")
        let changed = try await FileCrawler(reader: reader).update(loaded.snapshot, changes: [FileChange(path: app.appendingPathComponent("Contents/Resources/fr.lproj").path)], respectGitignore: true, access: fixtureAccess)
        try expect(changed.snapshot.search(ParsedQuery("Changed")).first?.item.kind == .app)
        try expect(changed.snapshot.restricting(to: []).applicationCount == 0)
    }
    await h.test("files: moved-in trees, same-path replacement, rule removal and unchanged snapshots") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeFile(root, "keep.txt"); let original = try await crawlFixture(root)
        try makeFile(dir, "incoming/nested/arrived.txt"); try FileManager.default.moveItem(at: dir.appendingPathComponent("incoming"), to: root.appendingPathComponent("incoming"))
        var current = try await FileCrawler().update(original.snapshot, changes: [FileChange(path: root.path + "/")], respectGitignore: true, access: fixtureAccess)
        try expect(current.snapshot.contains(path: root.appendingPathComponent("incoming/nested/arrived.txt").path))
        try expect(!original.snapshot.contains(path: root.appendingPathComponent("incoming").path))
        try FileManager.default.removeItem(at: root.appendingPathComponent("incoming")); try makeFile(root, "incoming/new.txt")
        current = try await FileCrawler().update(current.snapshot, changes: [FileChange(path: root.path)], respectGitignore: true, access: fixtureAccess)
        try expect(!current.snapshot.contains(path: root.appendingPathComponent("incoming/nested/arrived.txt").path))
        try expect(current.snapshot.contains(path: root.appendingPathComponent("incoming/new.txt").path))
        try makeFile(root, ".gitignore", "incoming/\n")
        current = try await FileCrawler().update(current.snapshot, changes: [FileChange(path: root.path)], respectGitignore: true, access: fixtureAccess)
        try expect(!current.snapshot.contains(path: root.appendingPathComponent("incoming").path))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".gitignore"))
        current = try await FileCrawler().update(current.snapshot, changes: [FileChange(path: root.path)], respectGitignore: true, access: fixtureAccess)
        try expect(current.snapshot.contains(path: root.appendingPathComponent("incoming/new.txt").path))
        try FileManager.default.removeItem(at: root.appendingPathComponent("incoming"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("incoming").path, withDestinationPath: "/nonexistent-fixture")
        current = try await FileCrawler().update(current.snapshot, changes: [FileChange(path: root.path)], respectGitignore: true, access: fixtureAccess)
        try expect(current.snapshot.contains(path: root.appendingPathComponent("incoming").path) && !current.snapshot.contains(path: root.appendingPathComponent("incoming/new.txt").path))
    }
    await h.test("files: failed reads retain entries, persisted dirty work retries without new events") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root"), data = dir.appendingPathComponent("data")
        try makeFile(root, "child/keep.txt"); let initial = try await crawlFixture(root)
        let deny = Mutex(true), child = root.appendingPathComponent("child").path
        let reader = FileReading(children: { path in if path == child && deny.withLock({ $0 }) { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }; return try FileReading.readChildren(path) })
        let failed = try await FileCrawler(reader: reader).update(initial.snapshot, changes: [FileChange(path: child)], respectGitignore: true, access: fixtureAccess)
        try expect(failed.snapshot.contains(path: appendFixture(child, "keep.txt")) && failed.dirtyPaths.contains(child) && failed.snapshot.unavailableCount >= 2)
        let store = try FileIndexStore(directory: data)
        var config = AppConfig(); config.folders = [.init(path: root.path)]
        // First persist via a controller so the exact production config signature is used.
        let watcher = FixtureFileWatcher(), controller = FileIndexController(config: config, store: store, access: fixtureAccess, watcher: watcher, crawler: FileCrawler(reader: reader))
        controller.start(); try await eventually({ controller.snapshot != nil && controller.metrics.completedUpdates >= 1 }, timeout: 8); controller.stop()
        deny.withLock { $0 = false }; try makeFile(root, "child/new.txt")
        let second = FileIndexController(config: config, store: try FileIndexStore(directory: data), access: fixtureAccess, watcher: FixtureFileWatcher())
        second.start(); defer { second.stop() }
        try await eventually({ second.snapshot?.contains(path: appendFixture(child, "new.txt")) == true }, timeout: 8)
        try expect(second.metrics.loadedFromDisk)
    }
    await h.test("files: protected roots and ancestor traversal never call a blocked reader") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile(dir, "Desktop/private.txt"); try makeFile(dir, "safe.txt")
        let blocked = dir.appendingPathComponent("Desktop").path, reads = Mutex<[String]>([])
        let reader = FileReading(metadata: { path in reads.withLock { $0.append(path) }; return try FileReading.readMetadata(path) },
                                 children: { path in reads.withLock { $0.append(path) }; return try FileReading.readChildren(path) },
                                 ignoreContents: { path in reads.withLock { $0.append(path) }; return try FileReading.readIgnore(path) })
        for observation: AccessStatus? in [nil, .denied, .notFound, .error] {
            reads.withLock { $0 = [] }
            let result = try await FileCrawler(reader: reader).crawl(folders: [.init(path: dir.path), .init(path: blocked)], respectGitignore: true,
                access: FileAccessPolicy(protectedPaths: [blocked: observation]))
            try expect(!reads.withLock { $0.contains { $0 == blocked || $0.hasPrefix(blocked + "/") } })
            try expect(!result.snapshot.contains(path: appendFixture(blocked, "private.txt")))
        }
        let allowed = try await FileCrawler(reader: reader).crawl(folders: [.init(path: blocked)], respectGitignore: true, access: FileAccessPolicy(protectedPaths: [blocked: .allowed]))
        try expect(allowed.snapshot.count == 2)
    }
    await h.test("files: SQLite migration, rollback, relaunch equality and concurrent usage during staging") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root"), data = dir.appendingPathComponent("data")
        try makeFile(root, "Alpha.txt"); try makeFile(root, "nested/Beta.txt")
        let history = try UsageStore(directory: data, clock: { 100 })
        try await history.recordSuccessfulOpen(id: "file:" + root.appendingPathComponent("Alpha.txt").path)
        let store = try FileIndexStore(directory: data), scan = try await crawlFixture(root)
        let checkpoint = FileCheckpoint(path: root.path, device: 1, uuid: "fixture", eventID: 10)
        try await store.save(scan, signature: "fixture", checkpoints: [checkpoint], replacing: true)
        let loaded = try await store.load()!
        for query in ["alpha", "b", "nested/", "zzq"] { try expect(scan.snapshot.search(ParsedQuery(query)) == loaded.snapshot.search(ParsedQuery(query))) }
        try makeFile(root, "Gamma.txt")
        let changed = try await FileCrawler().update(scan.snapshot, changes: [FileChange(path: root.path)], respectGitignore: true, access: fixtureAccess)
        await store.injectActivationFailure(true)
        do { try await store.save(changed, signature: "fixture", checkpoints: [.init(path: root.path, device: 1, uuid: "fixture", eventID: 11)], replacing: false); throw TestFailure(description: "Expected rollback") }
        catch let e as TestFailure { throw e } catch { }
        let after = try await store.load()!; try expect(after.snapshot.count == loaded.snapshot.count && after.checkpoints == [checkpoint])
        do { try await store.save(changed, signature: "fixture", checkpoints: [], replacing: true); throw TestFailure(description: "Expected staged failure") }
        catch let e as TestFailure { throw e } catch { }
        let reopened = try FileIndexStore(directory: data), retained = try await reopened.load()!
        try expect(retained.snapshot.count == loaded.snapshot.count)
        await store.injectActivationFailure(false)
        async let saved: Void = store.save(changed, signature: "fixture", checkpoints: [checkpoint], replacing: true)
        try await history.recordSuccessfulOpen(id: "fixture:during-rebuild"); try await saved
        let reopenedUsage = try UsageStore(directory: data, clock: { 100 })
        let savedCounts = try await reopenedUsage.counts()
        try expect(savedCounts["fixture:during-rebuild"] == 1)
        let storeFirst = try FileIndexStore(directory: dir.appendingPathComponent("reverse"))
        _ = try await storeFirst.load(); let usageSecond = try UsageStore(directory: dir.appendingPathComponent("reverse"))
        try await usageSecond.recordSuccessfulOpen(id: "fixture:reverse")
    }
    await h.test("files: existing v1 usage migrates intact and newer schemas are rejected") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        var pointer: OpaquePointer?
        try expect(sqlite3_open(dir.appendingPathComponent("index.sqlite").path, &pointer) == SQLITE_OK)
        try expect(sqlite3_exec(pointer, "CREATE TABLE usage(item_id TEXT PRIMARY KEY,decayed_count REAL NOT NULL,last_update REAL NOT NULL); INSERT INTO usage VALUES('fixture:old',3.5,100); PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(pointer)
        _ = try FileIndexStore(directory: dir)
        let usage = try UsageStore(directory: dir, clock: { 100 }), counts = try await usage.counts()
        try near(counts["fixture:old"]!, 3.5)
        try expect(sqlite3_open(dir.appendingPathComponent("index.sqlite").path, &pointer) == SQLITE_OK)
        var statement: OpaquePointer?; sqlite3_prepare_v2(pointer, "PRAGMA user_version", -1, &statement, nil)
        try expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 2)
        sqlite3_finalize(statement)
        try expect(sqlite3_exec(pointer, "PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK); sqlite3_close(pointer)
        do { _ = try UsageStore(directory: dir); throw TestFailure(description: "Expected unknown-version rejection") }
        catch let e as TestFailure { throw e } catch { }
    }
    await h.test("files: compact top-50, Unicode highlights and usage match the existing search engine") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        var items = [SearchItem(id: "folder:" + dir.path, kind: .folder, name: dir.lastPathComponent, path: dir.path)]
        for i in 0..<180 {
            let name = ["Report", "README", "Café", "Straße", "Index", "Network"][i % 6] + "-\(i).md"
            try makeFile(dir, name)
            let path = dir.appendingPathComponent(name).path
            items.append(SearchItem(id: "file:" + path, kind: .file, name: name, path: path))
        }
        let scan = try await crawlFixture(dir), reference = try SearchIndex(items: items)
        let usage = UsageSnapshot(counts: Dictionary(uniqueKeysWithValues: items.suffix(12).map { ($0.id, 20.0) }))
        for text in ["r", "report", "readme", "cafe", "strasse", "in", "nw", "zzqq"] {
            let query = ParsedQuery("'" + text)
            try expect(scan.snapshot.search(query, usage: usage) == reference.search(query, usage: usage), "Compact search differs for \(text)")
        }
    }
    await h.test("files: scan buffers preserve restricted roots, changed kinds and reused slots") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let inner = dir.appendingPathComponent("inner")
        for i in 0..<300 { try makeFile(inner, "entry-\(i).txt") }
        let original = try await FileCrawler().crawl(folders: [.init(path: dir.path, depth: 1), .init(path: inner.path, depth: 2)], respectGitignore: true, access: fixtureAccess)
        let query = ParsedQuery("'entry")
        try expect(original.snapshot.search(query, limit: 400).count == 300)
        try expect(original.snapshot.restricting(to: [dir.path]).search(query).isEmpty)
        try expect(original.snapshot.restricting(to: [inner.path]).search(query, limit: 400).count == 300)
        let replaced = inner.appendingPathComponent("entry-0.txt")
        try FileManager.default.removeItem(at: replaced)
        try makeFile(replaced, "entry-child.txt")
        var updated = try await FileCrawler().update(original.snapshot, changes: [.init(path: inner.path)], respectGitignore: true, access: fixtureAccess)
        try expect(updated.snapshot.search(ParsedQuery("'entry-0.txt")).first?.item.kind == .folder)
        try expect(original.snapshot.search(ParsedQuery("'entry-0.txt")).first?.item.kind == .file)
        try FileManager.default.removeItem(at: inner.appendingPathComponent("entry-1.txt"))
        updated = try await FileCrawler().update(updated.snapshot, changes: [.init(path: inner.path)], respectGitignore: true, access: fixtureAccess)
        try makeFile(inner, "replacement.txt")
        updated = try await FileCrawler().update(updated.snapshot, changes: [.init(path: inner.path)], respectGitignore: true, access: fixtureAccess)
        try expect(updated.snapshot.search(ParsedQuery("'replacement")).count == 1)
        let removedPath = inner.appendingPathComponent("entry-1.txt").path
        try expect(!updated.snapshot.search(ParsedQuery("'entry-1.txt")).contains { $0.item.path == removedPath }, "Removed slot still searched")
        try expect(original.snapshot.search(ParsedQuery("'entry-1.txt")).first?.item.path == removedPath, "Old snapshot changed")
        try expect(updated.snapshot.restricting(to: [dir.path]).search(query).isEmpty)
    }
    await h.test("files: path tie order matches flat IDs across punctuation, Unicode and disjoint roots") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let parents = ["a", "a!", "a.txt", "a0", "a/nested", "café", "cafe2", "東京"]
        var items: [SearchItem] = []
        for parent in parents {
            try makeFile(dir, parent + "/Same.txt")
            let path = dir.appendingPathComponent(parent + "/Same.txt").path
            items.append(SearchItem(id: "file:" + path, kind: .file, name: "Same.txt", path: path))
        }
        let query = ParsedQuery("'same"), expected = try SearchIndex(items: items).search(query)
        let common = try await crawlFixture(dir)
        try expect(common.snapshot.search(query) == expected)
        let separate = try await FileCrawler().crawl(folders: parents.filter { $0 != "a/nested" }.map { .init(path: dir.appendingPathComponent($0).path) }, respectGitignore: true, access: fixtureAccess)
        try expect(separate.snapshot.search(query) == expected)
    }
    await h.test("files: merged ranking, usage, fallback, startup Return and explicit web readiness") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile(dir, "Terminal.txt"); try makeFile(dir, "Terminus.txt"); try makeFile(dir, "unique.txt")
        let files = try await crawlFixture(dir)
        let catalog = try CatalogSnapshot(entries: [CatalogEntry(item: fixture("Terminal", id: "app:terminal"), target: .application(URL(fileURLWithPath: "/Fixture/Terminal.app")))])
        let session = LauncherSession(config: AppConfig(), requiresFiles: true, usage: { UsageSnapshot(counts: ["file:" + dir.appendingPathComponent("Terminus.txt").path: 20]) })
        var actions: [ActionRequest] = []; session.onAction = { actions.append($0) }
        session.setCatalog(catalog); session.show(); session.edit("unique"); session.act(.open)
        try await Task.sleep(for: .milliseconds(40)); try expect(actions.isEmpty && session.model.pending)
        session.setFiles(files.snapshot); try await eventually { actions.count == 1 }
        try expect(actions[0].entry.item.name == "unique.txt")
        session.edit("term"); try await eventually { !session.model.pending }
        try expect(session.model.rows.first?.entry.item.id == "app:terminal" && session.model.rows.count == 3)
        session.edit("zzqq"); try await eventually { !session.model.pending }; try expect(session.model.rows.first?.result.webQuery == "zzqq")
        let web = LauncherSession(config: AppConfig(), requiresFiles: true, usage: { UsageSnapshot() })
        web.show(); web.edit("? immediately"); try await eventually { !web.model.pending }; try expect(web.model.rows.first?.result.webQuery == "immediately")
    }
    await h.test("files: first catalog failure completes local readiness and later recovers") {
        let session = LauncherSession(config: AppConfig(), requiresFiles: true, usage: { UsageSnapshot() })
        let watcher = WatcherFake(), gate = ScanGate()
        let catalog = CatalogController(paths: [], watcher: watcher, loader: { try await gate.load() })
        catalog.onChange = { session.setCatalog($0) }
        session.setFiles(FileIndexSnapshot()); session.show(); session.edit("lock")
        catalog.start(); defer { catalog.stop() }
        try await waitCalls(gate, 1); await gate.fail(1)
        try await eventually { !session.model.pending }
        try expect(session.model.rows.first?.entry.target == .command(.lock))
        watcher.send(); try await waitCalls(gate, 2); try await gate.finish(2, loadFixture("Recovered"))
        session.edit("recovered"); try await eventually { !session.model.pending && session.model.rows.first?.entry.item.name == "Recovered" }
    }
    await h.test("files: event flags, device UUID routing and sentinel checkpoints") {
        let cp = FileCheckpoint(path: "/Fixture/Root", device: 7, uuid: "volume-a", eventID: 90)
        func decoded(_ flags: UInt32, _ id: UInt64 = 91, _ path: String = "Fixture/Root/child") -> FileWatchBatch? {
            FileFolderWatcher.decode(root: cp.path, relative: "Fixture/Root", checkpoint: cp, paths: [path], flags: [flags], ids: [id])
        }
        try expect(decoded(UInt32(kFSEventStreamEventFlagHistoryDone), 500, "sentinel") == nil)
        let changed = decoded(UInt32(kFSEventStreamEventFlagRootChanged), 0)!
        try expect(changed.checkpoint.eventID == 90 && changed.rearm && changed.changes.first?.path == cp.path)
        let wrapped = decoded(UInt32(kFSEventStreamEventFlagEventIdsWrapped))!
        try expect(wrapped.checkpoint.uuid == nil && wrapped.checkpoint.eventID == 0)
        for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount] {
            let event = decoded(UInt32(flag))!; try expect(event.rearm && event.changes.first?.recursive == true && event.changes.first?.path == cp.path)
        }
        let subtree = decoded(UInt32(kFSEventStreamEventFlagMustScanSubDirs))!
        try expect(!subtree.rearm && subtree.changes.first?.path == "/Fixture/Root/child" && subtree.changes.first?.recursive == true)
        try expect(decoded(0, 91, "Fixture/Root/node_modules/cache") == nil)
        try expect(decoded(0, 91, "Fixture/Root/")?.changes.first?.path == cp.path)
        let volumeRoot = FileFolderWatcher.decode(root: "/", relative: "", checkpoint: cp, paths: ["folder"], flags: [0], ids: [91])!
        try expect(volumeRoot.changes.first?.path == "/folder")
        let other = FileCheckpoint(path: "/Fixture/Other", device: 8, uuid: "volume-b", eventID: 3)
        let routed = FileFolderWatcher.decode(root: other.path, relative: "Other", checkpoint: other, paths: ["Other/sub"], flags: [0], ids: [4])!
        try expect(routed.checkpoint.device == 8 && routed.checkpoint.eventID == 4 && cp.eventID == 90)
    }
    await h.test("files: changes during crawl, thousand-event coalescing and UUID recovery") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root"), data = dir.appendingPathComponent("data")
        try makeFile(root, "before.txt")
        let watcher = FixtureFileWatcher(), injected = Mutex(false)
        let reader = FileReading(children: { path in
            let names = try FileReading.readChildren(path)
            if path == root.path && injected.withLock({ value in if value { return false }; value = true; return true }) {
                try makeFile(root, "during.txt")
                Task { @MainActor in watcher.emit(root.path, root: root.path) }
            }
            return names
        })
        var config = AppConfig(); config.folders = [.init(path: root.path)]
        let controller = FileIndexController(config: config, store: try FileIndexStore(directory: data), access: fixtureAccess, watcher: watcher, crawler: FileCrawler(reader: reader))
        controller.start(); defer { controller.stop() }
        try await eventually({ controller.snapshot?.contains(path: root.appendingPathComponent("during.txt").path) == true }, timeout: 8)
        let original = controller.snapshot!, before = controller.metrics.completedUpdates
        for i in 0..<1000 { try makeFile(root, "burst/file-\(i).txt"); watcher.emit(root.path, root: root.path, id: UInt64(100 + i)) }
        try await eventually({ controller.snapshot?.count == original.count + 1001 }, timeout: 10)
        try expect(controller.metrics.completedUpdates == before + 1 && original.count < controller.snapshot!.count)
        controller.stop(); try makeFile(root, "unreported.txt")
        let changed = FixtureFileWatcher(); changed.uuid = "replaced-log"
        let second = FileIndexController(config: config, store: try FileIndexStore(directory: data), access: fixtureAccess, watcher: changed)
        second.start(); defer { second.stop() }
        try await eventually({ second.snapshot?.contains(path: root.appendingPathComponent("unreported.txt").path) == true }, timeout: 8)
        try expect(second.metrics.loadedFromDisk && second.metrics.listedDirectories > 0)
        second.stop()
        let absent = FixtureFileWatcher(); absent.uuid = nil
        let third = FileIndexController(config: config, store: try FileIndexStore(directory: data), access: fixtureAccess, watcher: absent)
        third.start(); defer { third.stop() }
        try await eventually({ third.metrics.completedScans > 0 && !third.isIndexing }, timeout: 8)
        try expect(third.metrics.listedDirectories > 0 && third.metrics.completedUpdates == 0)
        try expect(third.snapshot?.contains(path: root.appendingPathComponent("unreported.txt").path) == true)
    }
    await h.test("files: settings status observes start finish config changes and restored time") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root"), data = dir.appendingPathComponent("data")
        try makeFile(root, ".gitignore", "skip.txt\n"); try makeFile(root, "keep.txt"); try makeFile(root, "skip.txt")
        var config = AppConfig(); config.folders = [.init(path: root.path)]
        let controller = FileIndexController(config: config, store: try FileIndexStore(directory: data), access: fixtureAccess, watcher: FixtureFileWatcher())
        var states: [Bool] = []
        controller.onStatusChange = { [weak controller] in if let controller { states.append(controller.isIndexing) } }
        controller.start(); defer { controller.stop() }
        try await eventually({ controller.metrics.completedUpdates == 1 && !controller.isIndexing }, timeout: 8)
        let before = controller.snapshot!.count
        try expect(states.contains(true) && states.last == false && controller.snapshot?.lastUpdate != nil)
        config.respectGitignore = false; controller.setConfig(config)
        try expect(controller.isIndexing)
        try await eventually({ controller.metrics.completedUpdates == 2 && !controller.isIndexing }, timeout: 8)
        try expect(controller.snapshot?.count == before + 1 && states.last == false)
        let updated = controller.snapshot!.lastUpdate
        controller.stop()
        let resumed = FileIndexController(config: config, store: try FileIndexStore(directory: data), access: fixtureAccess, watcher: FixtureFileWatcher())
        resumed.start(); defer { resumed.stop() }
        try await eventually({ resumed.metrics.loadedFromDisk && !resumed.isIndexing }, timeout: 8)
        try expect(resumed.snapshot?.lastUpdate == updated)
        resumed.rebuild(); config.folders = []; resumed.setConfig(config)
        try expect(resumed.snapshot?.count == 0)
        try await eventually({ !resumed.isIndexing && resumed.snapshot?.roots.isEmpty == true }, timeout: 8)
    }
    await h.test("files: ignored-directory churn does not enumerate, save or publish") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root"), data = dir.appendingPathComponent("data")
        try makeFile(root, ".gitignore", "build/\n"); try makeFile(root, "safe.txt"); try makeFile(root, "build/cache.txt")
        var config = AppConfig(); config.folders = [.init(path: root.path)]
        let watcher = FixtureFileWatcher(), store = try FileIndexStore(directory: data)
        let controller = FileIndexController(config: config, store: store, access: fixtureAccess, watcher: watcher)
        controller.start(); defer { controller.stop() }
        try await eventually({ controller.metrics.completedUpdates == 1 }, timeout: 8)
        let before = controller.metrics, checkpoint = try await store.load()!.checkpoints
        for _ in 0..<100 { watcher.emit(root.appendingPathComponent("build").path, root: root.path, id: 42) }
        try await Task.sleep(for: .milliseconds(350))
        let afterCheckpoint = try await store.load()!.checkpoints
        try expect(controller.metrics.listedDirectories == before.listedDirectories && controller.metrics.publications == before.publications)
        try expect(controller.metrics.completedUpdates == before.completedUpdates && afterCheckpoint == checkpoint)
    }
    await h.test("files: failed stream scans once and config removal immediately hides its entries") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root"); try makeFile(root, "keep.txt")
        var config = AppConfig(); config.folders = [.init(path: root.path)]
        let failed = FixtureFileWatcher(); failed.healthy = false
        let controller = FileIndexController(config: config, store: try FileIndexStore(directory: dir.appendingPathComponent("data")), access: fixtureAccess, watcher: failed)
        controller.start(); defer { controller.stop() }
        try await eventually({ controller.metrics.completedUpdates == 1 }, timeout: 8)
        try await Task.sleep(for: .milliseconds(250)); try expect(controller.metrics.completedUpdates == 1 && !controller.watchHealthy)
        config.folders = []; controller.setConfig(config); try expect(controller.snapshot?.count == 0)
        try await eventually({ controller.snapshot?.roots.isEmpty == true }, timeout: 8)
        try expect(controller.snapshot?.count == 0)
    }
    await h.test("files: real FSEvents create rename delete replay and missing-root sibling isolation") {
        @MainActor func phase(_ name: String, _ condition: () -> Bool, timeout: Double = 8, debug: () -> String = { "" }) async throws {
            do { try await eventually(condition, timeout: timeout) }
            catch { throw TestFailure(description: "FSEvents phase: " + name + " " + debug()) }
        }
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root"), data = dir.appendingPathComponent("data")
        var config = AppConfig(); config.folders = [.init(path: root.path)]
        let watcher = RecordingFileWatcher(), controller = FileIndexController(config: config, store: try FileIndexStore(directory: data), access: fixtureAccess, watcher: watcher)
        controller.start(); defer { controller.stop() }
        try await phase("initial missing root", { controller.snapshot != nil && controller.metrics.completedUpdates > 0 }, timeout: 8)
        try expect(watcher.recursivePaths.isEmpty && !watcher.creationWatchPaths.isEmpty)
        let scans = controller.metrics.completedUpdates
        for i in 0..<40 { try makeFile(dir, "sibling/cache-\(i)") }
        try await Task.sleep(for: .milliseconds(500)); try expect(controller.metrics.completedUpdates == scans)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await phase("empty root creation", { watcher.recursivePaths.contains(root.path) }, timeout: 8)
        try makeFile(root, "first.txt")
        try await phase("file creation", { controller.snapshot?.contains(path: root.appendingPathComponent("first.txt").path) == true }, timeout: 8)
        try FileManager.default.moveItem(at: root.appendingPathComponent("first.txt"), to: root.appendingPathComponent("second.txt"))
        try await phase("rename", { controller.snapshot?.contains(path: root.appendingPathComponent("second.txt").path) == true && controller.snapshot?.contains(path: root.appendingPathComponent("first.txt").path) == false }, timeout: 8, debug: {
            let names = ["first.txt", "second.txt"].map { controller.snapshot?.contains(path: root.appendingPathComponent($0).path) == true }
            return "presence=\(names) updates=\(controller.metrics.completedUpdates) events=\(watcher.batches.map { $0.changes.map { URL(fileURLWithPath: $0.path).lastPathComponent } })"
        })
        controller.stop(); try makeFile(root, "offline.txt")
        let resumed = FileIndexController(config: config, store: try FileIndexStore(directory: data), access: fixtureAccess)
        resumed.start(); defer { resumed.stop() }
        try await phase("offline replay", { resumed.snapshot?.contains(path: root.appendingPathComponent("offline.txt").path) == true }, timeout: 10)
        try expect(resumed.metrics.loadedFromDisk)
        try FileManager.default.removeItem(at: root.appendingPathComponent("second.txt"))
        try await phase("deletion", { resumed.snapshot?.contains(path: root.appendingPathComponent("second.txt").path) == false }, timeout: 8)
        let moved = dir.appendingPathComponent("moved"); try FileManager.default.moveItem(at: root, to: moved)
        try await phase("root moved away", { resumed.snapshot?.roots.first?.status == .notFound }, timeout: 8)
        try expect(resumed.snapshot?.contains(path: root.appendingPathComponent("offline.txt").path) == true)
        try FileManager.default.moveItem(at: moved, to: root)
        try await phase("root returned", { resumed.snapshot?.roots.first?.status == .indexed }, timeout: 8)
        config.folders = []; resumed.setConfig(config); try expect(resumed.snapshot?.count == 0)
    }
}
func appendFixture(_ parent: String, _ name: String) -> String { parent + "/" + name }

@MainActor func ignoreTests(_ h: Harness) async {
    await h.test("gitignore: real Git oracle, nested rules, escapes, globstars, classes and case modes") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let rules = "*.log\n!important.log\n/root.txt\nfolder/\na/**/z\n**/cache\nend/**\nspace\\ \n\\#hash\n\\!bang\nq?.txt\n[[:digit:]][a-c].txt\nUPPER.TXT\ntrailing   \ninvalid\\\n"
        try makeFile(dir, ".gitignore", rules)
        let files = ["a.log", "important.log", "root.txt", "sub/root.txt", "a/z", "a/b/z", "sub/cache", "end/x/y", "space ", "#hash", "!bang", "q1.txt", "2b.txt", "upper.txt", "trailing", "normal", "folder/child", "sub/important.log"]
        for file in files { try makeFile(dir, file) }
        try makeFile(dir, "sub/.gitignore", "!*.log\n/root.txt\n")
        func git(_ arguments: [String], input: Data? = nil) throws -> (Int32, Data) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.currentDirectoryURL = dir
            p.arguments = ["-c", "core.excludesFile=/dev/null", "-c", "init.templateDir="] + arguments
            p.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
            let output = Pipe(), errors = Pipe(); p.standardOutput = output; p.standardError = errors
            let pipe = Pipe(); p.standardInput = pipe
            try p.run(); if let input { pipe.fileHandleForWriting.write(input) }; try pipe.fileHandleForWriting.close()
            let bytes = output.fileHandleForReading.readDataToEndOfFile(); _ = errors.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return (p.terminationStatus, bytes)
        }
        try expect(try git(["init", "--quiet"]).0 == 0)
        for ignoreCase in [false, true] {
            let input = Data((files.joined(separator: "\0") + "\0").utf8)
            let (status, data) = try git(["-c", "core.ignorecase=\(ignoreCase)", "check-ignore", "--no-index", "-z", "--stdin"], input: input)
            try expect(status == 0 || status == 1)
            let ignored = Set(String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init))
            let reader = FileReading(ignoresCase: { _ in ignoreCase })
            let scan = try await crawlFixture(dir, reader: reader)
            for file in files { try expect(scan.snapshot.contains(path: dir.appendingPathComponent(file).path) == !ignored.contains(file), "Oracle mismatch: \(file), case \(ignoreCase)") }
        }
        let off = try await crawlFixture(dir, respect: false); try expect(files.allSatisfy { off.snapshot.contains(path: dir.appendingPathComponent($0).path) })
    }
    await h.test("gitignore: linked rule files are never read and excluded parents stay excluded") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile(dir, "outside", "*.txt\n"); try makeFile(dir, "root/keep.txt")
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(".gitignore").path, withDestinationPath: dir.appendingPathComponent("outside").path)
        try expect(try FileReading.readIgnore(root.path) == nil)
        let scan = try await crawlFixture(root); try expect(scan.snapshot.contains(path: root.appendingPathComponent("keep.txt").path))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".gitignore"))
        try makeFile(root, ".gitignore", "blocked/\r\n!blocked/keep.txt\r\n"); try makeFile(root, "blocked/keep.txt")
        let excluded = try await crawlFixture(root); try expect(!excluded.snapshot.contains(path: root.appendingPathComponent("blocked/keep.txt").path))
    }
}
