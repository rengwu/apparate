import Foundation
import ApparateCore
import Synchronization

final class TestClock: Sendable {
    let time = Mutex<Double>(1_000_000)
    func now() -> Double { time.withLock { $0 } }
    func advance(_ amount: Double) { time.withLock { $0 += amount } }
}

@MainActor func usageTests(_ h: Harness) async {
    await h.test("usage: finite scores, bounded boost and tier/kind boundaries") {
        let items = [fixture("Terminal", id: "a"), fixture("Terminus", id: "b"), fixture("term", .file, id: "exact-file"),
                     fixture("term.txt", .file, id: "file"), fixture("The enormous river map", id: "fuzzy")]
        let first = try search(items, "term")
        try expect(first[1].item.id == "a")
        let used = try search(items, "term", usage: UsageSnapshot(counts: ["b": 20, "file": 1e100, "fuzzy": 100]))
        try expect(used.map(\.item.id) == ["exact-file", "b", "a", "file", "fuzzy"], "Usage rank: \(used.map(\.item.id))")
        try expect(used.allSatisfy { $0.textScore.isFinite && $0.usageBoost <= 0.5 })
        try near(UsageSnapshot(counts: ["a": 20]).boost(for: "a"), 0.5)
    }
    await h.test("usage: injected decay clock, snapshots and persistence after reopening") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        var store: UsageStore? = try UsageStore(directory: dir, clock: clock.now)
        for _ in 0..<20 { try await store!.recordSuccessfulOpen(id: "fixture:frequent") }
        let before = try await store!.snapshot()
        clock.advance(UsageStore.halfLife)
        let counts = try await store!.counts()
        try near(counts["fixture:frequent"]!, 10)
        let after = try await store!.snapshot()
        try near(before.boost(for: "fixture:frequent"), 0.5)
        try near(after.boost(for: "fixture:frequent"), 0.5 * log1p(10) / log1p(20))
        store = nil
        let reopened = try UsageStore(directory: dir, clock: clock.now)
        let reopenedCounts = try await reopened.counts()
        try near(reopenedCounts["fixture:frequent"]!, 10)
        try await reopened.recordSuccessfulOpen(id: "fixture:frequent")
        let updated = try await reopened.counts()
        try near(updated["fixture:frequent"]!, 11)
        // Snapshot remains a value after the database changes.
        try near(after.boost(for: "fixture:frequent"), 0.5 * log1p(10) / log1p(20))
        try await reopened.recordSuccessfulOpen(id: "opaque\0one")
        try await reopened.recordSuccessfulOpen(id: "opaque")
        let opaque = try await reopened.counts()
        try expect(opaque["opaque\0one"] == 1 && opaque["opaque"] == 1)
    }
    await h.test("usage: 2000-record bound and deterministic eviction") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try UsageStore(directory: dir, clock: { 1_000_000 })
        for i in 0..<2005 { try await store.recordSuccessfulOpen(id: String(format: "fixture:%04d", i)) }
        let counts = try await store.counts()
        try expect(counts.count == 2000 && counts["fixture:0000"] == nil && counts["fixture:0004"] == nil && counts["fixture:0005"] == 1)
    }
}

@MainActor func coordinatorTests(_ h: Harness) async {
    await h.test("generations: slow work and a query burst publish only the newest") {
        let index = try SearchIndex(items: [fixture("Alpha"), fixture("Beta")])
        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let cancelled = Mutex(false)
        let coordinator = SearchCoordinator { request, isCancelled in
            if request.query.text == "a" {
                started.signal(); _ = finish.wait(timeout: .now() + 3)
                cancelled.withLock { $0 = isCancelled() }
            }
            return request.index.search(request.query, usage: request.usage, isCancelled: isCancelled)
        }
        var delivered: [SearchResponse] = []
        coordinator.submit(index: index, query: ParsedQuery("a")) { delivered.append($0) }
        try expect(started.wait(timeout: .now() + 3) == .success)
        for text in ["al", "alp", "b", "be", "beta"] { coordinator.submit(index: index, query: ParsedQuery(text)) { delivered.append($0) } }
        finish.signal()
        try await eventually { !delivered.isEmpty }
        try expect(delivered.count == 1 && delivered[0].query.text == "beta" && delivered[0].results.first?.item.name == "Beta")
        try expect(cancelled.withLock { $0 })
    }
    await h.test("generations: invalidation after scoring and before owner delivery") {
        let index = try SearchIndex(items: [fixture("Alpha")]), queued = DispatchSemaphore(value: 0)
        let coordinator = SearchCoordinator { request, cancelled in
            let rows = request.index.search(request.query, isCancelled: cancelled)
            return rows
        }
        var delivered: [SearchResponse] = []
        coordinator.submit(index: index, query: ParsedQuery("alpha")) { delivered.append($0) }
        // This fence runs after the worker has enqueued its MainActor delivery task.
        // Keep the owner occupied until then, invalidate, and only then yield to that task.
        coordinator.worker.async { queued.signal() }
        try expect(queued.wait(timeout: .now() + 3) == .success)
        coordinator.invalidate()
        try await Task.sleep(for: .milliseconds(80))
        try expect(delivered.isEmpty)
        coordinator.submit(index: try SearchIndex(items: [fixture("Alpine")]), query: ParsedQuery("alp")) { delivered.append($0) }
        try await eventually { delivered.count == 1 }
        try expect(delivered[0].results.first?.item.name == "Alpine")
    }
}
