import Foundation
import CoreServices

public struct CatalogMetrics: Sendable {
    public var appCount = 0, settingsCount = 0, skippedApps = 0, malformedSettings = 0
    public var appScanMS = 0.0, settingsLoadMS = 0.0, prepareMS = 0.0
    public var settingsCacheHit = false, settingsCacheWriteFailed = false
    public init() {}
}
public struct CatalogLoad: Sendable {
    public let snapshot: CatalogSnapshot
    public let watchPaths: [String]
    public let metrics: CatalogMetrics
    public init(snapshot: CatalogSnapshot, watchPaths: [String], metrics: CatalogMetrics = CatalogMetrics()) {
        self.snapshot = snapshot; self.watchPaths = watchPaths; self.metrics = metrics
    }
    public static func system(cacheDirectory: URL? = nil) throws -> CatalogLoad {
        var metrics = CatalogMetrics()
        let start = ContinuousClock.now
        let apps = try AppSource.scan()
        metrics.appScanMS = durationMS(start.duration(to: .now))
        let settingsStart = ContinuousClock.now
        let settings: SettingsScan
        if let cacheDirectory {
            let cached = try SettingsCache.load(directory: cacheDirectory)
            settings = cached.scan; metrics.settingsCacheHit = cached.hit; metrics.settingsCacheWriteFailed = cached.writeFailed
        } else { settings = try SettingsSource.scan() }
        metrics.settingsLoadMS = durationMS(settingsStart.duration(to: .now))
        metrics.appCount = apps.entries.count; metrics.settingsCount = settings.entries.count
        metrics.skippedApps = apps.skippedBundles; metrics.malformedSettings = settings.malformedResources
        let prepareStart = ContinuousClock.now
        let snapshot = try CatalogSnapshot(entries: apps.entries + CatalogEntry.commands + settings.entries)
        metrics.prepareMS = durationMS(prepareStart.duration(to: .now))
        return CatalogLoad(snapshot: snapshot, watchPaths: apps.watchPaths, metrics: metrics)
    }
}
public func durationMS(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}
public enum CatalogEvent: Sendable { case changed, rescanRequired, failed }
@MainActor public protocol CatalogWatching: AnyObject {
    func start(paths: [String], changed: @escaping @MainActor @Sendable (CatalogEvent) -> Void) -> Bool
    func stop()
}
private final class EventContext: Sendable {
    let changed: @MainActor @Sendable (CatalogEvent) -> Void
    let paths: [String]
    init(paths: [String], _ changed: @escaping @MainActor @Sendable (CatalogEvent) -> Void) { self.paths = paths; self.changed = changed }
}

@MainActor public final class AppFolderWatcher: CatalogWatching {
    private var stream: FSEventStreamRef?
    private var creationWatches: [any DispatchSourceFileSystemObject] = []
    private var generation: UInt64 = 0
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
        let box = EventContext(paths: recursivePaths, changed)
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
            let reset = (0..<count).contains { flags[$0] & resetFlags != 0 }
            let changedPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            // Streams cover existing application roots/bundles only; missing roots use vnodes.
            let relevant = changedPaths.contains { path in box.paths.contains { root in
                path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/")
            } }
            guard reset || relevant else { return }
            MainActor.assumeIsolated { box.changed(reset ? .rescanRequired : .changed) }
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
    public private(set) var watchHealthy = false
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
                loader: @escaping @Sendable () async throws -> CatalogLoad = {
                    try await Task.detached(priority: .utility) { try CatalogLoad.system() }.value
                }) {
        self.paths = Array(Set(paths)).sorted(); self.watcher = watcher; self.loader = loader
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
        guard let existing = snapshot, let revised = try? existing.removing(id) else { return }
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
                if self.firstMetrics == nil { self.firstMetrics = loaded.metrics }
                let requestedPaths = Array(Set(loaded.watchPaths)).sorted()
                if requestedPaths != self.paths {
                    // Start watching newly discovered symlink targets BEFORE the verifying rescan.
                    self.paths = requestedPaths; self.watch(); self.revision &+= 1
                } else if version == self.revision {
                    self.snapshot = loaded.snapshot; self.metrics = loaded.metrics
                    self.onChange?(loaded.snapshot)
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
