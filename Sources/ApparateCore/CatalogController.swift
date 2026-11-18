import Foundation
import CoreServices

public struct CatalogMetrics: Sendable {
    public var appCount = 0, settingsCount = 0, skippedApps = 0, malformedSettings = 0
    public var appScanMS = 0.0, settingsLoadMS = 0.0, prepareMS = 0.0
    public var settingsCacheHit = false, settingsCacheWriteFailed = false
    public var appMetadataReads = 0, reusedApps = 0
    public var snapshotReused = false, settingsMemoryHit = false
    public init() {}
}
public struct CatalogLoad: Sendable {
    public let snapshot: CatalogSnapshot
    public let watchPaths: [String]
    public let metrics: CatalogMetrics
    public init(snapshot: CatalogSnapshot, watchPaths: [String], metrics: CatalogMetrics = CatalogMetrics()) {
        self.snapshot = snapshot; self.watchPaths = watchPaths; self.metrics = metrics
    }
}
/// Serial background ownership of app metadata and the prepared snapshot.
public actor SystemCatalogSource {
    private let cacheDirectory: URL?
    private var appCache = AppSourceCache()
    private var previous: CatalogSnapshot?
    private var settingsCache: (build: String, languages: [String], value: CachedSettings)?
    public init(cacheDirectory: URL? = nil) { self.cacheDirectory = cacheDirectory }
    public func load() throws -> CatalogLoad {
        var metrics = CatalogMetrics()
        let languages = Locale.preferredLanguages, build = SettingsCache.systemBuild
        let start = ContinuousClock.now
        let apps = try AppSource.scan(languages: languages, cache: &appCache)
        metrics.appScanMS = durationMS(start.duration(to: .now))
        metrics.appMetadataReads = apps.metadataReads; metrics.reusedApps = apps.reusedBundles
        let settingsStart = ContinuousClock.now
        let cached: CachedSettings
        if let saved = settingsCache, saved.build == build, saved.languages == languages {
            cached = saved.value; metrics.settingsMemoryHit = true
        } else {
            if let cacheDirectory { cached = try SettingsCache.load(directory: cacheDirectory, build: build, languages: languages) }
            else { cached = CachedSettings(scan: try SettingsSource.scan(languages: languages), hit: false, writeFailed: false) }
            settingsCache = (build, languages, cached)
        }
        let settings = cached.scan
        metrics.settingsCacheHit = cached.hit; metrics.settingsCacheWriteFailed = cached.writeFailed
        metrics.settingsLoadMS = durationMS(settingsStart.duration(to: .now))
        metrics.appCount = apps.entries.count; metrics.settingsCount = settings.entries.count
        metrics.skippedApps = apps.skippedBundles; metrics.malformedSettings = settings.malformedResources
        let prepareStart = ContinuousClock.now
        let entries = apps.entries + CatalogEntry.commands + settings.entries
        let snapshot: CatalogSnapshot
        if let previous, previous.entries.count == entries.count, entries.allSatisfy({ previous.entries[$0.item.id] == $0 }) {
            snapshot = previous; metrics.snapshotReused = true
        } else { snapshot = try CatalogSnapshot(entries: entries); previous = snapshot }
        metrics.prepareMS = durationMS(prepareStart.duration(to: .now))
        return CatalogLoad(snapshot: snapshot, watchPaths: apps.watchPaths, metrics: metrics)
    }
}
public func durationMS(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}
/// Aggregate event trace only: no names, paths or identifiers are retained.
public struct CatalogWatchDiagnostics: Sendable {
    public var batches = 0, events = 0, relevantEvents = 0, resetBatches = 0, creationChecks = 0
    public var rootEvents = 0, bundleEvents = 0, bundleContentEvents = 0
    public var flags: [UInt32: Int] = [:]
    public init() {}
    public func since(_ earlier: Self) -> Self {
        var result = Self()
        result.batches = batches - earlier.batches; result.events = events - earlier.events
        result.relevantEvents = relevantEvents - earlier.relevantEvents; result.resetBatches = resetBatches - earlier.resetBatches
        result.creationChecks = creationChecks - earlier.creationChecks; result.rootEvents = rootEvents - earlier.rootEvents
        result.bundleEvents = bundleEvents - earlier.bundleEvents; result.bundleContentEvents = bundleContentEvents - earlier.bundleContentEvents
        result.flags = flags.reduce(into: [:]) { result, pair in
            let count = pair.value - (earlier.flags[pair.key] ?? 0)
            if count > 0 { result[pair.key] = count }
        }
        return result
    }
    mutating func add(_ batch: Self) {
        batches += batch.batches; events += batch.events; relevantEvents += batch.relevantEvents; resetBatches += batch.resetBatches
        rootEvents += batch.rootEvents; bundleEvents += batch.bundleEvents; bundleContentEvents += batch.bundleContentEvents
        for (flag, count) in batch.flags { flags[flag, default: 0] += count }
    }
}
public enum CatalogEvent: Sendable { case changed, rescanRequired, failed }
@MainActor public protocol CatalogWatching: AnyObject {
    func start(paths: [String], changed: @escaping @MainActor @Sendable (CatalogEvent) -> Void) -> Bool
    func stop()
    var diagnostics: CatalogWatchDiagnostics { get }
}
public extension CatalogWatching { var diagnostics: CatalogWatchDiagnostics { CatalogWatchDiagnostics() } }
private final class EventContext: Sendable {
    let observed: @MainActor @Sendable (CatalogWatchDiagnostics) -> Void
    let paths: [String]
    init(paths: [String], _ observed: @escaping @MainActor @Sendable (CatalogWatchDiagnostics) -> Void) { self.paths = paths; self.observed = observed }
}

@MainActor public final class AppFolderWatcher: CatalogWatching {
    private var stream: FSEventStreamRef?
    private var creationWatches: [any DispatchSourceFileSystemObject] = []
    private var generation: UInt64 = 0
    public private(set) var diagnostics = CatalogWatchDiagnostics()
    public private(set) var recursivePaths: [String] = []
    public private(set) var creationWatchPaths: [String] = []
    public init() {}
    isolated deinit { stop() }
    public func start(paths: [String], changed: @escaping @MainActor @Sendable (CatalogEvent) -> Void) -> Bool {
        stop()
        guard !paths.isEmpty else { return true }
        // Replay from a captured boundary, including changes while the service registers
        // this stream. SinceNow can miss an immediate edit during that registration gap.
        let boundary = FSEventsGetCurrentEventId()
        let present = paths.filter { filePresence(URL(fileURLWithPath: $0)) != .missing }
        let home = Self.canonicalEventPath(FileManager.default.homeDirectoryForCurrentUser.path)
        // A source must name the application root/bundle, never the user's whole home.
        let candidates = Array(Set(present.map(Self.canonicalEventPath))).sorted()
        guard !candidates.contains(home) else { return false }
        for path in candidates where !recursivePaths.contains(where: { path.hasPrefix($0 + "/") }) {
            recursivePaths.append(path)
        }
        for path in paths where filePresence(URL(fileURLWithPath: path)) == .missing {
            let canonical = Self.canonicalEventPath(path)
            if recursivePaths.contains(where: { canonical.hasPrefix($0 + "/") }) { continue }
            guard watchCreation(of: URL(fileURLWithPath: path), changed: changed) else { stop(); return false }
        }
        guard !recursivePaths.isEmpty else { return true }
        let generation = generation
        let box = EventContext(paths: recursivePaths) { [weak self] batch in
            guard let self, self.generation == generation else { return }
            self.diagnostics.add(batch)
            if batch.resetBatches > 0 { changed(.rescanRequired) }
            else if batch.relevantEvents > 0 { changed(.changed) }
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: { pointer in
            guard let pointer else { return nil }
            _ = Unmanaged<EventContext>.fromOpaque(pointer).retain(); return pointer
        }, release: { pointer in
            if let pointer { Unmanaged<EventContext>.fromOpaque(pointer).release() }
        }, copyDescription: nil)
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        let created = FSEventStreamCreate(nil, { _, info, count, eventPaths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<EventContext>.fromOpaque(info).takeUnretainedValue()
            let resetFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
            let changedPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            var batch = CatalogWatchDiagnostics(); batch.batches = 1; batch.events = count
            for i in 0..<count {
                batch.flags[flags[i], default: 0] += 1
                if flags[i] & resetFlags != 0 { batch.resetBatches = 1 }
                let path = changedPaths[i]
                guard box.paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else { continue }
                batch.relevantEvents += 1
                if path.lowercased().hasSuffix(".app") { batch.bundleEvents += 1 }
                else if path.lowercased().contains(".app/") { batch.bundleContentEvents += 1 }
                else { batch.rootEvents += 1 }
            }
            MainActor.assumeIsolated { box.observed(batch) }
        }, &context, recursivePaths as CFArray, boundary, 0.15, options)
        guard let created else { stop(); return false }
        stream = created
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else { stop(); return false }
        return true
    }
    public func stop() {
        generation &+= 1
        creationWatches.forEach { $0.cancel() }; creationWatches = []; creationWatchPaths = []; recursivePaths = []
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
    }
    private func watchCreation(of root: URL, changed: @escaping @MainActor @Sendable (CatalogEvent) -> Void) -> Bool {
        let parent = AppSource.watchableParent(of: root)
        let fd = open(parent.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        var identity = stat()
        guard fstat(fd, &identity) == 0 else { close(fd); return false }
        let device = identity.st_dev, inode = identity.st_ino
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke], queue: .main)
        let generation = generation
        let check: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.generation == generation else { return }
            self.diagnostics.creationChecks += 1
            var current = stat()
            // Directory vnodes do not receive descendant-file churn. A direct sibling edit
            // may wake this handler, but does not rescan unless the watched chain changes.
            if filePresence(root) != .missing || AppSource.watchableParent(of: root).path != parent.path ||
                stat(parent.path, &current) != 0 || current.st_dev != device || current.st_ino != inode {
                changed(.rescanRequired)
            }
        }
        source.setEventHandler { MainActor.assumeIsolated { check() } }
        source.setCancelHandler { close(fd) }
        creationWatches.append(source); creationWatchPaths.append(parent.path); source.resume()
        // Close the check/register race even when an empty root appeared before resume.
        DispatchQueue.main.async(execute: check)
        return true
    }
    private static func canonicalEventPath(_ path: String) -> String {
        // Foundation can spell /private/var as /var; FSEvents uses the real path.
        // Resolve the existing prefix with POSIX realpath and retain any missing suffix.
        var url = URL(fileURLWithPath: path), suffix: [String] = []
        while true {
            if let resolved = realpath(url.path, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return suffix.isEmpty ? base : (base == "/" ? "" : base) + "/" + suffix.reversed().joined(separator: "/")
            }
            guard url.path != "/" else { return path }
            suffix.append(url.lastPathComponent); url.deleteLastPathComponent()
        }
    }
}

/// One complete snapshot, one in-flight scan, and one coalesced follow-up. No persistent event log.
@MainActor public final class CatalogController {
    public private(set) var snapshot: CatalogSnapshot?
    public private(set) var metrics = CatalogMetrics()
    public private(set) var firstMetrics: CatalogMetrics?
    public private(set) var completedScans = 0
    public private(set) var metadataReads = 0, reusedApps = 0, reusedSnapshots = 0
    public private(set) var watchHealthy = false
    public var watchDiagnostics: CatalogWatchDiagnostics { watcher.diagnostics }
    public var onChange: ((CatalogSnapshot) -> Void)?
    public var onError: ((String) -> Void)?
    private let watcher: any CatalogWatching
    private let loader: @Sendable () async throws -> CatalogLoad
    private var paths: [String]
    private var revision: UInt64 = 0
    private var running = false, stopped = true
    private var debounce: Task<Void, Never>?
    private var scan: Task<Void, Never>?

    public init(paths: [String], watcher: any CatalogWatching = AppFolderWatcher(),
                loader: (@Sendable () async throws -> CatalogLoad)? = nil) {
        self.paths = Array(Set(paths)).sorted(); self.watcher = watcher
        let source = SystemCatalogSource()
        self.loader = loader ?? { try await source.load() }
    }
    isolated deinit { stop() }
    public func start() {
        guard stopped else { return }
        stopped = false; watch(); revision &+= 1; launchScan()
    }
    public func stop() {
        stopped = true; revision &+= 1; watcher.stop(); debounce?.cancel(); scan?.cancel()
    }
    public func refresh() { receive(.rescanRequired) }
    public func removeMissing(_ id: String) {
        guard let existing = snapshot, existing.entries[id] != nil, let revised = try? existing.removing(id) else { return }
        snapshot = revised; onChange?(revised); refresh()
    }
    private func watch() {
        watchHealthy = watcher.start(paths: paths) { [weak self] event in self?.receive(event) }
        if !watchHealthy { onError?("Application-folder monitoring could not start. The current scan is still available.") }
    }
    private func receive(_ event: CatalogEvent) {
        guard !stopped else { return }
        revision &+= 1
        switch event {
        case .rescanRequired, .failed: watch()
        case .changed: break
        }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            self?.launchScan()
        }
    }
    private func launchScan() {
        guard !running, !stopped else { return }
        debounce?.cancel(); debounce = nil
        running = true
        let version = revision, loader = loader
        scan = Task { [weak self] in
            let result: Result<CatalogLoad, Error>
            do { result = .success(try await loader()) } catch { result = .failure(error) }
            guard let self else { return }
            self.running = false
            guard !self.stopped else { return }
            switch result {
            case .success(let loaded):
                self.completedScans += 1
                self.metrics = loaded.metrics
                self.metadataReads += loaded.metrics.appMetadataReads; self.reusedApps += loaded.metrics.reusedApps
                if loaded.metrics.snapshotReused { self.reusedSnapshots += 1 }
                if self.firstMetrics == nil { self.firstMetrics = loaded.metrics }
                let requestedPaths = Array(Set(loaded.watchPaths)).sorted()
                if requestedPaths != self.paths {
                    // Start watching newly discovered symlink targets BEFORE the verifying rescan.
                    self.paths = requestedPaths; self.watch(); self.revision &+= 1
                } else if version == self.revision {
                    if self.snapshot?.entries != loaded.snapshot.entries {
                        self.snapshot = loaded.snapshot; self.onChange?(loaded.snapshot)
                    }
                }
            case .failure(let error):
                self.onError?(error.localizedDescription)
                if self.snapshot == nil, version == self.revision, let commands = try? CatalogSnapshot(entries: CatalogEntry.commands) {
                    // A failed first attempt must not keep the other sources waiting forever.
                    self.snapshot = commands; self.onChange?(commands)
                }
            }
            if version != self.revision { self.launchScan() }
        }
    }
}
