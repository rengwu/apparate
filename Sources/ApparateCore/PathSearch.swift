import Foundation
import Synchronization
import Darwin

public struct PathQuery: Sendable, Equatable {
    public let directory: String, filter: String
    public init?(_ text: String, home: String) {
        guard text == "~" || text.hasPrefix("~/") || text.hasPrefix("/") else { return nil }
        let expanded = text == "~" ? home + "/" : text.hasPrefix("~/") ? home + text.dropFirst() : text
        guard let slash = expanded.lastIndex(of: "/") else { return nil }
        directory = AppConfig.normalizedFolder(String(expanded[...slash]), home: home)
        filter = String(expanded[expanded.index(after: slash)...])
    }
    public static func displayed(_ path: String, home: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

public struct PathReading: Sendable {
    public var files: FileReading
    public var canonical: @Sendable (String) -> String
    public init(files: FileReading = FileReading(), canonical: @escaping @Sendable (String) -> String = FileFolderWatcher.canonical) {
        self.files = files; self.canonical = canonical
    }
    /// Unattended profiles may only browse their own fixture directory.
    public static func restricted(to root: String) -> Self {
        let canonicalRoot = FileFolderWatcher.canonical(root)
        let canonical: @Sendable (String) -> String = { path in
            guard pathIsWithin(path, root) || pathIsWithin(path, canonicalRoot) else { return path }
            return FileFolderWatcher.canonical(path)
        }
        let permitted: @Sendable (String) throws -> Void = { path in
            guard pathIsWithin(path, root) || pathIsWithin(path, canonicalRoot),
                  pathIsWithin(canonical(path), canonicalRoot) else { throw FileReading.failure(EACCES) }
        }
        return Self(files: FileReading(metadata: { try permitted($0); return try FileReading.readMetadata($0) },
                                       children: { try permitted($0); return try FileReading.readChildren($0) }), canonical: canonical)
    }
}
public struct PathSearchResponse: Sendable {
    public let rows: [PanelRow]
    public let message: String?
}
private final class PathGeneration: Sendable { let value = Atomic<UInt64>(0) }
/// The serial worker owns this one-directory cache; no timers, watchers or index writes.
private final class PathEngine: @unchecked Sendable {
    let reader: PathReading
    var directory: String?, entries: [CatalogEntry] = []
    var prepared: (dots: Bool, index: SearchIndex)?
    init(reader: PathReading) { self.reader = reader }
    func clear() { directory = nil; entries = []; prepared = nil }
    func search(_ query: PathQuery, access: FileAccessPolicy, usage: UsageSnapshot, cancelled: @Sendable () -> Bool) -> PathSearchResponse {
        do {
            if directory != query.directory { clear() }
            if access.blocked(query.directory) != nil { return PathSearchResponse(rows: [], message: "Folder access is needed. Open Settings → Folders → Allow Access…") }
            if directory != query.directory {
                // Canonicalize protected parents, without probing the protected folders.
                // This also covers /var → /private/var aliases used by fixture homes.
                let canonicalAccess = FileAccessPolicy(protectedPaths: Dictionary(access.protectedPaths.map { path, observation in
                    (appendPath(reader.canonical(parentPath(path)), URL(fileURLWithPath: path).lastPathComponent), observation)
                }, uniquingKeysWith: { first, second in first == .allowed ? second : first }))
                func blocked(_ path: String) -> Bool { access.blocked(path) != nil || canonicalAccess.blocked(path) != nil }
                let canonical = reader.canonical(query.directory)
                if blocked(canonical) { return PathSearchResponse(rows: [], message: "Folder access is needed. Open Settings → Folders → Allow Access…") }
                let metadata = try reader.files.metadata(canonical)
                guard [.directory, .package, .application].contains(metadata.type) else { throw FileReading.failure(ENOTDIR) }
                var next: [CatalogEntry] = []
                for name in try reader.files.children(canonical) {
                    if cancelled() { return PathSearchResponse(rows: [], message: nil) }
                    let path = appendPath(query.directory, name), actual = appendPath(canonical, name)
                    if blocked(path) || blocked(actual) { continue }
                    let metadata: FileMetadata
                    do { metadata = try reader.files.metadata(actual) }
                    catch { if (error as NSError).code == Int(ENOENT) { continue }; throw error }
                    var kind: ItemKind = metadata.type == .directory ? .folder : .file
                    if metadata.type == .link {
                        let target = reader.canonical(actual)
                        if blocked(target) { continue }
                        if (try? reader.files.metadata(target).type) == .directory { kind = .folder }
                    }
                    next.append(CatalogEntry(item: SearchItem(id: (kind == .folder ? "folder:" : "file:") + path, kind: kind, name: name, path: path),
                        target: .file(URL(fileURLWithPath: path)), icon: .file(path)))
                }
                guard !cancelled() else { return PathSearchResponse(rows: [], message: nil) }
                directory = query.directory; entries = next
            }
            let dots = query.filter.hasPrefix(".")
            if prepared?.dots != dots {
                prepared = (dots, try SearchIndex(items: entries.filter { dots || !$0.item.name.hasPrefix(".") }.map(\.item)))
            }
            guard !cancelled(), let index = prepared?.index else { return PathSearchResponse(rows: [], message: nil) }
            let matches: [SearchResult]
            if query.filter.isEmpty {
                let sorted = index.items.indices.sorted {
                    if index.text.less(Int32($0), Int32($1)) { return true }
                    if index.text.less(Int32($1), Int32($0)) { return false }
                    return index.items[$0].id < index.items[$1].id
                }
                matches = sorted.prefix(50).map { SearchResult(item: index.items[$0], tier: .exact, textScore: 0, usageBoost: 0, source: .name, highlights: [], webQuery: nil) }
            } else {
                var config = AppConfig(); config.prefixes = [:]
                matches = index.search(ParsedQuery(query.filter, config: config), usage: usage, includeWebFallback: false, isCancelled: cancelled)
            }
            return PathSearchResponse(rows: matches.map { result in
                PanelRow(result: result, entry: CatalogEntry(item: result.item, target: .file(URL(fileURLWithPath: result.item.path!)), icon: .file(result.item.path!)))
            }, message: nil)
        } catch {
            clear()
            let error = error as NSError
            let message = error.code == Int(ENOENT) ? "Folder not found" : error.code == Int(ENOTDIR) ? "This path is not a folder" : "Could not read this folder"
            return PathSearchResponse(rows: [], message: message)
        }
    }
}
@MainActor public final class PathSearchCoordinator {
    private let generation = PathGeneration()
    private let worker = DispatchQueue(label: "local.apparate.path-search", qos: .userInitiated)
    private let engine: PathEngine
    private var hasWork = false
    public init(reader: PathReading = PathReading()) { engine = PathEngine(reader: reader) }
    public func invalidate(clear: Bool = false) {
        generation.value.wrappingAdd(1, ordering: .relaxed)
        if clear && hasWork {
            hasWork = false
            let engine = engine; worker.async { engine.clear() }
        }
    }
    public func submit(_ query: PathQuery, access: FileAccessPolicy, usage: UsageSnapshot,
                       deliver: @escaping @MainActor @Sendable (PathSearchResponse) -> Void) {
        hasWork = true
        let number = generation.value.wrappingAdd(1, ordering: .relaxed).newValue, generation = generation, engine = engine
        worker.async { [weak self] in
            let cancelled: @Sendable () -> Bool = { generation.value.load(ordering: .relaxed) != number }
            guard !cancelled() else { return }
            let result = engine.search(query, access: access, usage: usage, cancelled: cancelled)
            guard !cancelled() else { return }
            Task { @MainActor in
                guard self != nil, !cancelled() else { return }
                deliver(result)
            }
        }
    }
}
