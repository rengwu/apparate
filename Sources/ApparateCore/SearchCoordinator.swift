import Foundation
import Synchronization
import Darwin

public struct SearchRequest: Sendable {
    public let generation: UInt64
    public let index: SearchIndex
    public let query: ParsedQuery
    public let files: FileIndexSnapshot?
    public let usage: UsageSnapshot
    package init(generation: UInt64, index: SearchIndex, query: ParsedQuery, files: FileIndexSnapshot?, usage: UsageSnapshot) {
        self.generation = generation; self.index = index; self.query = query; self.files = files; self.usage = usage
    }
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
    package let stages: [String: Double]
    package let submittedTicks: UInt64, startedTicks: UInt64, finishedTicks: UInt64
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
    private let pipeline = SearchPipeline()
    package var measureStages = false
    public init(engine: Engine? = nil, observe: (@Sendable (SearchTrace) -> Void)? = nil) { self.engine = engine; self.observe = observe }

    @discardableResult public func invalidate() -> UInt64 {
        generation.value.wrappingAdd(1, ordering: .relaxed).newValue
    }

    @discardableResult public func submit(index: SearchIndex, query: ParsedQuery, files: FileIndexSnapshot? = nil, usage: UsageSnapshot = UsageSnapshot(),
                                         deliver: @escaping @MainActor @Sendable (SearchResponse) -> Void) -> UInt64 {
        let number = invalidate(), token = generation, engine = engine, pipeline = pipeline, observe = observe, delivery = delivery, measureStages = measureStages
        let submitted = ContinuousClock.now
        let submittedTicks = observe == nil ? 0 : ObservationClock.now
        let request = SearchRequest(generation: number, index: index, query: query, files: files, usage: usage)
        worker.async { [weak self] in
            let cancelled: @Sendable () -> Bool = { token.value.load(ordering: .relaxed) != number }
            guard !cancelled() else { return }
            let started = ContinuousClock.now
            let startedTicks = observe == nil ? 0 : ObservationClock.now
            let cpuStart = observe == nil ? 0 : clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            var stages: [String: Double] = [:]
            let results: [SearchResult]
            if let engine { results = engine(request, cancelled) }
            else { results = pipeline.search(request, isCancelled: cancelled, stage: measureStages ? { stages[$0] = $1 } : nil) }
            observe?(SearchTrace(generation: number, submitted: submitted, started: started, finished: .now, cancelled: cancelled(), cpuNanoseconds: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart, stages: stages, submittedTicks: submittedTicks, startedTicks: startedTicks, finishedTicks: ObservationClock.now))
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
