import Foundation

public struct FileIndexMetrics: Sendable {
    public var completedUpdates = 0, publications = 0, listedDirectories = 0, preparedChunks = 0
    public var crawlMS = 0.0, diskReadMS = 0.0, prepareMS = 0.0, saveMS = 0.0
    public var loadedFromDisk = false
    public init() {}
}
@MainActor public final class FileIndexController {
    public private(set) var snapshot: FileIndexSnapshot?
    public private(set) var metrics = FileIndexMetrics()
    public private(set) var watchHealthy = false
    public var isIndexing: Bool { loading || task != nil }
    public var rootStatuses: [FileRoot] {
        folders.map { folder in
            var root = snapshot?.roots.first { $0.path == folder.path } ?? FileRoot(path: folder.path, depth: folder.depth)
            if let blocked = access.blocked(folder.path) { root.status = blocked }
            else if isIndexing { root.status = .indexing }
            else if snapshot?.roots.contains(where: { $0.path == folder.path }) != true { root.status = .unavailable }
            return root
        }
    }
    public var onChange: ((FileIndexSnapshot) -> Void)?
    public var onError: ((String) -> Void)?
    private let store: FileIndexStore
    private let watcher: any FileWatching
    private let crawler: FileCrawler
    private var folders: [AppConfig.Folder]
    private var respect: Bool
    private var access: FileAccessPolicy
    private var signature: String
    private var watchPaths: Set<String> = []
    private var checkpoints: [FileCheckpoint] = []
    private var pendingCheckpoints: [String: FileCheckpoint] = [:]
    private var dirty: Set<String> = []
    private var pending: [String: Bool] = [:]
    private var full = false, rearm = false, stopped = true, loading = false
    private var revision: UInt64 = 0
    private var task: Task<Void, Never>?, debounce: Task<Void, Never>?
    public init(config: AppConfig, store: FileIndexStore, access: FileAccessPolicy = FileAccessPolicy(),
                watcher: any FileWatching = FileFolderWatcher(), crawler: FileCrawler = FileCrawler()) {
        self.store = store; self.access = access; self.watcher = watcher; self.crawler = crawler
        folders = Self.normalized(config.folders); respect = config.respectGitignore
        signature = Self.signature(folders, respect)
    }
    isolated deinit { stop() }
    static func normalized(_ folders: [AppConfig.Folder]) -> [AppConfig.Folder] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folders.map { AppConfig.Folder(path: AppConfig.normalizedFolder($0.path, home: home), depth: $0.depth) }.sorted { $0.path < $1.path }
    }
    static func signature(_ folders: [AppConfig.Folder], _ respect: Bool) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return "file-rules-3:\(respect):" + Locale.preferredLanguages.joined(separator: ",") + ":" + String(decoding: (try? encoder.encode(folders)) ?? Data(), as: UTF8.self)
    }
    public func start() {
        guard stopped else { return }; stopped = false; loading = true; revision &+= 1
        let version = revision
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if let stored = try await self.store.load(), version == self.revision, !self.stopped, stored.signature == self.signature {
                    let access = self.access
                    let permitted = await Task.detached(priority: .utility) { stored.snapshot.applyingAccess(access) }.value
                    guard version == self.revision, !self.stopped else { return }
                    self.snapshot = permitted; self.checkpoints = stored.checkpoints; self.dirty = stored.dirtyPaths
                    self.metrics.diskReadMS = stored.readMS; self.metrics.prepareMS = stored.prepareMS; self.metrics.loadedFromDisk = true
                    self.publish(permitted)
                } else { self.full = true }
            } catch { self.full = true; self.onError?("The saved file index could not be read; it will be rebuilt.") }
            guard version == self.revision, !self.stopped else { return }
            self.loading = false; self.task = nil; self.watch()
            for path in self.dirty { self.pending[path] = true }
            if self.snapshot == nil { self.full = true }
            self.launch()
        }
    }
    public func stop() {
        stopped = true; revision &+= 1; watcher.stop(); task?.cancel(); task = nil; debounce?.cancel(); debounce = nil
    }
    public func setConfig(_ config: AppConfig) {
        let revised = Self.normalized(config.folders), signature = Self.signature(revised, config.respectGitignore)
        guard signature != self.signature else { return }
        folders = revised; respect = config.respectGitignore; self.signature = signature
        if let snapshot { publish(snapshot.restricting(to: Set(revised.map(\.path)))) }
        rebuild()
    }
    public func setAccess(_ value: FileAccessPolicy) {
        // An explicit retry also matters when a saved Allowed hint is unchanged.
        access = value; rebuild()
    }
    public func rebuild() {
        guard !stopped else { return }
        revision &+= 1; task?.cancel(); task = nil; loading = false; full = true; pending = [:]; pendingCheckpoints = [:]
        watch(); launch()
    }
    public func removeMissing(_ id: String) {
        guard id.hasPrefix("file:") || id.hasPrefix("folder:") else { return }
        let prefix = id.hasPrefix("file:") ? 5 : 7
        receive(FileWatchBatch(checkpoint: FileCheckpoint(device: 0, uuid: nil, eventID: 0), changes: [FileChange(path: parentPath(String(id.dropFirst(prefix))))]))
    }
    private func desiredWatchPaths() -> [String] {
        var paths = folders.map(\.path)
        // Descendant mount points need their own device-relative stream.
        if let snapshot {
            for chunk in snapshot.chunks { for node in chunk.nodes.compactMap({ $0 }) where node.metadata.type == .directory && node.parent >= 0 {
                if let parent = snapshot.node(node.parent), node.metadata.device != 0, node.metadata.device != parent.metadata.device {
                    if let id = parent.children.first(where: { snapshot.node($0)?.name == node.name }) { paths.append(snapshot.path(id)) }
                }
            } }
        }
        return paths
    }
    private func watch() {
        let paths = desiredWatchPaths(); watchPaths = Set(paths)
        let result = watcher.start(paths: paths, checkpoints: checkpoints, access: access) { [weak self] in self?.receive($0) }
        watchHealthy = result.healthy
        for path in result.rescanPaths { pending[path] = true }
        for checkpoint in result.checkpoints { pendingCheckpoints[checkpoint.path] = checkpoint }
        if !result.healthy { onError?("File-folder monitoring could not start; a complete scan will still be attempted."); full = true }
        rearm = false
    }
    private func receive(_ batch: FileWatchBatch) {
        guard !stopped else { return }
        for change in batch.changes { pending[change.path] = (pending[change.path] ?? false) || change.recursive }
        if !batch.checkpoint.path.isEmpty {
            var checkpoint = batch.checkpoint
            if let prior = pendingCheckpoints[checkpoint.path], prior.uuid == checkpoint.uuid { checkpoint.eventID = max(prior.eventID, checkpoint.eventID) }
            pendingCheckpoints[checkpoint.path] = checkpoint
        }
        rearm = rearm || batch.rearm
        // Bound event storms by promoting the backlog to configured-root rescans.
        if pending.count > 1024 { pending = Dictionary(uniqueKeysWithValues: folders.map { ($0.path, true) }) }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            self?.launch()
        }
    }
    private func launch() {
        guard !stopped, !loading, task == nil, full || !pending.isEmpty else { return }
        debounce?.cancel(); debounce = nil
        if rearm {
            // Keep old checkpoints until the pending rescan has been committed. Newly armed
            // boundaries are covered by that scan; later events remain in the next batch.
            for checkpoint in pendingCheckpoints.values where checkpoint.uuid == nil { checkpoints.removeAll { $0.path == checkpoint.path } }
            watch()
        }
        let changes = pending.map { FileChange(path: $0.key, recursive: $0.value) }, replace = full
        let captured = pendingCheckpoints
        var nextCheckpoints = checkpoints.filter { !captured.keys.contains($0.path) }
        nextCheckpoints.append(contentsOf: captured.values)
        pending = [:]; pendingCheckpoints = [:]; full = false
        let version = revision, prior = snapshot ?? FileIndexSnapshot(), folders = folders, respect = respect, access = access,
            crawler = crawler, signature = signature, store = store, dirty = dirty
        task = Task { [weak self] in
            let began = ContinuousClock.now
            let work = Task.detached(priority: .utility) {
                if replace { return try await crawler.crawl(folders: folders, respectGitignore: respect, access: access, previous: prior) }
                return try await crawler.update(prior, changes: changes, respectGitignore: respect, access: access, dirtyPaths: dirty)
            }
            do {
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard let self, self.revision == version, !self.stopped else { return }
                let crawlMS = durationMS(began.duration(to: .now)), saveStart = ContinuousClock.now
                if !replace && result.changedChunks.isEmpty && result.dirtyPaths == dirty {
                    // Ignored-path churn needs no database write or search publication. A
                    // restart may replay these harmless events from the older disk cursor.
                    self.checkpoints = nextCheckpoints; self.task = nil; self.launch(); return
                }
                try await store.save(result, signature: signature, checkpoints: nextCheckpoints, replacing: replace)
                guard self.revision == version, !self.stopped else { return }
                self.checkpoints = nextCheckpoints; self.dirty = result.dirtyPaths
                self.metrics.completedUpdates += 1; self.metrics.listedDirectories += result.listedDirectories
                self.metrics.preparedChunks = result.preparedChunks; self.metrics.crawlMS = crawlMS
                self.metrics.saveMS = durationMS(saveStart.duration(to: .now))
                self.publish(result.snapshot); self.task = nil
                // A full crawl can discover additional mounted devices. Rearm only when the
                // configured watch coverage changed, not on every ordinary file update.
                if replace && Set(self.desiredWatchPaths()) != self.watchPaths { self.watch() }
                self.launch()
            } catch is CancellationError { }
            catch {
                guard let self, self.revision == version, !self.stopped else { return }
                self.onError?("The file index could not be updated; its previous snapshot is retained.")
                if self.snapshot == nil { self.publish(FileIndexSnapshot()) }
                self.task = nil; self.full = true
                // No timer retry loop. The next event or explicit rebuild retries safely.
            }
        }
    }
    private func publish(_ value: FileIndexSnapshot) { snapshot = value; metrics.publications += 1; onChange?(value) }
}
