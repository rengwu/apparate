import Foundation
import ApparateCore
import ApparateFixtures
import CoreServices
import Synchronization

@MainActor func dotTests(_ h: Harness) async {
    await h.test("dots: terminal entries, ignore switch, depth and explicit dot roots") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        for name in [".config/settings.json", ".config/.nested/private.txt", ".git/objects/sentinel", "Repo/.github/workflow.yml", "node_modules/no.txt", ".env", "vite.config.js"] { try makeFile(dir, name) }
        try makeFile(dir, ".gitignore", ".env\n.config/\n")
        let reads = Mutex<[String]>([])
        let crawler = FileCrawler(reader: FileReading(children: { path in reads.withLock { $0.append(path) }; return try FileReading.readChildren(path) }))
        let folders = [AppConfig.Folder(path: dir.path)]
        let scan = try await crawler.crawl(folders: folders, respectGitignore: true, access: fixtureAccess)
        for name in [".git", ".gitignore", "Repo/.github"] { try expect(scan.snapshot.contains(path: dir.path + "/" + name), name) }
        for name in [".env", ".config", ".git/objects", "Repo/.github/workflow.yml", "node_modules"] { try expect(!scan.snapshot.contains(path: dir.path + "/" + name), name) }
        try expect(!reads.withLock { $0.contains { $0.dropFirst(dir.path.count).split(separator: "/").contains { $0.hasPrefix(".") } } })
        let unignored = try await crawler.crawl(folders: folders, respectGitignore: false, access: fixtureAccess, previous: scan.snapshot)
        try expect(unignored.snapshot.contains(path: dir.path + "/.env") && unignored.snapshot.contains(path: dir.path + "/.config"))
        let explicit = try await crawler.crawl(folders: folders + [.init(path: dir.path + "/.config")], respectGitignore: true, access: fixtureAccess)
        try expect(explicit.snapshot.contains(path: dir.path + "/.config/settings.json"))
        try expect(explicit.snapshot.contains(path: dir.path + "/.config/.nested") && !explicit.snapshot.contains(path: dir.path + "/.config/.nested/private.txt"))
        try expect(explicit.snapshot.search(ParsedQuery("settings")).count == 1)
        try expect(explicit.snapshot.restricting(to: [dir.path]).search(ParsedQuery("settings")).isEmpty)
        let shallow = try await crawler.crawl(folders: [.init(path: dir.path, depth: 1)], respectGitignore: false, access: fixtureAccess)
        try expect(shallow.snapshot.contains(path: dir.path + "/.config") && !shallow.snapshot.contains(path: dir.path + "/Repo/.github"))
    }
    await h.test("dots: compact/flat/merged visibility, prefixes, highlights and cache reload") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        for name in [".config/sentinel", "Repo/.config/sentinel", "Repo/.env", "Repo/vite.config.js", "Repo/.東京"] { try makeFile(dir, name) }
        let scan = try await crawlFixture(dir), files = scan.snapshot
        let items = ["", "Repo", ".config", "Repo/.config", "Repo/.env", "Repo/vite.config.js", "Repo/.東京"].map { suffix in
            let path = suffix.isEmpty ? dir.path : dir.path + "/" + suffix
            let kind: ItemKind = ["", "Repo", ".config", "Repo/.config"].contains(suffix) ? .folder : .file
            return SearchItem(id: (kind == .folder ? "folder:" : "file:") + path, kind: kind, name: URL(fileURLWithPath: path).lastPathComponent, path: path)
        }
        let flat = try SearchIndex(items: items), pipeline = SearchPipeline(), empty = try SearchIndex(items: [])
        for text in ["config", "'config", "'.config", "'Repo/.env", "'Repo/", ".config", "'Repo/.東京"] {
            let query = ParsedQuery(text), compact = files.search(query)
            let regular = flat.search(query, includeWebFallback: false)
            try expect(compact == regular, "Flat/compact dot mismatch: \(text)")
            let merged = pipeline.search(SearchRequest(generation: 1, index: empty, query: query, files: files, usage: UsageSnapshot()))
            if !compact.isEmpty { try expect(merged == compact, text) }
        }
        try expect(files.search(ParsedQuery("config")).allSatisfy { !$0.item.name.hasPrefix(".") })
        let rows = files.search(ParsedQuery("'.config"))
        try expect(rows.first?.item.path == dir.path + "/.config" && rows.first?.highlights == Array(0..<7))
        try expect(rows.contains { $0.item.name == "vite.config.js" })
        try expect(files.search(ParsedQuery("'Repo/")).allSatisfy { !$0.item.name.hasPrefix(".") })
        try expect(files.search(ParsedQuery(".config")).isEmpty)
        let store = try FileIndexStore(directory: dir.appendingPathComponent("Store"))
        try await store.save(scan, signature: "dot-fixture", checkpoints: [], replacing: true)
        let loaded = try await store.load()!
        try expect(loaded.snapshot.search(ParsedQuery("'.config")) == rows)
        try expect(loaded.snapshot.restricting(to: [dir.path]).search(ParsedQuery("config")) == files.search(ParsedQuery("config")))
    }
    await h.test("dots: incremental create/rename/delete, deep silence and rule-file edits") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile(dir, "normal.txt")
        let crawler = FileCrawler(); var scan = try await crawlFixture(dir)
        try makeFile(dir, ".config/sentinel"); try makeFile(dir, ".env")
        scan = try await crawler.update(scan.snapshot, changes: [.init(path: dir.path + "/.config", recursive: true), .init(path: dir.path + "/.env")], respectGitignore: true, access: fixtureAccess)
        try expect(scan.snapshot.contains(path: dir.path + "/.config") && scan.snapshot.contains(path: dir.path + "/.env"))
        try expect(!scan.snapshot.contains(path: dir.path + "/.config/sentinel"))
        let quiet = try await crawler.update(scan.snapshot, changes: [.init(path: dir.path + "/.config/deep", recursive: true)], respectGitignore: true, access: fixtureAccess)
        try expect(quiet.listedDirectories == 0 && quiet.preparedChunks == 0)
        try FileManager.default.moveItem(atPath: dir.path + "/.env", toPath: dir.path + "/.renamed")
        scan = try await crawler.update(scan.snapshot, changes: [.init(path: dir.path + "/.env"), .init(path: dir.path + "/.renamed")], respectGitignore: true, access: fixtureAccess)
        try expect(!scan.snapshot.contains(path: dir.path + "/.env") && scan.snapshot.contains(path: dir.path + "/.renamed"))
        try makeFile(dir, ".gitignore", ".renamed\n")
        scan = try await crawler.update(scan.snapshot, changes: [.init(path: dir.path + "/.gitignore")], respectGitignore: true, access: fixtureAccess)
        try expect(!scan.snapshot.contains(path: dir.path + "/.renamed"))
        try FileManager.default.removeItem(atPath: dir.path + "/.gitignore")
        scan = try await crawler.update(scan.snapshot, changes: [.init(path: dir.path + "/.gitignore")], respectGitignore: true, access: fixtureAccess)
        try expect(scan.snapshot.contains(path: dir.path + "/.renamed"))
        try FileManager.default.removeItem(atPath: dir.path + "/.config")
        scan = try await crawler.update(scan.snapshot, changes: [.init(path: dir.path + "/.config")], respectGitignore: true, access: fixtureAccess)
        try expect(!scan.snapshot.contains(path: dir.path + "/.config"))
    }
    await h.test("dots: event filtering and independent explicit-root FSEvents") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Root"), dot = root.appendingPathComponent(".config")
        try makeFile(dot, "initial.txt")
        let checkpoint = FileCheckpoint(path: root.path, device: 1, uuid: nil, eventID: 0)
        func decode(_ suffix: String) -> FileWatchBatch? {
            FileFolderWatcher.decode(root: root.path, relative: "Root", checkpoint: checkpoint, paths: ["Root/" + suffix], flags: [0], ids: [1])
        }
        try expect(decode(".config") != nil && decode(".env") != nil && decode(".gitignore") != nil)
        try expect(decode(".config/deep") == nil && decode("node_modules") == nil && decode("Repo/.git/objects") == nil)
        let watcher = FileFolderWatcher(); var arrivals: [FileWatchBatch] = []
        let start = watcher.start(paths: [root.path, dot.path], checkpoints: [], access: fixtureAccess) { arrivals.append($0) }
        defer { watcher.stop() }
        try expect(start.healthy && Set(watcher.recursivePaths) == [root.path, dot.path])
        try await Task.sleep(for: .milliseconds(250)); arrivals = []
        try makeFile(dot, "new.txt")
        try await eventually({ arrivals.contains { $0.checkpoint.path == dot.path } }, timeout: 8)
        let scan = try await FileCrawler().crawl(folders: [.init(path: root.path), .init(path: dot.path)], respectGitignore: true, access: fixtureAccess)
        try makeFile(dot, "after.txt")
        let changed = try await FileCrawler().update(scan.snapshot, changes: [.init(path: dot.path)], respectGitignore: true, access: fixtureAccess)
        try expect(changed.snapshot.contains(path: dot.path + "/after.txt"))
    }
    await h.test("dots: app basename gate, alternate matching, deduplication and persistence") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Apps"), app = root.appendingPathComponent(".Hidden.app")
        try bundleFixture(app, info: ["CFBundleName": "Visible", "CFBundleDisplayName": "Visible"])
        let scan = try await crawlFixture(root)
        let catalog = try CatalogSnapshot(entries: AppSource.scan(roots: [], additionalApps: [app]).entries)
        let pipeline = SearchPipeline()
        try expect(scan.snapshot.applicationCount == 1)
        for query in ["Visible", "Hidden"] {
            let rows = pipeline.search(SearchRequest(generation: 1, index: catalog.index, query: ParsedQuery(query), files: scan.snapshot, usage: UsageSnapshot()))
            try expect(rows.allSatisfy { $0.item.kind == .web }, "Dot app leaked: \(query)")
        }
        var config = AppConfig(); config.prefixes = [:]
        for text in [".Hidden", ".Hidden.app"] {
            let rows = pipeline.search(SearchRequest(generation: 1, index: catalog.index, query: ParsedQuery(text, config: config), files: scan.snapshot, usage: UsageSnapshot()))
            try expect(rows.count == 1 && rows[0].item.kind == .app && rows[0].item.name == "Visible")
            try expect(catalog.entries[rows[0].item.id]?.target == .application(app.resolvingSymlinksInPath()))
        }
        let store = try FileIndexStore(directory: dir.appendingPathComponent("Store"))
        try await store.save(scan, signature: "dot-app-fixture", checkpoints: [], replacing: true)
        let loaded = try await store.load()!
        try expect(loaded.snapshot.search(ParsedQuery("Visible")).isEmpty)
        try expect(loaded.snapshot.search(ParsedQuery(".Hidden.app", config: config)).first?.item.kind == .app)
    }
    await h.test("dots: deterministic measurement corpus counts and no sentinel descent") {
        let fixture = SyntheticFiles(count: 20_000, includeDots: true)
        let scan = try await FileCrawler(reader: fixture.reader).crawl(folders: [.init(path: fixture.root)], respectGitignore: true, access: fixtureAccess)
        try expect(scan.snapshot.count == 20_000 && scan.snapshot.dotEntryCount == 2950 && scan.listedDirectories == 501)
        let unignored = try await FileCrawler(reader: fixture.reader).crawl(folders: [.init(path: fixture.root)], respectGitignore: false, access: fixtureAccess)
        try expect(unignored.snapshot.count == 20_050 && unignored.snapshot.dotEntryCount == 3000)
    }
}
