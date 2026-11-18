import Foundation

/// Confined to the coordinator's serial worker. Optional stage clocks are diagnostics only.
package final class SearchPipeline: @unchecked Sendable {
    private let fileUsage = FileUsageCache()
    package init() {}
    package func search(_ request: SearchRequest, isCancelled: @Sendable () -> Bool = { false },
                        stage: ((String, Double) -> Void)? = nil) -> [SearchResult] {
        func timed<T>(_ name: String, _ work: () -> T) -> T {
            guard let stage else { return work() }
            let start = ContinuousClock.now, result = work()
            stage(name, durationMS(start.duration(to: .now))); return result
        }
        guard let files = request.files, request.query.scope != .web else {
            return timed("catalog") { request.index.search(request.query, usage: request.usage, isCancelled: isCancelled) }
        }
        let local = timed("catalog") { request.index.search(request.query, usage: request.usage, includeWebFallback: false, isCancelled: isCancelled) }
        let boosts = timed("usage") { fileUsage.resolve(files, request.usage) }
        let fileRows = timed("files") { files.search(request.query, boosts: boosts, isCancelled: isCancelled) }
        let apps = timed("discovered_apps") { files.applications?.index.search(request.query, usage: request.usage, includeWebFallback: false, isCancelled: isCancelled) ?? [] }
        let merged = timed("merge") { SearchResult.merge([local, fileRows, apps]) }
        return merged.isEmpty ? timed("fallback") { request.index.search(request.query, usage: request.usage, isCancelled: isCancelled) } : merged
    }
}
