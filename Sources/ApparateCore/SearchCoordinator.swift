import Foundation
import Synchronization
import Darwin

public struct SearchRequest: Sendable {
    public let generation: UInt64
    public let index: SearchIndex
    public let query: ParsedQuery
    public let files: FileIndexSnapshot?
    public let usage: UsageSnapshot
}
public struct SearchResponse: Sendable {
    public let generation: UInt64
    public let query: ParsedQuery
    public let results: [SearchResult]
}
public struct SearchTrace: Sendable {
    public let generation: UInt64
    public let submitted: ContinuousClock.Instant, started: ContinuousClock.Instant, finished: ContinuousClock.Instant
    public let cancelled: Bool
    public let cpuNanoseconds: UInt64
}
package enum SearchDelivery: String, Sendable { case task, dispatch }
private final class SearchGeneration: Sendable { let value = Atomic<UInt64>(0) }

/// Submissions, invalidation and the final guard + callback are synchronous on MainActor.
/// The serial worker never publishes directly. Changes to config/index resubmit or invalidate.
@MainActor
public final class SearchCoordinator {
    public typealias Engine = @Sendable (SearchRequest, @Sendable () -> Bool) -> [SearchResult]
    private let generation = SearchGeneration()
    // Package visibility lets the executable tests enqueue a fence after delivery is queued.
    package let worker = DispatchQueue(label: "local.apparate.search", qos: .userInitiated)
    package var delivery = SearchDelivery.task
    package var onDelivery: ((UInt64, ContinuousClock.Instant) -> Void)?
    private let engine: Engine?
    private let observe: (@Sendable (SearchTrace) -> Void)?
    private let fileUsage = FileUsageCache()
    public init(engine: Engine? = nil, observe: (@Sendable (SearchTrace) -> Void)? = nil) { self.engine = engine; self.observe = observe }

    @discardableResult public func invalidate() -> UInt64 {
        generation.value.wrappingAdd(1, ordering: .relaxed).newValue
    }

    @discardableResult public func submit(index: SearchIndex, query: ParsedQuery, files: FileIndexSnapshot? = nil, usage: UsageSnapshot = UsageSnapshot(),
                                         deliver: @escaping @MainActor @Sendable (SearchResponse) -> Void) -> UInt64 {
        let number = invalidate(), token = generation, engine = engine, fileUsage = fileUsage, observe = observe, delivery = delivery
        let submitted = ContinuousClock.now
        let request = SearchRequest(generation: number, index: index, query: query, files: files, usage: usage)
        worker.async { [weak self] in
            let cancelled: @Sendable () -> Bool = { token.value.load(ordering: .relaxed) != number }
            guard !cancelled() else { return }
            let started = ContinuousClock.now
            let cpuStart = observe == nil ? 0 : clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let results: [SearchResult]
            if let engine { results = engine(request, cancelled) }
            else if let files = request.files, request.query.scope != .web {
                let local = request.index.search(request.query, usage: request.usage, includeWebFallback: false, isCancelled: cancelled)
                let fileRows = files.search(request.query, boosts: fileUsage.resolve(files, request.usage), isCancelled: cancelled)
                let discoveredApps = files.applications?.index.search(request.query, usage: request.usage, includeWebFallback: false, isCancelled: cancelled) ?? []
                let merged = SearchResult.merge([local, fileRows, discoveredApps])
                results = merged.isEmpty ? request.index.search(request.query, usage: request.usage, isCancelled: cancelled) : merged
            } else { results = request.index.search(request.query, usage: request.usage, isCancelled: cancelled) }
            observe?(SearchTrace(generation: number, submitted: submitted, started: started, finished: .now, cancelled: cancelled(), cpuNanoseconds: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart))
            guard !cancelled() else { return }
            let publish: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                self.onDelivery?(number, .now)
                guard self.generation.value.load(ordering: .relaxed) == number else { return }
                deliver(SearchResponse(generation: number, query: query, results: results))
            }
            switch delivery {
            case .task: Task { @MainActor in publish() }
            case .dispatch: DispatchQueue.main.async { publish() }
            }
        }
        return number
    }
}
