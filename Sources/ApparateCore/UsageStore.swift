import Foundation
import SQLite3

public struct UsageSnapshot: Sendable {
    let boosts: [String: Double]
    let identity = UUID()
    public init(counts: [String: Double] = [:], lambda: Double = 0.5) {
        // The bound is part of ranking, even if a caller supplies an invalid count.
        boosts = counts.mapValues { count in
            guard count.isFinite, count > 0 else { return 0 }
            return max(0, min(0.5, lambda)) * min(1, log1p(count) / log1p(20))
        }
    }
    public func boost(for id: String) -> Double { boosts[id] ?? 0 }
}

public struct UsageError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

public actor UsageStore {
    public static let halfLife: TimeInterval = 30 * 24 * 60 * 60
    private let connection: IndexConnection
    private let clock: @Sendable () -> TimeInterval
    private var db: OpaquePointer { connection.db }

    public init(directory: URL, clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        connection = try IndexConnection(directory.appendingPathComponent("index.sqlite"))
        self.clock = clock
    }

    public func counts() throws -> [String: Double] { try counts(at: clock()) }
    public func snapshot() throws -> UsageSnapshot { UsageSnapshot(counts: try counts()) }

    /// Call only after an action succeeds. Merely viewing or selecting a row never records usage.
    public func recordSuccessfulOpen(id: String) throws {
        let now = clock()
        guard now.isFinite else { throw UsageError(description: "Usage clock is not finite.") }
        try exec("BEGIN IMMEDIATE")
        do {
            var counts = try counts(at: now)
            let count = (counts[id] ?? 0) + 1
            try statement("INSERT INTO usage(item_id, decayed_count, last_update) VALUES (?, ?, ?) ON CONFLICT(item_id) DO UPDATE SET decayed_count=excluded.decayed_count, last_update=excluded.last_update") { s in
                bind(id, to: s, at: 1); sqlite3_bind_double(s, 2, count); sqlite3_bind_double(s, 3, now)
                try done(s)
            }
            counts[id] = count
            if counts.count > 2000 {
                let remove = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }.prefix(counts.count - 2000)
                try statement("DELETE FROM usage WHERE item_id = ?") { s in
                    for entry in remove { bind(entry.key, to: s, at: 1); try done(s); sqlite3_reset(s); sqlite3_clear_bindings(s) }
                }
            }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    private func counts(at now: TimeInterval) throws -> [String: Double] {
        var values: [String: Double] = [:]
        try statement("SELECT item_id, decayed_count, last_update FROM usage") { s in
            var status = sqlite3_step(s)
            while status == SQLITE_ROW {
                let id = String(decoding: UnsafeBufferPointer(start: sqlite3_column_text(s, 0), count: Int(sqlite3_column_bytes(s, 0))), as: UTF8.self)
                let count = sqlite3_column_double(s, 1), time = sqlite3_column_double(s, 2)
                values[id] = max(0, count) * pow(0.5, max(0, now - time) / Self.halfLife)
                status = sqlite3_step(s)
            }
            guard status == SQLITE_DONE else { throw failure() }
        }
        return values
    }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() } }
    private func statement<T>(_ sql: String, _ action: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw failure() }
        defer { sqlite3_finalize(pointer) }
        return try action(pointer)
    }
    private func bind(_ value: String, to statement: OpaquePointer, at position: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, position, $0, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func done(_ statement: OpaquePointer) throws { guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() } }
    private func failure() -> UsageError { UsageError(description: String(cString: sqlite3_errmsg(db))) }
}
