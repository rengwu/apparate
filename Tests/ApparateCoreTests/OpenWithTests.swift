import Foundation
import ApparateCore
import Synchronization
import SQLite3

func openApp(_ name: String, path: String? = nil) -> CatalogEntry {
    let url = URL(fileURLWithPath: path ?? "/Fixture/\(name).app")
    return CatalogEntry(item: SearchItem(id: "app:" + url.path, kind: .app, name: name, path: url.path), target: .application(url), icon: .symbol("app"))
}
func openItem(_ name: String, folder: Bool = false) -> CatalogEntry {
    let path = "/Fixture/\(name)"
    return CatalogEntry(item: SearchItem(id: "file:" + path, kind: folder ? .folder : .file, name: name, path: path), target: .file(URL(fileURLWithPath: path)), icon: .symbol(folder ? "folder" : "doc"))
}
actor OpenGate {
    var calls = 0
    var pending: [Int: CheckedContinuation<OpenWithDiscovery, Never>] = [:]
    func read() async -> OpenWithDiscovery { calls += 1; let n = calls; return await withCheckedContinuation { pending[n] = $0 } }
    func finish(_ n: Int, _ value: OpenWithDiscovery) { pending.removeValue(forKey: n)?.resume(returning: value) }
}
@MainActor func openWithTests(_ h: Harness) async {
    await h.test("Open With: config defaults, literal key policy and round trip") {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let config = try decoder.decode(AppConfig.self, from: Data("{}".utf8))
        try expect(config.openWithKey == .openWithDefault && config.validationErrors().isEmpty)
        try expect(decoder.decode(AppConfig.self, from: encoder.encode(config)) == config)
        func key(_ code: UInt32, _ flags: UInt32) -> AppConfig.HotKey { var k = AppConfig.HotKey(); k.keyCode = code; k.modifiers = flags; return k }
        for value in [key(0,512), key(36,256), key(48,2048), key(53,4096), key(125,512), key(8,256), key(0,256), key(7,256), key(9,256), key(6,256), key(6,768), key(18,256), key(12,256), key(43,256), key(49,256), key(36,0), key(36,1)] {
            var invalid = config; invalid.openWithKey = value
            try expect(!invalid.validationErrors().isEmpty, "Accepted reserved/typing key \(value)")
        }
        for value in [key(36,512), key(76,512), key(40,2304), key(122,512)] {
            var valid = config; valid.openWithKey = value; try expect(valid.validationErrors().isEmpty)
        }
        var clash = config; clash.hotKey = .openWithDefault; try expect(!clash.validationErrors().isEmpty)
    }
    await h.test("Open With: fake Workspace workers, remembered missing app and unresolved type") {
        let app = openApp("Editor"), old = URL(fileURLWithPath: "/Fixture/Old.app"), checks = Mutex<[Bool]>([]), unknown = Mutex(false), appMissing = Mutex(true), reads = Mutex(0)
        let service = OpenWithService(lookup: { _,_ in
            checks.withLock { $0.append(!Thread.isMainThread) }
            return OpenWithDiscovery(contentType: unknown.withLock { $0 } ? nil : "public.text", claimed: [app], defaultApplication: app)
        }, application: { url in
            checks.withLock { $0.append(!Thread.isMainThread) }
            if appMissing.withLock({ $0 }) { throw SourceError("Missing app") }
            return openApp("Old", path: url.path)
        }, lastChoice: { _ in reads.withLock { $0 += 1 }; return old })
        let absent = try await service.discover(openItem("notes"), FileAccessPolicy(protectedPaths: [:]))
        try expect(absent.lastApplication == nil && absent.defaultApplication == app)
        appMissing.withLock { $0 = false }
        let present = try await service.discover(openItem("notes"), FileAccessPolicy(protectedPaths: [:]))
        try expect(present.lastApplication?.target.fileURL == old)
        unknown.withLock { $0 = true }
        let unresolved = try await service.discover(openItem("notes"), FileAccessPolicy(protectedPaths: [:]))
        try expect(unresolved.contentType == nil && unresolved.lastApplication == nil && reads.withLock { $0 } == 2)
        try expect(checks.withLock { $0.count == 5 && $0.allSatisfy { $0 } })
    }
    await h.test("Open With: protected observations precede lookup and canonical aliases cannot bypass") {
        let access = FileAccessPolicy(protectedPaths: ["/Fixture/Home/Documents": .denied]), calls = Mutex(0)
        let canonical: @Sendable (String) -> String = { path in
            calls.withLock { $0 += 1 }
            return path.replacingOccurrences(of: "/Alias", with: "/Fixture/Home/Documents")
        }
        do { try OpenWithAccess.validate(URL(fileURLWithPath: "/Fixture/Home/Documents/note"), access: access, canonical: canonical); throw TestFailure(description: "Lexical denial bypassed") }
        catch is SourceError {}
        try expect(calls.withLock { $0 } == 0)
        do { try OpenWithAccess.validate(URL(fileURLWithPath: "/Alias/note"), access: access, canonical: canonical); throw TestFailure(description: "Canonical denial bypassed") }
        catch is SourceError {}
        try OpenWithAccess.validate(URL(fileURLWithPath: "/Fixture/Home/notes"), access: access, canonical: canonical)
        try OpenWithAccess.validate(URL(fileURLWithPath: "/Alias/note"), access: FileAccessPolicy(protectedPaths: ["/Fixture/Home/Documents": .allowed]), canonical: canonical)
    }
    await h.test("Open With: groups, deduplication, literal Unicode matcher and catalog tail") {
        let last = openApp("Zeta Editor"), def = openApp("Default Editor"), alpha = openApp("Alpha Editor"), beta = openApp("Beta Editor")
        let tail = openApp("東京 Editor"), dot = openApp(".Dot Editor")
        let index = try OpenWithIndex(discovery: OpenWithDiscovery(contentType: "public.text", claimed: [beta, alpha, def, alpha], defaultApplication: def, lastApplication: last), catalog: [tail, dot, last, def])
        let rows = index.rows(query: "")
        try expect(rows.map(\.entry.item.name) == ["Zeta Editor", "Default Editor", "Alpha Editor", "Beta Editor"])
        try expect(rows.map(\.locationOverride) == ["Last used", "Default", "", ""])
        let filtered = index.rows(query: "editor").map(\.entry.item.name)
        try expect(Array(filtered.prefix(2)) == ["Zeta Editor", "Default Editor"] && Set(filtered[2..<4]) == ["Alpha Editor", "Beta Editor"] && filtered.suffix(2).contains("東京 Editor"), "Typed groups differ: \(filtered)")
        let unicode = index.rows(query: "東京"); try expect(unicode.count == 1 && unicode[0].result.highlights == [0,1])
        try expect(index.rows(query: ".dot").first?.entry.item.name == ".Dot Editor")
        try expect(index.rows(query: "?editor").isEmpty && index.rows(query: "~/").isEmpty)
        let overlap = try OpenWithIndex(discovery: OpenWithDiscovery(contentType: nil, claimed: [def], defaultApplication: def, lastApplication: def), catalog: [def])
        try expect(overlap.rows(query: "").count == 1 && overlap.rows(query: "")[0].locationOverride == "Last used")
    }
    await h.test("Open With: exact back state, filtered apps, actions and mode key guards") {
        let files = (0..<24).map { openItem(String(format: "notes-%02d.md", $0)) }, app = openApp("Editor"), tail = openApp("Other Tool")
        let session = LauncherSession(config: AppConfig(), openWith: OpenWithService { _,_ in OpenWithDiscovery(contentType: "public.text", claimed: [app]) }, usage: { UsageSnapshot() })
        session.setCatalog(try CatalogSnapshot(entries: files + [tail])); session.show(); defer { session.hide() }
        session.edit("notes"); try await eventually { !session.model.pending }; session.move(16); session.scroll(-2)
        let selected = session.model.selectedID, first = session.model.firstVisibleRow
        var actions: [ActionRequest] = []; session.onAction = { actions.append($0) }
        try expect(session.beginOpenWith()); try expect(session.isOpenWith && session.model.pending && session.model.query.isEmpty && session.model.rows.isEmpty)
        try await eventually { !session.model.pending }; try expect(session.model.rows.count == 1)
        try expect(session.completion == nil && session.placeholder.contains("notes-16"))
        session.act(.reveal); session.act(.copyPath); session.act(.open, isRepeat: true); try expect(actions.isEmpty)
        session.edit("other"); try await eventually { !session.model.pending }; session.activateVisible(1)
        try expect(actions.count == 1 && actions[0].entry.item.id == selected && actions[0].openWith?.application == tail.target.fileURL && actions[0].openWith?.contentType == "public.text")
        try expect(session.escape()); try expect(!session.isOpenWith && session.model.query == "notes" && session.model.selectedID == selected && session.model.firstVisibleRow == first)
        try expect(session.escape() && session.model.query.isEmpty && session.model.visible)
        try expect(!session.beginOpenWith())
    }
    await h.test("Open With: generation cancellation, hide and source changes on Back") {
        let gate = OpenGate(), file = openItem("notes.md"), replacement = openItem("notes-new.md"), app = openApp("Editor")
        let discovery = OpenWithDiscovery(contentType: nil, claimed: [app])
        let session = LauncherSession(config: AppConfig(), openWith: OpenWithService { _,_ in await gate.read() }, usage: { UsageSnapshot() })
        session.setCatalog(try CatalogSnapshot(entries: [file])); session.show(); session.edit("notes")
        try await eventually { !session.model.pending }; try expect(session.beginOpenWith())
        for _ in 0..<100 { if await gate.calls == 1 { break }; try await Task.sleep(for: .milliseconds(1)) }
        try expect(session.escape()); await gate.finish(1, discovery)
        try await Task.sleep(for: .milliseconds(10)); try expect(!session.isOpenWith && session.model.rows.first?.entry == file)
        try expect(session.beginOpenWith())
        for _ in 0..<100 { if await gate.calls == 2 { break }; try await Task.sleep(for: .milliseconds(1)) }
        session.hide(); await gate.finish(2, discovery); session.show(); try await Task.sleep(for: .milliseconds(10))
        try expect(!session.isOpenWith && session.model.rows.isEmpty)
        session.edit("notes"); try await eventually { !session.model.pending }; try expect(session.beginOpenWith())
        for _ in 0..<100 { if await gate.calls == 3 { break }; try await Task.sleep(for: .milliseconds(1)) }
        await gate.finish(3, discovery); try await eventually { !session.model.pending }
        session.setCatalog(try CatalogSnapshot(entries: [replacement])); try expect(session.model.pending)
        try expect(session.escape()); try await eventually { !session.model.pending }
        try expect(session.model.query == "notes" && session.model.selected?.entry == replacement)
        // The cancelled refresh may not have started; drain it only if it did.
        await gate.finish(4, discovery); session.hide()
    }
    await h.test("Open With: folder, missing discovery, pending and marked triggers") {
        let folder = openItem("Fixture Folder", folder: true), app = openApp("Finder")
        let session = LauncherSession(config: AppConfig(), openWith: OpenWithService { entry,_ in
            if entry.item.kind == .folder { return OpenWithDiscovery(contentType: "public.folder", claimed: [app]) }
            throw OpenWithLookupError("The item no longer exists.", missingID: entry.item.id)
        }, usage: { UsageSnapshot() })
        session.setCatalog(try CatalogSnapshot(entries: [folder, openItem("missing.txt"), app])); session.show(); defer { session.hide() }
        session.edit("folder"); try expect(!session.beginOpenWith()); try await eventually { !session.model.pending }
        session.setComposing(true); try expect(!session.beginOpenWith()); session.setComposing(false)
        try expect(!session.beginOpenWith(isRepeat: true)); try expect(session.beginOpenWith()); try await eventually { !session.model.pending }
        var request: ActionRequest?; session.onAction = { request = $0 }; session.act(.open)
        try expect(request?.openWith?.contentType == "public.folder")
        _ = session.escape(); session.edit("missing"); try await eventually { !session.model.pending }
        var failure: ActionFailure?; session.onOpenWithFailure = { failure = $0 }
        try expect(session.beginOpenWith()); try await eventually { failure != nil }
        try expect(failure?.missingID == openItem("missing.txt").item.id && !session.model.pending)
        _ = session.escape(); session.edit("finder"); try await eventually { !session.model.pending }; try expect(!session.beginOpenWith())
    }
    await h.test("Open With: success-only item history, chosen-app failure and unresolved type") {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try UsageStore(directory: directory), executor = ExecutorFake(), missing = Mutex<String?>(nil)
        let dispatcher = ActionDispatcher(executor: executor, presence: { url in missing.withLock { $0 == url.path } ? .missing : .present }, recordOpenWith: { try await store.recordSuccessfulOpen(id: $0, contentType: $1, application: $2) }, record: { try await store.recordSuccessfulOpen(id: $0) })
        let file = openItem("notes.md"), app = URL(fileURLWithPath: "/Fixture/Editor.app")
        let action = ActionRequest(entry: file, operation: .open, openWith: OpenWithChoice(application: app, contentType: "public.text"))
        executor.failure = true; let refused = await dispatcher.perform(action); try expect(refused != nil)
        var counts = try await store.counts(); try expect(counts.isEmpty)
        executor.failure = false; missing.withLock { $0 = app.path }
        let vanishedApp = await dispatcher.perform(action); try expect(vanishedApp?.missingID == nil && vanishedApp?.reason.contains("application") == true)
        missing.withLock { $0 = file.target.fileURL?.path }; let vanishedFile = await dispatcher.perform(action); try expect(vanishedFile?.missingID == file.item.id)
        missing.withLock { $0 = nil }; let success = await dispatcher.perform(action); try expect(success == nil)
        counts = try await store.counts(); let remembered = try await store.lastOpenWith(for: "public.text")
        try expect(counts.count == 1 && counts[file.item.id] != nil && remembered == app)
        let unknown = ActionRequest(entry: openItem("unknown"), operation: .open, openWith: OpenWithChoice(application: app, contentType: nil))
        let accepted = await dispatcher.perform(unknown); try expect(accepted == nil)
        let reopened = try UsageStore(directory: directory), persisted = try await reopened.lastOpenWith(for: "public.text")
        counts = try await reopened.counts(); try expect(persisted == app && counts.count == 2)
    }
    await h.test("Open With: additive v2 migration, bounded type history and existing file data") {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var db: OpaquePointer?; try expect(sqlite3_open(directory.appendingPathComponent("index.sqlite").path, &db) == SQLITE_OK)
        try expect(sqlite3_exec(db, "CREATE TABLE usage(item_id TEXT PRIMARY KEY,decayed_count REAL NOT NULL,last_update REAL NOT NULL); INSERT INTO usage VALUES('old',2,100); CREATE TABLE file_nodes(generation INTEGER,id INTEGER,parent INTEGER,name TEXT,kind INTEGER,details BLOB,PRIMARY KEY(generation,id)) WITHOUT ROWID; INSERT INTO file_nodes VALUES(1,0,-1,'kept',1,X'01'); PRAGMA user_version=2", nil,nil,nil) == SQLITE_OK); sqlite3_close(db)
        let clock = Mutex<Double>(100), store = try UsageStore(directory: directory, clock: { clock.withLock { $0 } }), app = URL(fileURLWithPath: "/Fixture/Editor.app")
        for n in 0..<130 { clock.withLock { $0 += 1 }; try await store.recordSuccessfulOpen(id: "new", contentType: "type.\(n)", application: app) }
        let first = try await store.lastOpenWith(for: "type.0"), second = try await store.lastOpenWith(for: "type.1"), third = try await store.lastOpenWith(for: "type.2"), counts = try await store.counts()
        try expect(first == nil && second == nil && third == app && counts["old"] != nil)
        try expect(sqlite3_open(directory.appendingPathComponent("index.sqlite").path, &db) == SQLITE_OK); defer { sqlite3_close(db) }
        var stmt: OpaquePointer?; sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM file_nodes WHERE name='kept'", -1, &stmt, nil); defer { sqlite3_finalize(stmt) }
        try expect(sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt,0) == 1)
    }
}
