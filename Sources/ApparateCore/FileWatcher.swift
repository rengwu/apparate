import Foundation
import CoreServices
import Darwin

public struct FileWatchBatch: Sendable {
    public var checkpoint: FileCheckpoint
    public var changes: [FileChange]
    public var rearm: Bool
    public init(checkpoint: FileCheckpoint, changes: [FileChange], rearm: Bool = false) {
        self.checkpoint = checkpoint; self.changes = changes; self.rearm = rearm
    }
}
public struct FileWatchStart: Sendable {
    public var checkpoints: [FileCheckpoint] = []
    public var rescanPaths: [String] = []
    public var healthy = true
    public init(checkpoints: [FileCheckpoint] = [], rescanPaths: [String] = [], healthy: Bool = true) {
        self.checkpoints = checkpoints; self.rescanPaths = rescanPaths; self.healthy = healthy
    }
}
@MainActor public protocol FileWatching: AnyObject {
    func start(paths: [String], checkpoints: [FileCheckpoint], access: FileAccessPolicy, shallowPaths: Set<String>,
               receive: @escaping @MainActor @Sendable (FileWatchBatch) -> Void) -> FileWatchStart
    func stop()
}
extension FileWatching {
    public func start(paths: [String], checkpoints: [FileCheckpoint], access: FileAccessPolicy,
                      receive: @escaping @MainActor @Sendable (FileWatchBatch) -> Void) -> FileWatchStart {
        start(paths: paths, checkpoints: checkpoints, access: access, shallowPaths: [], receive: receive)
    }
}
private final class FileEventContext: Sendable {
    let root: String, relative: String
    let checkpoint: FileCheckpoint
    let receive: @MainActor @Sendable (FileWatchBatch) -> Void
    init(root: String, relative: String, checkpoint: FileCheckpoint, receive: @escaping @MainActor @Sendable (FileWatchBatch) -> Void) {
        self.root = root; self.relative = relative; self.checkpoint = checkpoint; self.receive = receive
    }
}

@MainActor public final class FileFolderWatcher: FileWatching {
    private var streams: [FSEventStreamRef] = []
    private var vnodes: [any DispatchSourceFileSystemObject] = []
    private var generation: UInt64 = 0
    public private(set) var recursivePaths: [String] = []
    public private(set) var shallowPaths: [String] = []
    public private(set) var creationWatchPaths: [String] = []
    public init() {}
    isolated deinit { stop() }
    public func stop() {
        generation &+= 1
        for stream in streams { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        streams = []; vnodes.forEach { $0.cancel() }; vnodes = []; recursivePaths = []; shallowPaths = []; creationWatchPaths = []
    }
    public func start(paths: [String], checkpoints: [FileCheckpoint], access: FileAccessPolicy, shallowPaths: Set<String> = [],
                      receive: @escaping @MainActor @Sendable (FileWatchBatch) -> Void) -> FileWatchStart {
        stop()
        let generation = generation
        let deliver: @MainActor @Sendable (FileWatchBatch) -> Void = { [weak self] batch in
            guard self?.generation == generation else { return }; receive(batch)
        }
        var result = FileWatchStart(), watched: [(String, Int32)] = []
        for path in Array(Set(paths)).sorted(by: { $0.count < $1.count }) where access.blocked(path) == nil {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                if !watchCreation(path, receive: deliver) { result.healthy = false }
                result.rescanPaths.append(path); continue
            }
            let device = info.st_dev
            if shallowPaths.contains(path) {
                if watchShallow(path, receive: deliver) { self.shallowPaths.append(path) } else { result.healthy = false }
                // Vnodes have no replay cursor: verify this single directory on startup/rearm.
                result.rescanPaths.append(path)
                continue
            }
            if watched.contains(where: {
                $0.1 == device && pathIsWithin(path, $0.0) &&
                    !path.dropFirst($0.0.count).split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "node_modules" })
            }) { continue }
            var fs = statfs()
            guard statfs(path, &fs) == 0 else { result.healthy = false; result.rescanPaths.append(path); continue }
            let mount = withUnsafePointer(to: &fs.f_mntonname) { p in p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            let canonical = Self.canonical(path)
            // APFS firmlinks (e.g. /Users) may already be device-root-relative even though
            // statfs reports /System/Volumes/Data as the volume mount point.
            let relative = pathIsWithin(canonical, mount) ? String(canonical.dropFirst(mount == "/" ? 1 : mount.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : String(canonical.drop(while: { $0 == "/" }))
            let uuid = FSEventsCopyUUIDForDevice(device).map { CFUUIDCreateString(nil, $0) as String }
            let old = checkpoints.first { $0.path == path && $0.device == device && $0.uuid == uuid && uuid != nil }
            let boundary = old?.eventID ?? FSEventsGetLastEventIdForDeviceBeforeTime(device, Date().timeIntervalSince1970)
            let checkpoint = FileCheckpoint(path: path, device: device, uuid: uuid, eventID: boundary)
            if old == nil { result.rescanPaths.append(path) }
            let box = FileEventContext(root: path, relative: relative, checkpoint: checkpoint, receive: deliver)
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: { p in
                guard let p else { return nil }; _ = Unmanaged<FileEventContext>.fromOpaque(p).retain(); return p
            }, release: { p in if let p { Unmanaged<FileEventContext>.fromOpaque(p).release() } }, copyDescription: nil)
            let stream = FSEventStreamCreateRelativeToDevice(nil, { _, opaque, count, rawPaths, flags, ids in
                guard let opaque else { return }
                let box = Unmanaged<FileEventContext>.fromOpaque(opaque).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]
                let batch = FileFolderWatcher.decode(root: box.root, relative: box.relative, checkpoint: box.checkpoint,
                                        paths: paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)),
                                        ids: Array(UnsafeBufferPointer(start: ids, count: count)))
                if let batch { MainActor.assumeIsolated { box.receive(batch) } }
            }, &context, device, [relative] as CFArray, uuid == nil ? UInt64(kFSEventStreamEventIdSinceNow) : boundary, 0.15,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
            guard let stream else { result.healthy = false; result.rescanPaths.append(path); continue }
            FSEventStreamSetDispatchQueue(stream, .main)
            guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); result.healthy = false; result.rescanPaths.append(path); continue }
            streams.append(stream); recursivePaths.append(path); watched.append((path, device)); result.checkpoints.append(checkpoint)
        }
        return result
    }
    /// Pure event decoding also lets recovery cases be exercised without disrupting a volume.
    public nonisolated static func decode(root: String, relative: String, checkpoint original: FileCheckpoint,
                                          paths: [String], flags: [UInt32], ids: [UInt64]) -> FileWatchBatch? {
        guard paths.count == flags.count, flags.count == ids.count else { return nil }
        var checkpoint = original, changes: [FileChange] = [], rearm = false
        let reset = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        for i in paths.indices {
            if flags[i] & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            if ids[i] != 0 { checkpoint.eventID = max(checkpoint.eventID, ids[i]) }
            if flags[i] & reset != 0 {
                changes = [FileChange(path: root, recursive: true)]; rearm = true
                if flags[i] & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0 { checkpoint.eventID = 0; checkpoint.uuid = nil }
                break
            }
            let relativePath = String(paths[i].drop(while: { $0 == "/" }))
            let path: String
            if relative.isEmpty { path = relativePath.isEmpty ? root : appendPath(root, relativePath) }
            else if pathIsWithin(relativePath, relative) { path = root + relativePath.dropFirst(relative.count) }
            else if pathIsWithin(relative, relativePath) { path = root }
            else { continue }
            let normalizedPath = AppConfig.normalizedFolder(path, home: "")
            let suffix = normalizedPath.dropFirst(root.count).split(separator: "/")
            if suffix.contains("node_modules") || suffix.dropLast().contains(where: { $0.hasPrefix(".") }) { continue }
            changes.append(FileChange(path: normalizedPath, recursive: flags[i] & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0))
        }
        return changes.isEmpty ? nil : FileWatchBatch(checkpoint: checkpoint, changes: changes, rearm: rearm)
    }
    private func watchShallow(_ path: String, receive: @escaping @MainActor @Sendable (FileWatchBatch) -> Void) -> Bool {
        let fd = open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFDIR else { close(fd); return false }
        let inode = original.st_ino, device = original.st_dev
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .attrib, .delete, .rename, .revoke], queue: .main)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            MainActor.assumeIsolated {
                var current = stat()
                let replaced = lstat(path, &current) != 0 || current.st_ino != inode || current.st_dev != device
                let rearm = replaced || !source.data.intersection([.delete, .rename, .revoke]).isEmpty
                receive(FileWatchBatch(checkpoint: FileCheckpoint(path: path, device: device, uuid: nil, eventID: 0),
                    changes: [FileChange(path: path)], rearm: rearm))
            }
        }
        source.setCancelHandler { close(fd) }; source.resume(); vnodes.append(source)
        return true
    }
    private func watchCreation(_ path: String, receive: @escaping @MainActor @Sendable (FileWatchBatch) -> Void) -> Bool {
        let root = URL(fileURLWithPath: path), parent = AppSource.watchableParent(of: root)
        let fd = open(parent.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        var original = stat()
        guard fstat(fd, &original) == 0 else { close(fd); return false }
        let inode = original.st_ino, device = original.st_dev
        var rootInfo = stat()
        let originallyPresent = lstat(path, &rootInfo) == 0
        let rootInode = rootInfo.st_ino, rootDevice = rootInfo.st_dev
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke], queue: .main)
        let check: @MainActor @Sendable () -> Void = {
            var now = stat(), currentRoot = stat()
            let present = lstat(path, &currentRoot) == 0
            let changed = present != originallyPresent || (present && (currentRoot.st_ino != rootInode || currentRoot.st_dev != rootDevice || currentRoot.st_mode & S_IFMT == S_IFDIR))
            if changed || AppSource.watchableParent(of: root).path != parent.path || stat(parent.path, &now) != 0 || now.st_ino != inode || now.st_dev != device {
                receive(FileWatchBatch(checkpoint: FileCheckpoint(path: path, device: device, uuid: nil, eventID: 0), changes: [FileChange(path: path, recursive: true)], rearm: true))
            }
        }
        source.setEventHandler { MainActor.assumeIsolated { check() } }; source.setCancelHandler { close(fd) }
        source.resume(); vnodes.append(source); creationWatchPaths.append(parent.path); DispatchQueue.main.async(execute: check)
        return true
    }
    public nonisolated static func canonical(_ path: String) -> String {
        var url = URL(fileURLWithPath: path), suffix: [String] = []
        while true {
            if let resolved = realpath(url.path, nil) {
                defer { free(resolved) }
                return suffix.reversed().reduce(String(cString: resolved)) { appendPath($0, $1) }
            }
            guard url.path != "/" else { return path }
            suffix.append(url.lastPathComponent); url.deleteLastPathComponent()
        }
    }
}
