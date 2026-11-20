import Foundation

extension AppConfig.HotKey {
    public static var openWithDefault: Self {
        var key = Self(); key.keyCode = 36; key.modifiers = 512; key.display = "⇧↩"; return key
    }
}
public enum OpenWithShortcut {
    // Carbon modifier masks, matching the persisted launcher shortcut format.
    public static func validation(_ key: AppConfig.HotKey, launcher: AppConfig.HotKey) -> String? {
        let flags = key.modifiers, code = key.keyCode
        guard code < 128, flags != 0, flags & ~UInt32(256 | 512 | 2048 | 4096) == 0 else {
            return "Open With needs a valid key and a modifier."
        }
        if code == launcher.keyCode && flags == launcher.modifiers { return "Open With conflicts with Open Apparate." }
        if [48, 53, 123, 124, 125, 126].contains(code) { return "That key is reserved for panel navigation." }
        let nonprinting: Set<UInt32> = [36, 76, 51, 117, 115, 119, 116, 121, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        if flags == 512 && !nonprinting.contains(code) { return "Use ⌘, ⌥ or ⌃ with a typing key for Open With." }
        // Preserve primary actions, numbered rows, quit, Settings and native editing.
        if flags == 256 && [36, 76, 8, 12, 43, 18, 19, 20, 21, 23, 22, 26, 28, 25, 0, 7, 9, 6].contains(code)
            || flags == 768 && code == 6 { return "That shortcut is already used by the panel or text editor." }
        return nil
    }
}

public struct OpenWithChoice: Sendable, Equatable {
    public let application: URL
    public let contentType: String?
    public init(application: URL, contentType: String?) { self.application = application; self.contentType = contentType }
}
public struct OpenWithDiscovery: Sendable {
    public let contentType: String?
    public let claimed: [CatalogEntry]
    public let defaultApplication: CatalogEntry?
    public let lastApplication: CatalogEntry?
    public init(contentType: String?, claimed: [CatalogEntry], defaultApplication: CatalogEntry? = nil, lastApplication: CatalogEntry? = nil) {
        self.contentType = contentType; self.claimed = claimed; self.defaultApplication = defaultApplication; self.lastApplication = lastApplication
    }
}
public struct OpenWithService: Sendable {
    public var discover: @Sendable (CatalogEntry, FileAccessPolicy) async throws -> OpenWithDiscovery
    public init(discover: @escaping @Sendable (CatalogEntry, FileAccessPolicy) async throws -> OpenWithDiscovery = { _,_ in
        throw SourceError("Open With is unavailable.")
    }) { self.discover = discover }
    public init(lookup: @escaping @Sendable (CatalogEntry, FileAccessPolicy) throws -> OpenWithDiscovery,
                application: @escaping @Sendable (URL) throws -> CatalogEntry,
                lastChoice: @escaping @Sendable (String) async throws -> URL?) {
        discover = { entry, access in
            let worker = Task.detached { try lookup(entry, access) }
            let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            var last: CatalogEntry?
            if let type = value.contentType, let url = try await lastChoice(type) {
                let reader = Task.detached { try? application(url) }
                last = await withTaskCancellationHandler { await reader.value } onCancel: { reader.cancel() }
            }
            try Task.checkCancellation()
            return OpenWithDiscovery(contentType: value.contentType, claimed: value.claimed, defaultApplication: value.defaultApplication, lastApplication: last)
        }
    }

}

/// Prepared once per discovery/catalog snapshot. Matching runs on a worker, never the UI thread.
package struct OpenWithIndex: Sendable {
    let groups: [SearchIndex]
    let entries: [String: CatalogEntry]
    let labels: [String: String]
    package init(discovery: OpenWithDiscovery, catalog: [CatalogEntry]) throws {
        var seen = Set<String>(), all: [String: CatalogEntry] = [:], labels: [String: String] = [:]
        var groups: [SearchIndex] = []
        for (group, candidates) in [[discovery.lastApplication].compactMap { $0 }, [discovery.defaultApplication].compactMap { $0 }, discovery.claimed, catalog].enumerated() {
            var items: [SearchItem] = []
            for entry in candidates.sorted(by: { $0.item.id < $1.item.id }) {
                guard entry.item.kind == .app, case .application(let original) = entry.target else { continue }
                let url = original.standardizedFileURL, id = "open-with:" + url.path
                guard seen.insert(id).inserted else { continue }
                let item = SearchItem(id: id, kind: .app, name: entry.item.name, alternateNames: entry.item.alternateNames)
                let label = group == 0 ? "Last used" : group == 1 ? "Default" : ""
                all[id] = CatalogEntry(item: item, target: .application(url), location: label, icon: entry.icon)
                labels[id] = label; items.append(item)
            }
            groups.append(try SearchIndex(items: items))
        }
        self.groups = groups; entries = all; self.labels = labels
    }
    package func rows(query: String) -> [PanelRow] {
        let query = ParsedQuery(literalName: query)
        var results: [SearchResult] = []
        for (group, index) in groups.enumerated() {
            if Task.isCancelled { return [] }
            if query.isEmpty {
                if group == 3 { break }
                let ordered = index.items.indices.sorted {
                    if index.text.less(Int32($0), Int32($1)) { return true }
                    if index.text.less(Int32($1), Int32($0)) { return false }
                    return index.items[$0].id < index.items[$1].id
                }
                results += ordered.prefix(50 - results.count).map { SearchResult(item: index.items[$0], tier: .exact, textScore: 0, usageBoost: 0, source: .name, highlights: [], webQuery: nil) }
            } else {
                results += index.search(query, limit: 50 - results.count, includeWebFallback: false, isCancelled: { Task.isCancelled })
            }
            if results.count == 50 { break }
        }
        return results.compactMap { result in entries[result.item.id].map { PanelRow(result: result, entry: $0, locationOverride: labels[result.item.id]) } }
    }
}

public struct OpenWithLookupError: Error, LocalizedError, Sendable {
    public let reason: String
    public let missingID: String?
    public init(_ reason: String, missingID: String? = nil) { self.reason = reason; self.missingID = missingID }
    public var errorDescription: String? { reason }
}

/// Check lexical and canonical destinations before Workspace/type metadata lookup.
public enum OpenWithAccess {
    public static func validate(_ url: URL, access: FileAccessPolicy,
                                canonical: @Sendable (String) -> String = FileFolderWatcher.canonical) throws {
        let denied = "Folder access is needed. Open Settings → Folders → Allow Access…"
        guard access.blocked(url.path) == nil else { throw SourceError(denied) }
        let protected = FileAccessPolicy(protectedPaths: Dictionary(access.protectedPaths.map { path, status in
            (appendPath(canonical(parentPath(path)), URL(fileURLWithPath: path).lastPathComponent), status)
        }, uniquingKeysWith: { first, second in first == .allowed ? second : first }))
        let destination = canonical(url.path)
        guard access.blocked(destination) == nil, protected.blocked(destination) == nil else { throw SourceError(denied) }
    }
}
