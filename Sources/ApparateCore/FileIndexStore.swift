import Foundation
import SQLite3

/// Each instance is confined to its owning actor. Both owners use the same migration.
final class IndexConnection: @unchecked Sendable {
    let db: OpaquePointer
    init(_ url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw UsageError(description: "Index database could not be opened.")
        }
        db = pointer; sqlite3_busy_timeout(db, 3000)
        do {
            try exec("PRAGMA journal_mode=WAL")
            let version = try integer("PRAGMA user_version")
            guard (0...3).contains(version) else { throw UsageError(description: "Unsupported index database version.") }
            try exec("BEGIN IMMEDIATE")
            try exec("CREATE TABLE IF NOT EXISTS usage (item_id TEXT PRIMARY KEY, decayed_count REAL NOT NULL, last_update REAL NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS file_nodes (generation INTEGER NOT NULL, id INTEGER NOT NULL, parent INTEGER NOT NULL, name TEXT NOT NULL, kind INTEGER NOT NULL, details BLOB NOT NULL, PRIMARY KEY(generation,id)) WITHOUT ROWID")
            try exec("CREATE TABLE IF NOT EXISTS file_state (singleton INTEGER PRIMARY KEY CHECK(singleton=1), generation INTEGER NOT NULL, details BLOB NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS open_with (content_type TEXT PRIMARY KEY, application TEXT NOT NULL, last_used REAL NOT NULL)")
            try exec("PRAGMA user_version=3; COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    deinit { sqlite3_close(db) }
    func failure() -> UsageError { UsageError(description: String(cString: sqlite3_errmsg(db))) }
    func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() } }
    func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }; return try body(statement)
    }
    func integer(_ sql: String) throws -> Int64 {
        try statement(sql) { s in guard sqlite3_step(s) == SQLITE_ROW else { throw failure() }; return sqlite3_column_int64(s, 0) }
    }
    func done(_ s: OpaquePointer) throws { guard sqlite3_step(s) == SQLITE_DONE else { throw failure() } }
    func bind(_ value: String, _ s: OpaquePointer, _ i: Int32) {
        _ = value.withCString { sqlite3_bind_text(s, i, $0, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    func bind(_ data: Data, _ s: OpaquePointer, _ i: Int32) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(s, i, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    func data(_ s: OpaquePointer, _ i: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(s, i))
        guard count > 0, let pointer = sqlite3_column_blob(s, i) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }
}

public struct FileCheckpoint: Codable, Sendable, Equatable {
    public var path: String
    public var device: Int32
    public var uuid: String?
    public var eventID: UInt64
    public init(path: String = "", device: Int32, uuid: String?, eventID: UInt64) { self.path = path; self.device = device; self.uuid = uuid; self.eventID = eventID }
}
struct FileDiskState: Codable, Sendable {
    var roots: [FileRoot]
    var free: [Int32]
    var slots: Int
    var count: Int
    var revision: UInt64
    var lastUpdate: Date?
    var skipHiddenFiles: Bool?
    var signature: String
    var checkpoints: [FileCheckpoint]
    var dirty: Set<String>
}
public struct StoredFileIndex: Sendable {
    public let snapshot: FileIndexSnapshot
    public let signature: String
    public let checkpoints: [FileCheckpoint]
    public let dirtyPaths: Set<String>
    public let readMS: Double
    public let prepareMS: Double
}
public actor FileIndexStore {
    private let connection: IndexConnection
    private var generation: Int64?
    private var saving = false
    /// Deterministic transaction failure injection, confined to fixture stores.
    public var failBeforeActivation = false
    public func injectActivationFailure(_ value: Bool) { failBeforeActivation = value }
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        connection = try IndexConnection(directory.appendingPathComponent("index.sqlite"))
    }
    public func load() throws -> StoredFileIndex? {
        let start = ContinuousClock.now, db = connection
        let stored: (Int64, Data)? = try db.statement("SELECT generation,details FROM file_state WHERE singleton=1") { s in
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw db.failure() }
            return (sqlite3_column_int64(s, 0), db.data(s, 1))
        }
        guard let (generation, data) = stored else { return nil }
        let state = try JSONDecoder().decode(FileDiskState.self, from: data)
        guard state.slots >= 0, state.slots < Int(Int32.max), state.count <= state.slots else { throw SourceError("The file index is invalid.") }
        var arrays = Array(repeating: [FileNode?](repeating: nil, count: FileChunk.size), count: (state.slots + FileChunk.size - 1) / FileChunk.size)
        try db.statement("SELECT id,details FROM file_nodes WHERE generation=? ORDER BY id") { s in
            sqlite3_bind_int64(s, 1, generation)
            var status = sqlite3_step(s)
            let decoder = JSONDecoder()
            while status == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(s, 0))
                guard id >= 0, id < state.slots else { throw SourceError("The file index contains an invalid node.") }
                arrays[id / FileChunk.size][id % FileChunk.size] = try decoder.decode(FileNode.self, from: db.data(s, 1))
                status = sqlite3_step(s)
            }
            guard status == SQLITE_DONE else { throw db.failure() }
        }
        let readMS = durationMS(start.duration(to: .now)), prepare = ContinuousClock.now
        var snapshot = FileIndexSnapshot()
        snapshot.chunks = arrays.map(FileChunk.init); snapshot.roots = state.roots; snapshot.free = state.free
        snapshot.slots = state.slots; snapshot.count = state.count; snapshot.revision = state.revision; snapshot.lastUpdate = state.lastUpdate
        snapshot.skipHiddenFiles = state.skipHiddenFiles ?? false
        // Validate graph links before the snapshot can reach search (including cycle bounds).
        for root in snapshot.roots { guard snapshot.node(root.node) != nil else { throw SourceError("The file index root is invalid.") } }
        for id in 0..<snapshot.slots {
            guard let node = snapshot.node(Int32(id)) else { continue }
            guard node.parent < 0 || snapshot.node(node.parent) != nil,
                  node.children.allSatisfy({ snapshot.node($0)?.parent == Int32(id) }) else { throw SourceError("The file index graph is invalid.") }
            var parent = node.parent, depth = 0
            while parent >= 0 { depth += 1; guard depth < 512 else { throw SourceError("The file index graph has a cycle.") }; parent = snapshot.node(parent)?.parent ?? -1 }
        }
        snapshot.prepareApplications()
        self.generation = generation
        return StoredFileIndex(snapshot: snapshot, signature: state.signature, checkpoints: state.checkpoints, dirtyPaths: state.dirty,
                               readMS: readMS, prepareMS: durationMS(prepare.duration(to: .now)))
    }
    public func save(_ result: FileCrawlResult, signature: String, checkpoints: [FileCheckpoint], replacing: Bool) async throws {
        while saving { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation(); saving = true; defer { saving = false }
        let db = connection, snapshot = result.snapshot
        let state = FileDiskState(roots: snapshot.roots, free: snapshot.free, slots: snapshot.slots, count: snapshot.count,
                                  revision: snapshot.revision, lastUpdate: snapshot.lastUpdate, skipHiddenFiles: snapshot.skipHiddenFiles, signature: signature, checkpoints: checkpoints, dirty: result.dirtyPaths)
        let stateData = try JSONEncoder().encode(state)
        let replace = replacing || generation == nil
        let target = replace ? try db.integer("SELECT COALESCE(MAX(generation),0)+1 FROM file_nodes") : generation!
        let chunks = replace ? Array(snapshot.chunks.indices) : result.changedChunks.sorted()
        func write(_ indices: ArraySlice<Int>) throws {
            try db.statement("DELETE FROM file_nodes WHERE generation=? AND id>=? AND id<?") { remove in
                try db.statement("INSERT INTO file_nodes(generation,id,parent,name,kind,details) VALUES(?,?,?,?,?,?)") { insert in
                    let encoder = JSONEncoder()
                    for chunk in indices {
                        sqlite3_bind_int64(remove, 1, target); sqlite3_bind_int(remove, 2, Int32(chunk * FileChunk.size)); sqlite3_bind_int(remove, 3, Int32((chunk + 1) * FileChunk.size))
                        try db.done(remove); sqlite3_reset(remove)
                        for offset in snapshot.chunks[chunk].nodes.indices {
                            guard let node = snapshot.chunks[chunk].nodes[offset] else { continue }
                            sqlite3_bind_int64(insert, 1, target); sqlite3_bind_int(insert, 2, Int32(chunk * FileChunk.size + offset))
                            sqlite3_bind_int(insert, 3, node.parent); db.bind(node.name, insert, 4); sqlite3_bind_int(insert, 5, Int32(node.metadata.type.rawValue))
                            db.bind(try encoder.encode(node), insert, 6); try db.done(insert); sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                        }
                    }
                }
            }
        }
        func activate() throws {
            if failBeforeActivation { throw SourceError("Injected file-index activation failure.") }
            try db.statement("INSERT INTO file_state(singleton,generation,details) VALUES(1,?,?) ON CONFLICT(singleton) DO UPDATE SET generation=excluded.generation,details=excluded.details") { s in
                sqlite3_bind_int64(s, 1, target); db.bind(stateData, s, 2); try db.done(s)
            }
        }
        if replace {
            for start in stride(from: 0, to: chunks.count, by: 4) {
                try Task.checkCancellation()
                try db.transaction { try write(chunks[start..<min(start + 4, chunks.count)]) }
                await Task.yield()
            }
            try Task.checkCancellation()
            try db.transaction { try activate() }
        } else {
            try Task.checkCancellation()
            try db.transaction { try write(chunks[...]); try activate() }
        }
        generation = target
        // Old/staged generations never affect reads; bounded cleanup yields to usage writes.
        while true {
            try Task.checkCancellation()
            try db.transaction {
                try db.statement("DELETE FROM file_nodes WHERE (generation,id) IN (SELECT generation,id FROM file_nodes WHERE generation<>? LIMIT 1024)") { s in
                    sqlite3_bind_int64(s, 1, target); try db.done(s)
                }
            }
            if sqlite3_changes(db.db) == 0 { break }
            await Task.yield()
        }
    }
}
