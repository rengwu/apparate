import Foundation
import Darwin

public enum FileRootStatus: String, Codable, Sendable { case indexed, indexing, unavailable, denied, notFound, waitingForAccess }
public struct FileRoot: Codable, Sendable, Equatable {
    public var path: String
    public var depth: Int
    public var status: FileRootStatus = .indexing
    public var count = 0
    var node: Int32 = -1
    var ignoreCase = false
    public init(path: String, depth: Int) { self.path = path; self.depth = depth }
}
public enum FileEntryType: Int, Codable, Sendable { case file, directory, link, package, application }
public struct FileMetadata: Codable, Sendable, Equatable {
    public var type: FileEntryType
    public var device: UInt64
    public var inode: UInt64
    public var modified: Int64
    public var hidden: Bool
    public init(type: FileEntryType, device: UInt64 = 0, inode: UInt64 = 0, modified: Int64 = 0, hidden: Bool = false) {
        self.type = type; self.device = device; self.inode = inode; self.modified = modified; self.hidden = hidden
    }
}
final class FileApplication: Codable, Sendable, Equatable {
    let name: String
    let alternates: [String]
    let path: String
    init(_ entry: CatalogEntry) { name = entry.item.name; alternates = entry.item.alternateNames; path = entry.item.path! }
    static func == (lhs: FileApplication, rhs: FileApplication) -> Bool {
        lhs.name == rhs.name && lhs.alternates == rhs.alternates && lhs.path == rhs.path
    }
    var entry: CatalogEntry {
        let url = URL(fileURLWithPath: path)
        return CatalogEntry(item: SearchItem(id: "app:" + path, kind: .app, name: name, alternateNames: alternates, path: path),
                            target: .application(url), location: url.deletingLastPathComponent().path, icon: .file(path))
    }
}
struct FileNode: Codable, Sendable, Equatable {
    var name: String
    var parent: Int32
    var metadata: FileMetadata
    var owner: Int32 = -1
    var otherOwners: [Int32] = []
    var children: [Int32] = []
    var anchor: String? = nil
    var unavailable = false
    var ruleHash: UInt64 = 0
    var application: FileApplication? = nil
    var visible: Bool { owner >= 0 }
    var kind: ItemKind { metadata.type == .application ? .app : (metadata.type == .directory ? .folder : .file) }
    func belongs(to root: Int32) -> Bool { owner == root || otherOwners.contains(root) }
    mutating func include(_ root: Int32) {
        if owner < 0 { owner = root } else if owner != root && !otherOwners.contains(root) { otherOwners.append(root) }
    }
    mutating func exclude(_ root: Int32) {
        if owner == root { owner = otherOwners.popLast() ?? -1 } else { otherOwners.removeAll { $0 == root } }
    }
}
/// An immutable chunk owns its original names and prepared matching buffers. Updating one
/// node copies/prepares at most 256 nodes, regardless of searches retaining older snapshots.
final class FileChunk: Sendable {
    static let size = 256
    let nodes: [FileNode?]
    let text: TextStore
    let appOffsets: [Int]
    // The scan reads only these value buffers and prepared text. It never copies a
    // FileNode (and its reference-bearing metadata) for an ordinary candidate.
    let kinds: [ItemKind?]
    let ordinaryKinds: [ItemKind?]
    let parents: [Int32]
    init(_ nodes: [FileNode?]) {
        self.nodes = nodes
        appOffsets = nodes.indices.filter { nodes[$0]?.application != nil }
        kinds = nodes.map { node in
            guard let node, node.visible, node.kind != .app else { return nil }
            return node.kind
        }
        ordinaryKinds = nodes.contains(where: { $0?.name.hasPrefix(".") == true })
            ? kinds.enumerated().map { nodes[$0.offset]?.name.hasPrefix(".") == true ? nil : $0.element } : kinds
        parents = nodes.map { $0?.parent ?? -1 }
        var text = TextStore()
        for node in nodes { _ = text.append(node?.name ?? "") }
        self.text = text
    }
}
public struct FileIndexSnapshot: Sendable {
    var chunks: [FileChunk] = []
    var identity = UUID()
    var applications: CatalogSnapshot?
    public internal(set) var roots: [FileRoot] = []
    var free: [Int32] = []
    var slots = 0
    public internal(set) var count = 0
    public internal(set) var revision: UInt64 = 0
    public internal(set) var lastUpdate: Date?
    public internal(set) var skipHiddenFiles = false
    var allowedRoots: Set<Int32>?
    var restrictedKinds: [[ItemKind?]]?
    var restrictedOrdinaryKinds: [[ItemKind?]]?
    public init() {}
    func node(_ id: Int32) -> FileNode? {
        guard id >= 0, Int(id) < slots else { return nil }
        return chunks[Int(id) / FileChunk.size].nodes[Int(id) % FileChunk.size]
    }
    func searchable(_ node: FileNode) -> Bool {
        guard node.visible else { return false }
        if skipHiddenFiles && node.name.hasPrefix(".") {
            guard roots.indices.contains(where: { r in
                guard allowedRoots?.contains(Int32(r)) != false, node.belongs(to: Int32(r)), let root = self.node(roots[r].node) else { return false }
                return root.parent == node.parent && root.name == node.name && root.anchor == node.anchor
            }) else { return false }
        }
        guard let allowedRoots else { return true }
        return allowedRoots.contains(node.owner) || node.otherOwners.contains(where: allowedRoots.contains)
    }
    func path(_ id: Int32) -> String {
        var names: [String] = [], current = id
        while let node = node(current) {
            if let anchor = node.anchor { return names.reversed().reduce(anchor) { appendPath($0, $1) } }
            names.append(node.name); current = node.parent
        }
        return "/" + names.reversed().joined(separator: "/")
    }
    func find(_ path: String) -> Int32? {
        guard let root = roots.filter({ pathIsWithin(path, $0.path) }).min(by: { $0.path.count < $1.path.count }), root.node >= 0 else { return nil }
        var id = root.node
        let suffix = path.dropFirst(root.path.count).split(separator: "/")
        for part in suffix {
            guard let next = node(id)?.children.first(where: { node($0)?.name == String(part) }) else { return nil }
            id = next
        }
        return id
    }
    func entry(_ id: Int32) -> CatalogEntry? {
        guard let node = node(id), searchable(node) else { return nil }
        let path = path(id), kind = node.kind
        return CatalogEntry(item: SearchItem(id: (kind == .folder ? "folder:" : "file:") + path, kind: kind, name: node.name, path: path),
                            target: .file(URL(fileURLWithPath: path)), location: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent,
                            icon: .file(path))
    }
    mutating func prepareApplications() {
        var entries: [String: CatalogEntry] = [:]
        for chunk in chunks { for offset in chunk.appOffsets {
            if let node = chunk.nodes[offset], searchable(node), let app = node.application { entries[app.entry.item.id] = app.entry }
        } }
        applications = try? CatalogSnapshot(entries: entries.values.sorted { $0.item.id < $1.item.id })
    }
    public var applicationCount: Int { applications?.entries.count ?? 0 }
    package var dotEntryCount: Int { chunks.reduce(0) { $0 + $1.nodes.compactMap { $0 }.filter { searchable($0) && $0.name.hasPrefix(".") }.count } }
    public func restricting(to paths: Set<String>, skipHiddenFiles: Bool? = nil) -> FileIndexSnapshot {
        var result = self
        result.identity = UUID()
        if let skipHiddenFiles { result.skipHiddenFiles = skipHiddenFiles }
        result.allowedRoots = Set(roots.indices.filter { paths.contains(roots[$0].path) }.map(Int32.init))
        result.count = chunks.reduce(0) { total, chunk in total + chunk.nodes.compactMap { $0 }.filter { result.searchable($0) }.count }
        result.restrictedKinds = chunks.map { chunk in
            chunk.nodes.indices.map { offset in
                guard let node = chunk.nodes[offset], result.searchable(node) else { return nil }
                return chunk.kinds[offset]
            }
        }
        result.restrictedOrdinaryKinds = chunks.enumerated().map { index, chunk in
            chunk.ordinaryKinds.indices.map { offset in result.restrictedKinds![index][offset] == nil ? nil : chunk.ordinaryKinds[offset] }
        }
        result.prepareApplications()
        return result
    }
    func applyingAccess(_ access: FileAccessPolicy) -> FileIndexSnapshot {
        var writer = FileIndexBuilder(self)
        for (path, observation) in access.protectedPaths where observation != .allowed {
            if let id = find(path) { writer.markUnavailable(id) }
            for r in roots.indices where pathIsWithin(roots[r].path, path) || pathIsWithin(path, roots[r].path) {
                writer.roots[r].status = observation == .denied ? .denied : .waitingForAccess
                if pathIsWithin(roots[r].path, path) { writer.markUnavailable(roots[r].node) }
            }
        }
        return writer.edits.isEmpty && writer.roots == roots ? self : writer.finish()
    }
    public func contains(path: String) -> Bool { find(path).flatMap(node).map(searchable) ?? false }
    public var unavailableCount: Int { chunks.reduce(0) { $0 + $1.nodes.compactMap { $0 }.filter { searchable($0) && $0.unavailable }.count } }
}

func appendPath(_ parent: String, _ name: String) -> String { parent == "/" ? "/" + name : parent + "/" + name }
func pathIsWithin(_ path: String, _ parent: String) -> Bool { path == parent || path.hasPrefix(parent == "/" ? "/" : parent + "/") }
func parentPath(_ path: String) -> String { URL(fileURLWithPath: path).deletingLastPathComponent().path }

/// Writer-local mutations. Prepared buffers are built only for touched chunks at publication.
struct FileIndexBuilder {
    var base: FileIndexSnapshot
    var edits: [Int: [FileNode?]] = [:]
    var roots: [FileRoot]
    var free: [Int32]
    var slots: Int
    var count: Int
    init(_ base: FileIndexSnapshot = FileIndexSnapshot()) {
        self.base = base; roots = base.roots; free = base.free; slots = base.slots; count = base.count
        // A pending config view counts only allowed candidates, while its shared
        // graph still contains the old memberships that the rebuild will remove.
        if base.allowedRoots != nil {
            count = base.chunks.reduce(0) { $0 + $1.nodes.compactMap { $0 }.filter(\.visible).count }
        }
    }
    func node(_ id: Int32) -> FileNode? {
        guard id >= 0, Int(id) < slots else { return nil }
        let chunk = Int(id) / FileChunk.size, offset = Int(id) % FileChunk.size
        if let edited = edits[chunk] { return edited[offset] }
        return base.node(id)
    }
    mutating func set(_ id: Int32, _ value: FileNode?) {
        let old = node(id)
        // A scan can visit every node without changing it. Preserve shared chunks
        // until metadata, membership, children or application presentation changes.
        guard old != value else { return }
        if old?.visible == true { count -= 1 }
        if value?.visible == true { count += 1 }
        let chunk = Int(id) / FileChunk.size, offset = Int(id) % FileChunk.size
        if edits[chunk] == nil {
            edits[chunk] = chunk < base.chunks.count ? base.chunks[chunk].nodes : Array(repeating: nil, count: FileChunk.size)
        }
        edits[chunk]![offset] = value
    }
    mutating func add(_ node: FileNode) -> Int32 {
        let id: Int32
        if let reused = free.popLast() { id = reused }
        else { id = Int32(slots); slots += 1 }
        set(id, node); return id
    }
    mutating func include(_ id: Int32, root: Int32) {
        guard var value = node(id) else { return }
        if !value.belongs(to: root) { roots[Int(root)].count += 1; value.include(root) }
        value.unavailable = false; set(id, value)
    }
    mutating func excludeTree(_ id: Int32, root: Int32) {
        guard var value = node(id) else { return }
        for child in value.children { excludeTree(child, root: root) }
        if value.belongs(to: root) { roots[Int(root)].count -= 1; value.exclude(root) }
        value.children.removeAll { node($0) == nil }
        if !value.visible && value.children.isEmpty && !roots.contains(where: { $0.node == id }) {
            set(id, nil); free.append(id)
        } else { set(id, value) }
    }
    mutating func markUnavailable(_ id: Int32) {
        guard var value = node(id) else { return }
        value.unavailable = true; set(id, value)
        for child in value.children { markUnavailable(child) }
    }
    func path(_ id: Int32) -> String {
        var names: [String] = [], current = id
        while let n = node(current) {
            if let anchor = n.anchor { return names.reversed().reduce(anchor) { appendPath($0, $1) } }
            names.append(n.name); current = n.parent
        }
        return "/" + names.reversed().joined(separator: "/")
    }
    func find(_ path: String) -> Int32? {
        guard let root = roots.filter({ pathIsWithin(path, $0.path) }).min(by: { $0.path.count < $1.path.count }), root.node >= 0 else { return nil }
        var id = root.node
        for name in path.dropFirst(root.path.count).split(separator: "/") {
            guard let child = node(id)?.children.first(where: { node($0)?.name == String(name) }) else { return nil }
            id = child
        }
        return id
    }
    mutating func finish() -> FileIndexSnapshot {
        var snapshot = base
        for chunk in edits.keys.sorted() {
            let replacement = FileChunk(edits[chunk]!)
            if chunk == snapshot.chunks.count { snapshot.chunks.append(replacement) }
            else { snapshot.chunks[chunk] = replacement }
        }
        snapshot.roots = roots; snapshot.free = free; snapshot.slots = slots; snapshot.count = count
        snapshot.allowedRoots = nil; snapshot.restrictedKinds = nil; snapshot.restrictedOrdinaryKinds = nil
        snapshot.prepareApplications()
        snapshot.identity = UUID(); snapshot.revision &+= 1; snapshot.lastUpdate = Date()
        return snapshot
    }
}

public struct FileAccessPolicy: Sendable {
    public let protectedPaths: [String: AccessStatus?]
    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path, observations: [AccessObservation] = []) {
        protectedPaths = Dictionary(uniqueKeysWithValues: AccessFolder.allCases.map { folder in
            (appendPath(home, folder.rawValue), observations.last { $0.folder == folder }?.status)
        })
    }
    public init(protectedPaths: [String: AccessStatus?]) { self.protectedPaths = protectedPaths }
    public func blocked(_ path: String) -> FileRootStatus? {
        for (protected, observation) in protectedPaths where pathIsWithin(path, protected) && observation != .allowed {
            return observation == .denied ? .denied : .waitingForAccess
        }
        return nil
    }
}

public struct FileReading: Sendable {
    public var metadata: @Sendable (String) throws -> FileMetadata
    public var children: @Sendable (String) throws -> [String]
    public var ignoreContents: @Sendable (String) throws -> Data?
    public var application: @Sendable (String) -> CatalogEntry
    public var ignoresCase: @Sendable (String) -> Bool
    public init(metadata: @escaping @Sendable (String) throws -> FileMetadata = Self.readMetadata,
                children: @escaping @Sendable (String) throws -> [String] = Self.readChildren,
                ignoreContents: @escaping @Sendable (String) throws -> Data? = Self.readIgnore,
                application: @escaping @Sendable (String) -> CatalogEntry = Self.readApplication,
                ignoresCase: @escaping @Sendable (String) -> Bool = Self.volumeIgnoresCase) {
        self.metadata = metadata; self.children = children; self.ignoreContents = ignoreContents; self.application = application; self.ignoresCase = ignoresCase
    }
    static func failure(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    public static func readMetadata(_ path: String) throws -> FileMetadata {
        var s = stat()
        guard lstat(path, &s) == 0 else { throw failure(errno) }
        let mode = s.st_mode & S_IFMT
        var type: FileEntryType = mode == S_IFLNK ? .link : (mode == S_IFDIR ? .directory : .file)
        if type == .directory {
            let url = URL(fileURLWithPath: path)
            if url.pathExtension.lowercased() == "app" { type = .application }
            else if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { type = .package }
        }
        return FileMetadata(type: type, device: UInt64(UInt32(bitPattern: s.st_dev)), inode: s.st_ino,
                            modified: Int64(s.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(s.st_mtimespec.tv_nsec),
                            hidden: s.st_flags & UInt32(UF_HIDDEN) != 0 || URL(fileURLWithPath: path).lastPathComponent.hasPrefix("."))
    }
    public static func readChildren(_ path: String) throws -> [String] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure(errno) }
        guard let directory = fdopendir(fd) else { let code = errno; close(fd); throw failure(code) }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw failure(errno) }
        return names.sorted()
    }
    public static func readIgnore(_ path: String) throws -> Data? {
        let fd = open(appendPath(path, ".gitignore"), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT || errno == ELOOP { return nil }
            throw failure(errno)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure(errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { return nil }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let length = read(fd, &bytes, bytes.count)
            if length < 0 { if errno == EINTR { continue }; throw failure(errno) }
            if length == 0 { return result }
            result.append(contentsOf: bytes.prefix(length))
        }
    }
    public static func readApplication(_ path: String) -> CatalogEntry {
        let url = URL(fileURLWithPath: path)
        if let entry = try? AppSource.bundleEntry(at: url) { return entry }
        // An incomplete app may be observed during installation. It remains a terminal app
        // item, with its filename until metadata becomes readable on the next bundle event.
        return CatalogEntry(item: SearchItem(id: "app:" + path, kind: .app, name: url.deletingPathExtension().lastPathComponent, path: path),
                            target: .application(url), location: url.deletingLastPathComponent().path, icon: .file(path))
    }
    public static func volumeIgnoresCase(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) == false
    }
}
