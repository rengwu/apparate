import Foundation
import Synchronization

public struct SearchRequest: Sendable {
    public let generation: UInt64
    public let index: SearchIndex
    public let query: ParsedQuery
    public let usage: UsageSnapshot
}
public struct SearchResponse: Sendable {
    public let generation: UInt64
    public let query: ParsedQuery
    public let results: [SearchResult]
}
private final class SearchGeneration: Sendable { let value = Atomic<UInt64>(0) }

/// Submissions, invalidation and the final guard + callback are synchronous on MainActor.
/// The serial worker never publishes directly. Changes to config/index resubmit or invalidate.
@MainActor
public final class SearchCoordinator {
    public typealias Engine = @Sendable (SearchRequest, @Sendable () -> Bool) -> [SearchResult]
    private let generation = SearchGeneration()
    // Package visibility lets the executable tests enqueue a fence after delivery is queued.
    package let worker = DispatchQueue(label: "local.apparate.search", qos: .userInitiated)
    private let engine: Engine
    public init(engine: @escaping Engine = { request, cancelled in
        request.index.search(request.query, usage: request.usage, isCancelled: cancelled)
    }) { self.engine = engine }

    @discardableResult public func invalidate() -> UInt64 {
        generation.value.wrappingAdd(1, ordering: .relaxed).newValue
    }

    @discardableResult public func submit(index: SearchIndex, query: ParsedQuery, usage: UsageSnapshot = UsageSnapshot(),
                                         deliver: @escaping @MainActor @Sendable (SearchResponse) -> Void) -> UInt64 {
        let number = invalidate(), token = generation, engine = engine
        let request = SearchRequest(generation: number, index: index, query: query, usage: usage)
        worker.async { [weak self] in
            let cancelled: @Sendable () -> Bool = { token.value.load(ordering: .relaxed) != number }
            guard !cancelled() else { return }
            let results = engine(request, cancelled)
            guard !cancelled() else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation.value.load(ordering: .relaxed) == number else { return }
                deliver(SearchResponse(generation: number, query: query, results: results))
            }
        }
        return number
    }
}
