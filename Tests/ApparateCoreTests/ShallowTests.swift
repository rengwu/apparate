import Foundation
import ApparateCore
import Synchronization
import Darwin

@MainActor private final class WatchPlan: FileWatching {
    var paths: [String] = [], shallow: Set<String> = []
    func start(paths: [String], checkpoints: [FileCheckpoint], access: FileAccessPolicy, shallowPaths: Set<String>, receive: @escaping @MainActor @Sendable (FileWatchBatch) -> Void) -> FileWatchStart {
        self.paths = paths; shallow = shallowPaths; return FileWatchStart()
    }
    func stop() {}
}
@MainActor func shallowTests(_ h: Harness) async {
    await h.test("shallow: home/root overlap, Finder-hidden children and bounded mount coverage") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let disk = dir.appendingPathComponent("Disk"), home = disk.appendingPathComponent("Users/Home"), projects = home.appendingPathComponent("Projects")
        for path in ["Library/Application Support/a.txt", ".ssh/config", "node_modules/a.txt", "Projects/Repo/src/main.swift"] { try makeFile(home, path) }
        try makeFile(disk, "usr/bin/fixture"); try makeFile(disk, "Applications/fixture.txt")
        try expect(chflags(home.path + "/Library", UInt32(UF_HIDDEN)) == 0)
        try expect(chflags(disk.path + "/usr", UInt32(UF_HIDDEN)) == 0)
        let listed = Mutex<[String]>([])
        let reader = FileReading(metadata: { path in
            var value = try FileReading.readMetadata(path)
            if path.hasPrefix(disk.path + "/usr") { value.device += 1 } // A mounted boundary, without a real mount.
            return value
        }, children: { path in listed.withLock { $0.append(path) }; return try FileReading.readChildren(path) })
        var config = AppConfig(); config.skipHiddenFiles = false
        config.folders = [.init(path: home.path, depth: 1), .init(path: disk.path, depth: 1), .init(path: projects.path, depth: 4)]
        let plan = WatchPlan(), controller = FileIndexController(config: config, store: try FileIndexStore(directory: dir.appendingPathComponent("Data")), access: fixtureAccess, watcher: plan, crawler: FileCrawler(reader: reader))
        controller.start(); defer { controller.stop() }; try await eventually({ !controller.isIndexing && controller.snapshot != nil }, timeout: 8)
        let snapshot = controller.snapshot!
        for path in [home.path + "/Library", home.path + "/.ssh", disk.path + "/usr", projects.path + "/Repo/src/main.swift"] { try expect(snapshot.contains(path: path)) }
        for path in [home.path + "/Library/Application Support", home.path + "/.ssh/config", home.path + "/node_modules", disk.path + "/usr/bin"] { try expect(!snapshot.contains(path: path)) }
        try expect(snapshot.search(ParsedQuery("projects")).filter { $0.item.path == projects.path }.count == 1)
        try expect(Set(plan.paths) == Set(config.folders.map(\.path)) && plan.shallow == [home.path, disk.path])
        try expect(!listed.withLock { $0.contains(home.path + "/Library") || $0.contains(disk.path + "/usr") })
    }
    await h.test("shallow: vnode immediate changes, deep silence, replacement and startup recheck") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Root"), data = dir.appendingPathComponent("Data")
        try makeFile(root, "Sub/deep/initial.txt")
        var config = AppConfig(); config.folders = [.init(path: root.path, depth: 1)]
        let watcher = RecordingFileWatcher(), controller = FileIndexController(config: config, store: try FileIndexStore(directory: data), access: fixtureAccess, watcher: watcher)
        controller.start(); defer { controller.stop() }; try await eventually({ !controller.isIndexing && controller.snapshot?.count == 2 }, timeout: 8)
        try expect(watcher.recursivePaths.isEmpty && watcher.shallowPaths == [root.path])
        try await Task.sleep(for: .milliseconds(250))
        let batches = watcher.batches.count, scans = controller.metrics.completedScans
        for i in 0..<150 { try makeFile(root, "Sub/deep/cache-\(i).txt") }
        try await Task.sleep(for: .milliseconds(400))
        try expect(watcher.batches.count == batches && controller.metrics.completedScans == scans, "Deep writes woke the shallow watcher")
        try makeFile(root, "new.txt")
        try await eventually({ controller.snapshot?.contains(path: root.path + "/new.txt") == true }, timeout: 8)
        try FileManager.default.moveItem(atPath: root.path + "/new.txt", toPath: root.path + "/renamed.txt")
        try await eventually({ controller.snapshot?.contains(path: root.path + "/renamed.txt") == true && controller.snapshot?.contains(path: root.path + "/new.txt") == false }, timeout: 8)
        try FileManager.default.removeItem(atPath: root.path + "/renamed.txt")
        try await eventually({ controller.snapshot?.contains(path: root.path + "/renamed.txt") == false }, timeout: 8)
        try FileManager.default.moveItem(at: root, to: dir.appendingPathComponent("Old")); try makeFile(root, "replacement.txt")
        try await eventually({ controller.snapshot?.contains(path: root.path + "/replacement.txt") == true && watcher.shallowPaths == [root.path] }, timeout: 8)
        controller.stop(); try makeFile(root, "offline.txt")
        let resumed = FileIndexController(config: config, store: try FileIndexStore(directory: data), access: fixtureAccess, watcher: watcher)
        resumed.start(); defer { resumed.stop() }
        try await eventually({ resumed.snapshot?.contains(path: root.path + "/offline.txt") == true }, timeout: 8)
        try expect(resumed.metrics.loadedFromDisk && resumed.metrics.listedDirectories > 0 && watcher.recursivePaths.isEmpty)
    }
    await h.test("shallow: missing root rearm and independently nested recursive root") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Home"), nested = root.appendingPathComponent("Projects")
        var config = AppConfig(); config.folders = [.init(path: root.path, depth: 1), .init(path: nested.path, depth: 5)]
        let watcher = RecordingFileWatcher(), controller = FileIndexController(config: config, store: try FileIndexStore(directory: dir.appendingPathComponent("Data")), access: fixtureAccess, watcher: watcher)
        controller.start(); defer { controller.stop() }; try await eventually({ !controller.isIndexing && controller.snapshot != nil }, timeout: 8)
        try expect(watcher.recursivePaths.isEmpty && !watcher.creationWatchPaths.isEmpty)
        try makeFile(nested, "Repo/initial.txt")
        try await eventually({ watcher.shallowPaths == [root.path] && watcher.recursivePaths == [nested.path] && controller.snapshot?.contains(path: nested.path + "/Repo/initial.txt") == true }, timeout: 8)
        try makeFile(nested, "Repo/new.txt")
        try await eventually({ controller.snapshot?.contains(path: nested.path + "/Repo/new.txt") == true }, timeout: 8)
        try expect(controller.snapshot?.search(ParsedQuery("projects")).filter { $0.item.path == nested.path }.count == 1)
    }
    await h.test("shallow: shorter path ranking agrees in flat compact and merged search after usage") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile(dir, "Applications/keep"); try makeFile(dir, "Project/a/applications/keep")
        let paths = [dir.path + "/Applications", dir.path + "/Project/a/applications"]
        let items = paths.map { SearchItem(id: "folder:" + $0, kind: .folder, name: URL(fileURLWithPath: $0).lastPathComponent, path: $0) }
        let flat = try SearchIndex(items: items), compact = try await crawlFixture(dir)
        for boosted in [false, true] {
            let usage = UsageSnapshot(counts: boosted ? [items[1].id: 20] : [:]), query = ParsedQuery("'applications")
            let expected = boosted ? paths.reversed().map { $0 } : paths
            try expect(flat.search(query, usage: usage).map(\.item.path) == expected)
            try expect(compact.snapshot.search(query, usage: usage).map(\.item.path) == expected)
            let session = LauncherSession(config: AppConfig(), requiresFiles: true, usage: { usage }); defer { session.hide() }
            session.setFiles(compact.snapshot)
            session.setCatalog(try CatalogSnapshot(entries: [CatalogEntry(item: items[0], target: .file(URL(fileURLWithPath: paths[0])))]))
            session.show(); session.edit("'applications"); try await eventually { !session.model.pending }
            try expect(session.model.rows.map(\.entry.item.path) == expected)
        }
    }
}
