import Foundation
import Darwin

public struct FileChange: Sendable, Codable {
    public var path: String
    public var recursive: Bool
    public init(path: String, recursive: Bool = false) { self.path = path; self.recursive = recursive }
}
public struct FileCrawlResult: Sendable {
    public var snapshot: FileIndexSnapshot
    public var dirtyPaths: Set<String>
    public var listedDirectories: Int
    public var preparedChunks: Int
    var changedChunks: Set<Int>
}
public struct FileCrawler: Sendable {
    public var reader: FileReading
    public init(reader: FileReading = FileReading()) { self.reader = reader }
    public func crawl(folders: [AppConfig.Folder], respectGitignore: Bool, skipHiddenFiles: Bool = false, access: FileAccessPolicy,
                      previous: FileIndexSnapshot = FileIndexSnapshot()) async throws -> FileCrawlResult {
        var work = CrawlWork(reader: reader, access: access, respect: respectGitignore, skipHidden: skipHiddenFiles, previous: previous)
        let roots = folders.map { FileRoot(path: $0.path, depth: $0.depth) }.sorted { $0.path < $1.path }
        if roots.map(\.path) == previous.roots.map(\.path) {
            work.builder = FileIndexBuilder(previous)
            for i in roots.indices { work.builder.roots[i].depth = roots[i].depth; work.builder.roots[i].status = .indexing }
        } else {
            work.builder.roots = roots
            work.makeRootNodes()
        }
        for r in work.builder.roots.indices { try await work.scanRoot(Int32(r)) }
        work.removeHiddenMemberships()
        return work.finish()
    }
    public func update(_ snapshot: FileIndexSnapshot, changes: [FileChange], respectGitignore: Bool, skipHiddenFiles: Bool? = nil,
                       access: FileAccessPolicy, dirtyPaths: Set<String> = []) async throws -> FileCrawlResult {
        let skipHidden = skipHiddenFiles ?? snapshot.skipHiddenFiles
        if skipHidden != snapshot.skipHiddenFiles {
            return try await crawl(folders: snapshot.roots.map { .init(path: $0.path, depth: $0.depth) }, respectGitignore: respectGitignore, skipHiddenFiles: skipHidden, access: access, previous: snapshot)
        }
        let changes = changes.map { FileChange(path: AppConfig.normalizedFolder($0.path, home: ""), recursive: $0.recursive) }
        var work = CrawlWork(reader: reader, access: access, respect: respectGitignore, skipHidden: skipHidden, previous: snapshot)
        work.builder = FileIndexBuilder(snapshot); work.dirty = dirtyPaths
        for r in snapshot.roots.indices {
            let root = snapshot.roots[r]
            let relevant = changes.filter { pathIsWithin($0.path, root.path) || pathIsWithin(root.path, $0.path) }
            guard !relevant.isEmpty else { continue }
            work.builder.roots[r].status = .indexed
            var requests: [String: Bool] = [:]
            for change in relevant {
                var path = pathIsWithin(root.path, change.path) ? root.path : change.path
                let parts = path.dropFirst(root.path.count).split(separator: "/")
                if parts.contains("node_modules") || parts.dropLast().contains(where: { $0.hasPrefix(".") }) { continue }
                // Dot children are terminal for this root. Refresh their entry from the
                // parent, including a recursive event; an explicit dot root has no suffix.
                if parts.last?.hasPrefix(".") == true { path = parentPath(path) }
                // Bundle metadata changes are reported below the package path. Refresh the
                // terminal app from its parent; never enumerate package contents as files.
                var ancestor = path, terminal = false
                while ancestor != root.path && pathIsWithin(ancestor, root.path) {
                    if let known = work.builder.find(ancestor).flatMap(work.builder.node) {
                        if known.metadata.type == .application { path = parentPath(ancestor); break }
                        if known.metadata.type == .package || known.metadata.type == .link { terminal = true; break }
                    }
                    ancestor = parentPath(ancestor)
                }
                if terminal { continue }
                if respectGitignore {
                    do { if try work.inheritedScopes(root: root, path: path) == nil { continue } }
                    catch { /* A failed rule read must reach the normal unavailable/retry path. */ }
                }
                while path != root.path && (work.builder.find(path).flatMap(work.builder.node)?.metadata.type != .directory) { path = parentPath(path) }
                if let n = work.builder.find(path).flatMap(work.builder.node), let current = try? reader.metadata(path),
                   current.type != .directory || n.metadata.inode != current.inode || n.metadata.device != current.device {
                    path = path == root.path ? path : parentPath(path)
                }
                requests[path] = (requests[path] ?? false) || change.recursive
            }
            // A recursive parent covers every descendant request in the batch.
            for path in requests.keys.sorted() {
                if requests.contains(where: { $0.key != path && $0.value && pathIsWithin(path, $0.key) }) { continue }
                if path == root.path { try await work.scanRoot(Int32(r), recursive: requests[path]!) }
                else if let id = work.builder.find(path) {
                    do {
                        guard let scopes = try work.inheritedScopes(root: root, path: path) else { continue }
                        let depth = path.dropFirst(root.path.count).split(separator: "/").count
                        try await work.scanDirectory(id, root: Int32(r), depth: depth, scopes: scopes, recursive: requests[path]!)
                    } catch is CancellationError { throw CancellationError() }
                    catch { work.failed(path, id: id, root: Int32(r), error: error) }
                }
            }
        }
        return work.finish()
    }
}

private struct CrawlWork {
    let reader: FileReading
    let access: FileAccessPolicy
    let respect: Bool
    let skipHidden: Bool
    let previous: FileIndexSnapshot
    var builder = FileIndexBuilder()
    var dirty: Set<String> = []
    var listed = 0

    mutating func makeRootNodes() {
        for r in builder.roots.indices.sorted(by: { builder.roots[$0].path.count < builder.roots[$1].path.count }) {
            let path = builder.roots[r].path
            let outer = builder.roots.indices.filter { $0 != r && builder.roots[$0].node >= 0 && pathIsWithin(path, builder.roots[$0].path) }
                .min { builder.roots[$0].path.count < builder.roots[$1].path.count }
            if let outer {
                var parent = builder.roots[outer].node
                for component in path.dropFirst(builder.roots[outer].path.count).split(separator: "/") {
                    if let found = builder.node(parent)?.children.first(where: { builder.node($0)?.name == String(component) }) { parent = found }
                    else {
                        let id = builder.add(FileNode(name: String(component), parent: parent, metadata: FileMetadata(type: .directory)))
                        var n = builder.node(parent)!; n.children.append(id); builder.set(parent, n); parent = id
                    }
                }
                builder.roots[r].node = parent
            } else {
                builder.roots[r].node = builder.add(FileNode(name: URL(fileURLWithPath: path).lastPathComponent, parent: -1,
                                                            metadata: FileMetadata(type: .directory), anchor: path))
            }
        }
    }
    mutating func scanRoot(_ root: Int32, recursive: Bool = true) async throws {
        let path = builder.roots[Int(root)].path, id = builder.roots[Int(root)].node
        if let blocked = access.blocked(path) {
            builder.roots[Int(root)].status = blocked; builder.markUnavailable(id); return
        }
        do {
            let metadata = try reader.metadata(path)
            guard metadata.type == .directory else { throw FileReading.failure(ENOTDIR) }
            var n = builder.node(id)!; n.metadata = metadata; builder.set(id, n); builder.include(id, root: root)
            builder.roots[Int(root)].ignoreCase = reader.ignoresCase(path)
            builder.roots[Int(root)].status = .indexed
            try await scanDirectory(id, root: root, depth: 0, scopes: [], recursive: recursive)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if builder.roots[Int(root)].count == 0, let old = previous.find(path) {
                copyPrevious(old, to: id, root: root)
            }
            failed(path, id: id, root: root, error: error)
        }
    }
    mutating func copyPrevious(_ old: Int32, to id: Int32, root: Int32) {
        guard let source = previous.node(old), var target = builder.node(id) else { return }
        target.metadata = source.metadata; target.application = source.application; target.ruleHash = source.ruleHash; builder.set(id, target)
        if source.visible { builder.include(id, root: root) }
        for child in source.children {
            guard let c = previous.node(child) else { continue }
            let next = builder.add(FileNode(name: c.name, parent: id, metadata: c.metadata))
            target = builder.node(id)!; target.children.append(next); builder.set(id, target)
            copyPrevious(child, to: next, root: root)
        }
    }
    mutating func failed(_ path: String, id: Int32, root: Int32, error: Error) {
        builder.markUnavailable(id); dirty.insert(path)
        let e = error as NSError, underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError ?? e
        let code = underlying.domain == NSPOSIXErrorDomain ? underlying.code : -1
        if code == Int(EACCES) || code == Int(EPERM) || e.code == NSFileReadNoPermissionError { builder.roots[Int(root)].status = .denied }
        else if path == builder.roots[Int(root)].path && [Int(ENOENT), Int(ENOTDIR)].contains(code) { builder.roots[Int(root)].status = .notFound }
        else { builder.roots[Int(root)].status = .unavailable }
    }
    func inheritedScopes(root: FileRoot, path: String) throws -> [IgnoreScope]? {
        var scopes: [IgnoreScope] = [], current = root.path
        let components = path.dropFirst(root.path.count).split(separator: "/")
        for component in components {
            guard access.blocked(current) == nil else { return nil }
            guard try reader.metadata(current).type == .directory else { return nil }
            if respect, let data = try reader.ignoreContents(current) {
                scopes.append(IgnoreScope(directory: current, rules: GitIgnore(String(decoding: data, as: UTF8.self), ignoreCase: root.ignoreCase)))
            }
            current = appendPath(current, String(component))
            var excluded = false
            for scope in scopes { if let choice = scope.decision(current, directory: true) { excluded = choice } }
            if excluded { return nil }
        }
        return scopes
    }
    mutating func scanDirectory(_ id: Int32, root: Int32, depth: Int, scopes inherited: [IgnoreScope], recursive: Bool) async throws {
        try Task.checkCancellation()
        let path = builder.path(id)
        if let blocked = access.blocked(path) {
            builder.markUnavailable(id); builder.roots[Int(root)].status = blocked; return
        }
        guard var directory = builder.node(id) else { return }
        if depth >= builder.roots[Int(root)].depth {
            for child in directory.children { builder.excludeTree(child, root: root) }
            directory.children.removeAll { builder.node($0) == nil }; builder.set(id, directory); return
        }
        // All reads succeed before deletions become evidence; a failed listing is not empty.
        let names = try reader.children(path); listed += 1
        var children: [(String, FileMetadata)] = []
        for name in names where name != "node_modules" && (!skipHidden || !name.hasPrefix(".")) {
            let full = appendPath(path, name)
            if access.blocked(full) != nil { continue }
            do { children.append((name, try reader.metadata(full))) }
            catch {
                let e = error as NSError
                if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT) { continue }
                throw error
            }
        }
        let rules = respect ? try reader.ignoreContents(path) : nil
        let hash = rules?.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 } ?? 0
        let rescan = recursive || directory.ruleHash != hash
        directory.ruleHash = hash; directory.unavailable = false
        var scopes = inherited
        if let rules { scopes.append(IgnoreScope(directory: path, rules: GitIgnore(String(decoding: rules, as: UTF8.self), ignoreCase: builder.roots[Int(root)].ignoreCase))) }
        var existing = Dictionary(uniqueKeysWithValues: directory.children.compactMap { child in builder.node(child).map { ($0.name, child) } })
        var retained: [Int32] = [], descend: [(Int32, Bool)] = []
        for (name, metadata) in children {
            let full = appendPath(path, name)
            var excluded = false
            for scope in scopes { if let choice = scope.decision(full, directory: metadata.type == .directory || metadata.type == .package || metadata.type == .application) { excluded = choice } }
            guard !excluded else { continue }
            let child: Int32, isNew: Bool
            if let found = existing.removeValue(forKey: name), var old = builder.node(found) {
                child = found
                isNew = !old.belongs(to: root) || old.metadata.type != metadata.type || old.metadata.device != metadata.device || old.metadata.inode != metadata.inode
                if isNew {
                    for descendant in old.children { builder.excludeTree(descendant, root: root) }
                    old.children.removeAll { builder.node($0) == nil }
                }
                old.metadata = metadata; if metadata.type != .application { old.application = nil }; builder.set(child, old)
            } else { child = builder.add(FileNode(name: name, parent: id, metadata: metadata)); isNew = true }
            if metadata.type == .application {
                var app = builder.node(child)!; app.application = FileApplication(reader.application(full)); builder.set(child, app)
            }
            builder.include(child, root: root); retained.append(child)
            if metadata.type == .directory && !name.hasPrefix(".") { descend.append((child, rescan || isNew)) }
        }
        for child in existing.values {
            if let blocked = access.blocked(builder.path(child)) {
                builder.markUnavailable(child); builder.roots[Int(root)].status = blocked
            } else { builder.excludeTree(child, root: root) }
            if builder.node(child) != nil { retained.append(child) }
        }
        directory.children = retained.sorted { (builder.node($0)?.name ?? "") < (builder.node($1)?.name ?? "") }
        builder.set(id, directory); dirty.remove(path)
        for (child, needsScan) in descend where needsScan {
            do { try await scanDirectory(child, root: root, depth: depth + 1, scopes: scopes, recursive: true) }
            catch is CancellationError { throw CancellationError() }
            catch { failed(builder.path(child), id: child, root: root, error: error) }
        }
        await Task.yield()
    }
    mutating func removeHiddenMemberships() {
        guard skipHidden else { return }
        // A failed listing may retain old nodes from the previous policy. Remove
        // only memberships below roots; explicit roots keep their own ownership.
        for offset in 0..<builder.slots {
            let id = Int32(offset)
            guard let node = builder.node(id), node.visible, node.name.hasPrefix(".") else { continue }
            for root in [node.owner] + node.otherOwners where root >= 0 && builder.roots[Int(root)].node != id {
                builder.excludeTree(id, root: root)
            }
            if var parent = builder.node(node.parent) {
                parent.children.removeAll { builder.node($0) == nil }; builder.set(node.parent, parent)
            }
        }
    }
    mutating func finish() -> FileCrawlResult {
        builder.base.skipHiddenFiles = skipHidden
        let changed = Set(builder.edits.keys)
        return FileCrawlResult(snapshot: builder.finish(), dirtyPaths: dirty, listedDirectories: listed,
                               preparedChunks: changed.count, changedChunks: changed)
    }
}
