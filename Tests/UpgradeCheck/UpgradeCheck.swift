import Foundation
import CryptoKit
import ApparateCore

private struct CheckFailure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message: message) }
}
/// This separate headless executable exercises the production Core stores. It is
/// never linked into Apparate, and suppresses only asynchronous watcher replay.
@MainActor private final class QuietWatcher: FileWatching {
    func start(paths: [String], checkpoints: [FileCheckpoint], access: FileAccessPolicy, shallowPaths: Set<String>,
               receive: @escaping @MainActor @Sendable (FileWatchBatch) -> Void) -> FileWatchStart { FileWatchStart() }
    func stop() {}
}
@main private struct UpgradeCheck {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        try require(arguments.count == 5 && ["seed", "check"].contains(arguments[1]), "Usage: ApparateUpgradeCheck seed|check DATA ROOT RECEIPT")
        let seed = arguments[1] == "seed", directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let root = URL(fileURLWithPath: arguments[3], isDirectory: true), receipt = URL(fileURLWithPath: arguments[4])
        try require(AppConfig.dataDirectory(environment: ["APPARATE_HOME": directory.path]).standardizedFileURL == directory.standardizedFileURL, "Data-directory override changed")
        try require(root.path.hasPrefix("/private/tmp/") || root.path.hasPrefix(FileManager.default.temporaryDirectory.path), "Owned temporary root required")
        try require(directory.path.hasPrefix("/private/tmp/") || directory.path.hasPrefix(FileManager.default.temporaryDirectory.path), "Owned temporary data required")
        let configURL = directory.appendingPathComponent("config.json")
        if seed {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
            try Data("readme".utf8).write(to: root.appendingPathComponent("README.md"))
            try Data("notes".utf8).write(to: root.appendingPathComponent("Notes/release-notes.txt"))
            try Data("hidden".utf8).write(to: root.appendingPathComponent(".secret"))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var config = AppConfig(); config.folders = [.init(path: root.path, depth: 10)]
            config.skipHiddenFiles = true; config.resultLocation = .below; config.showMenuBarIcon = false
            try JSONEncoder().encode(config).write(to: configURL)
        }
        let configBytes = try Data(contentsOf: configURL)
        let config = try ConfigStore(directory: directory); defer { config.stopWatching() }
        try require(config.errors.isEmpty && config.current.folders == [.init(path: root.path, depth: 10)], "Config load failed")
        let history = try UsageStore(directory: directory, clock: { 1_800_000_000 })
        let fileID = "file:" + root.appendingPathComponent("README.md").path
        let application = URL(fileURLWithPath: "/Fixture/Applications/Editor.app")
        if seed { try await history.recordSuccessfulOpen(id: fileID, contentType: "public.plain-text", application: application) }
        let store = try FileIndexStore(directory: directory)
        let files = FileIndexController(config: config.current, store: store, access: FileAccessPolicy(protectedPaths: [:]), watcher: QuietWatcher())
        files.start(); defer { files.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (files.snapshot == nil || files.isIndexing) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard let snapshot = files.snapshot, !files.isIndexing else { throw CheckFailure(message: "Index did not settle") }
        try require(snapshot.count == 4 && snapshot.roots.allSatisfy { $0.status == .indexed }, "Index contents differ")
        try require(!snapshot.contains(path: root.appendingPathComponent(".secret").path), "Hidden rule was lost")
        try require(files.metrics.loadedFromDisk == !seed && files.metrics.completedScans == (seed ? 1 : 0), "Unexpected full rebuild/cache miss")
        let rows = snapshot.search(ParsedQuery("read", config: config.current))
        try require(rows.map(\.item.id) == [fileID], "Search content changed")
        let counts = try await history.counts(), remembered = try await history.lastOpenWith(for: "public.plain-text")
        try require(counts == [fileID: 1] && remembered == application, "Usage/Open With history changed")
        try require(try Data(contentsOf: configURL) == configBytes, "Loading rewrote config")
        let result: [String: Any] = ["result": "Passed", "mode": arguments[1], "count": snapshot.count,
            "revision": snapshot.revision, "last_update": snapshot.lastUpdate?.timeIntervalSince1970 ?? 0,
            "config_sha256": SHA256.hash(data: configBytes).map { String(format: "%02x", $0) }.joined(),
            "loaded_from_disk": files.metrics.loadedFromDisk, "completed_scans": files.metrics.completedScans,
            "search_names": rows.map(\.item.name), "usage_count": counts[fileID]!, "open_with": remembered!.lastPathComponent,
            "skip_hidden": snapshot.skipHiddenFiles, "data_directory_override": true, "launched_app": false, "watcher": "quiet injected watcher; no event replay" ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: receipt)
    }
}
