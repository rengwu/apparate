import Foundation
import ApparateCore
import Synchronization
import Darwin

private final class PathFixture: Sendable {
    let listings = Mutex<[String: [String]]>([
        "/": ["Applications", "Users"], "/Fixture/Home": ["Library", ".ssh", ".config", "node_modules", "note.txt", "A👩🏽‍💻e\u{301}東京"],
        "/Fixture/Home/Library": ["Application Support", "Preferences"], "/Fixture/Home/.config": ["settings.json"],
        "/Fixture/Home/node_modules": ["module.js"], "/Fixture/Home/.ssh": [],
        "/Fixture/Home/Library/Application Support": ["example.txt"], "/Fixture/Home/Library/Preferences": [],
        "/Applications": ["Example.app"], "/Applications/Example.app": ["Contents"], "/Applications/Example.app/Contents": []])
    let reads = Mutex<[String]>([])
    let onMain = Mutex(false)
    var reader: PathReading {
        PathReading(files: FileReading(metadata: { [self] path in
            onMain.withLock { $0 = $0 || Thread.isMainThread }; reads.withLock { $0.append("stat:" + path) }
            if path.hasSuffix(".app") { return FileMetadata(type: .application) }
            if listings.withLock({ $0[path] != nil }) { return FileMetadata(type: .directory) }
            if listings.withLock({ $0.values.flatMap { $0 }.contains(URL(fileURLWithPath: path).lastPathComponent) }) { return FileMetadata(type: .file) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }, children: { [self] path in
            onMain.withLock { $0 = $0 || Thread.isMainThread }; reads.withLock { $0.append("list:" + path) }
            if path == "/Fixture/Home/denied" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
            return listings.withLock { $0[path] ?? [] }
        }), canonical: { $0 == "/Fixture/Home/alias" ? "/Fixture/Home/Documents" : $0 })
    }
    @MainActor func session(access: FileAccessPolicy = fixtureAccess, usage: UsageSnapshot = UsageSnapshot()) -> LauncherSession {
        LauncherSession(config: AppConfig(), requiresFiles: true, pathReader: reader, pathHome: "/Fixture/Home", pathAccess: access, usage: { usage })
    }
}
@MainActor private func pathQuery(_ text: String, in session: LauncherSession) async throws {
    session.edit(text); try await eventually { !session.model.pending }
}
@MainActor func pathTests(_ h: Harness) async {
    await h.test("path: parsing, normalization, scope precedence and relative paths remain indexed") {
        let home = "/Fixture/Home"
        for (text, directory, filter) in [("~", home, ""), ("~/", home, ""), ("~/.ss", home, ".ss"), ("~/.config/", home + "/.config", ""),
                                            ("/app", "/", "app"), ("~/Library/App", home + "/Library", "App"), ("~/Library/../.ssh/", home + "/.ssh", "")] {
            let query = PathQuery(text, home: home)
            try expect(query?.directory == directory && query?.filter == filter, text)
        }
        for text in ["project/src", "~someone", "hello", "x ~/Library"] { try expect(PathQuery(text, home: home) == nil) }
        let fixture = PathFixture(), session = fixture.session(); defer { session.hide() }; session.show()
        for prefix in ["", "?", ".", "'"] {
            try await pathQuery(prefix + "/app", in: session)
            try expect(!session.isCatalogReady && session.model.rows.map(\.entry.item.name) == ["Applications"] && session.completion == "/Applications/")
        }
        session.edit("Library/App"); try expect(session.model.pending, "An internal slash must await indexed sources")
        session.setCatalog(try CatalogSnapshot(entries: [])); session.setFiles(FileIndexSnapshot())
        try await eventually { !session.model.pending }
        try expect(session.model.rows.first?.result.webQuery == "Library/App", "Internal slash no-match behavior changed")
    }
    await h.test("path: alphabetical listing, dot names, node_modules, Unicode, cap and matcher") {
        let fixture = PathFixture(), session = fixture.session(); defer { session.hide() }; session.show()
        try await pathQuery("~/", in: session)
        try expect(session.model.rows.map(\.entry.item.name) == ["A👩🏽‍💻e\u{301}東京", "Library", "node_modules", "note.txt"])
        try await pathQuery("~/.ss", in: session); try expect(session.completion == "~/.ssh/")
        try expect(session.model.rows.first?.entry.item.kind == .folder && session.model.rows.first?.result.highlights == [0, 1, 2], "Dot-folder name must highlight .ss")
        try await pathQuery("~/.config/", in: session); try expect(session.model.rows.map(\.entry.item.name) == ["settings.json"])
        try await pathQuery("~/東京", in: session); try expect(session.model.rows.first?.entry.item.name == "A👩🏽‍💻e\u{301}東京")
        try expect(session.model.rows.first?.result.highlights == [3, 4], "Path highlights must use name grapheme offsets")
        try await pathQuery("~/nm", in: session); try expect(session.model.rows.first?.entry.item.name == "node_modules")
        fixture.listings.withLock { $0["/Fixture/Home/Many"] = (0..<75).reversed().map { String(format: "Entry %02d", $0) } }
        try await pathQuery("~/Many/", in: session)
        try expect(session.model.rows.count == 50 && session.model.rows.first?.entry.item.name == "Entry 00" && session.model.rows.last?.entry.item.name == "Entry 49")
        try await pathQuery("~/Many/ent", in: session); try expect(session.model.rows.count == 50)
        try expect(!fixture.onMain.withLock { $0 }, "Filesystem work ran on main thread")
    }
    await h.test("path: one-directory cache, leave/show/access invalidation and catalog independence") {
        let fixture = PathFixture(), session = fixture.session(); defer { session.hide() }; session.show()
        try await pathQuery("~/Library/A", in: session)
        let before = fixture.reads.withLock { $0.count }
        try await pathQuery("~/Library/App", in: session); try await pathQuery("~/Library/Application", in: session)
        try expect(fixture.reads.withLock { $0.count } == before)
        let revision = session.model.revision
        session.setCatalog(try CatalogSnapshot(entries: [])); session.setFiles(FileIndexSnapshot())
        try expect(session.model.revision == revision && !session.model.pending)
        try await pathQuery("~/.config/", in: session); try await pathQuery("~/Library/App", in: session)
        try expect(fixture.reads.withLock { $0.filter { $0 == "list:/Fixture/Home/Library" }.count } == 2)
        session.edit(""); try await pathQuery("~/Library/App", in: session)
        session.hide(); session.show(); try await pathQuery("~/Library/App", in: session)
        session.setPathAccess(fixtureAccess); try await eventually { !session.model.pending }
        try expect(fixture.reads.withLock { $0.filter { $0 == "list:/Fixture/Home/Library" }.count } == 5)
    }
    await h.test("path: missing, unreadable, file, no matches and protected lexical/canonical gates") {
        let fixture = PathFixture()
        fixture.listings.withLock { $0["/Fixture/Home/denied"] = [] }
        let protected = "/Fixture/Home/Documents"
        let session = fixture.session(access: FileAccessPolicy(protectedPaths: [protected: .denied])); defer { session.hide() }; session.show()
        for (query, message) in [("~/missing/", "Folder not found"), ("~/denied/", "Could not read this folder"), ("~/note.txt/", "This path is not a folder"), ("~/zzzzzzzz", nil)] {
            try await pathQuery(query, in: session)
            try expect(session.model.rows.isEmpty && session.pathMessage == message, query)
        }
        fixture.reads.withLock { $0 = [] }
        for query in ["~/Documents/", "~/Library/../Documents/", "~/alias/"] {
            try await pathQuery(query, in: session)
            try expect(session.model.rows.isEmpty && session.pathMessage?.contains("Allow Access") == true)
        }
        try expect(fixture.reads.withLock { $0.isEmpty }, "Protected request reached the metadata/listing reader")
        fixture.listings.withLock { $0[protected] = ["allowed.txt"] }
        session.setPathAccess(FileAccessPolicy(protectedPaths: [protected: .allowed])); try await eventually { !session.model.pending }
        try expect(session.model.rows.first?.entry.item.name == "allowed.txt" && session.pathMessage == nil)
    }
    await h.test("path: folder completion, package leaves, action targets and IME/pending guards") {
        let fixture = PathFixture(), session = fixture.session(); defer { session.hide() }; session.show()
        var actions: [ActionRequest] = []; session.onAction = { actions.append($0) }
        try await pathQuery("?~/Library/App", in: session)
        try expect(session.completion == "~/Library/Application Support/")
        session.setComposing(true); try expect(session.completion == nil); session.setComposing(false)
        session.edit("~/Library/App"); try expect(session.completion == nil); try await eventually { !session.model.pending }
        for operation in [ActionOperation.open, .reveal, .copyPath] { session.act(operation) }
        try expect(actions.count == 3 && actions.allSatisfy { $0.entry.target.fileURL?.path == "/Fixture/Home/Library/Application Support" })
        try await pathQuery("~/note.txt", in: session); try expect(session.completion == nil && session.model.rows.first?.entry.item.kind == .file)
        try await pathQuery("/Applications/", in: session); try expect(session.completion == "/Applications/Example.app" && session.model.rows.first?.entry.item.kind == .file)
        try await pathQuery("/Applications/Example.app/", in: session); try expect(session.completion == "/Applications/Example.app/Contents/")
    }
    await h.test("path: rapid directory changes cancel stale listing, queued actions and hiding") {
        let gate = DispatchSemaphore(value: 0), entered = Mutex(false), reads = Mutex<[String]>([])
        let reader = PathReading(files: FileReading(metadata: { _ in FileMetadata(type: .directory) }, children: { path in
            reads.withLock { $0.append(path) }
            if path == "/Fixture/Slow" { entered.withLock { $0 = true }; gate.wait() }
            return ["Child"]
        }), canonical: { $0 })
        let session = LauncherSession(config: AppConfig(), pathReader: reader, pathHome: "/Fixture", pathAccess: fixtureAccess, usage: { UsageSnapshot() })
        defer { gate.signal(); session.hide() }; var actions = 0; session.onAction = { _ in actions += 1 }; session.show()
        session.edit("~/Slow/"); session.act(.open); try await eventually { entered.withLock { $0 } }
        session.edit("~/Intermediate/"); session.edit("~/Fast/"); gate.signal()
        try await eventually { !session.model.pending }
        try expect(session.model.rows.first?.entry.item.path == "/Fixture/Fast/Child" && actions == 0)
        try expect(!reads.withLock { $0.contains("/Fixture/Intermediate") })
        entered.withLock { $0 = false }; session.edit("~/Slow/"); try await eventually { entered.withLock { $0 } }
        session.hide(); gate.signal(); try await Task.sleep(for: .milliseconds(40))
        try expect(!session.model.visible && session.model.rows.first?.entry.item.path == "/Fixture/Fast/Child")
    }
    await h.test("path: real fixture links, protected aliases and no index-style exclusions") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile(dir, "folder/child.txt"); try makeFile(dir, "Documents/private.txt"); try makeFile(dir, ".config/settings.json")
        try makeFile(dir, "node_modules/module.js"); try makeFile(dir, "Library/Application Support/settings.json")
        try FileManager.default.createSymbolicLink(atPath: dir.path + "/alias", withDestinationPath: dir.path + "/folder")
        try FileManager.default.createSymbolicLink(atPath: dir.path + "/protected-link", withDestinationPath: dir.path + "/Documents")
        let session = LauncherSession(config: AppConfig(), pathReader: .restricted(to: dir.path), pathHome: dir.path,
            pathAccess: FileAccessPolicy(protectedPaths: [dir.path + "/Documents": .denied]), usage: { UsageSnapshot() })
        defer { session.hide() }; session.show()
        try await pathQuery("~/ali", in: session); try expect(session.completion == "~/alias/", "Folder link completion: \(String(describing: session.pathMessage))")
        try await pathQuery("~/alias/", in: session); try expect(session.model.rows.first?.entry.item.path == dir.path + "/alias/child.txt")
        try await pathQuery("~/protected-link/", in: session); try expect(session.pathMessage?.contains("Allow Access") == true, "Canonical protected alias escaped the access policy")
        try await pathQuery("~/", in: session); try expect(!session.model.rows.contains { ["Documents", "protected-link", ".config"].contains($0.entry.item.name) })
        try expect(session.model.rows.contains { $0.entry.item.name == "node_modules" })
        try await pathQuery("~/Library/App", in: session); try expect(session.completion == "~/Library/Application Support/")
    }
}
