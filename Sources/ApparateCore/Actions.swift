import Foundation
import Darwin

public enum FilePresence: Sendable, Equatable { case present, missing, unknown }
public func filePresence(_ url: URL) -> FilePresence {
    var info = stat()
    if lstat(url.path, &info) == 0 { return .present }
    return errno == ENOENT || errno == ENOTDIR ? .missing : .unknown
}
public enum ActionOperation: Sendable, Equatable { case open, reveal, copyPath }
public struct ActionRequest: Sendable, Equatable {
    public let entry: CatalogEntry
    public let operation: ActionOperation
    public init(entry: CatalogEntry, operation: ActionOperation) { self.entry = entry; self.operation = operation }
}
public enum ActionURL {
    public static func web(template: String, query: String) throws -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard template.components(separatedBy: "{query}").count == 2,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: template.replacingOccurrences(of: "{query}", with: encoded)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), !(url.host?.isEmpty ?? true) else {
            throw SourceError("The web search URL is invalid.")
        }
        return url
    }
    public static func settings(bundle: String, anchor: String?) throws -> URL {
        guard !bundle.isEmpty, bundle.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }) else {
            throw SourceError("The settings pane identifier is invalid.")
        }
        var components = URLComponents()
        components.scheme = "x-apple.systempreferences"; components.path = bundle; components.query = anchor
        guard let url = components.url else { throw SourceError("The settings link is invalid.") }
        return url
    }
}

@MainActor public protocol ActionExecuting: AnyObject {
    func openApplication(_ url: URL) async throws
    func openURL(_ url: URL) async throws
    func reveal(_ url: URL) async throws
    func copyPath(_ path: String) async throws
    func command(_ command: SystemCommand) async throws
}
public struct ActionFailure: Sendable {
    public let title: String
    public let reason: String
    public let missingID: String?
}
@MainActor public final class ActionDispatcher {
    private let executor: any ActionExecuting
    private let presence: @Sendable (URL) -> FilePresence
    private let record: @Sendable (String) async throws -> Void
    public var onHistoryError: ((String) -> Void)?
    public init(executor: any ActionExecuting, presence: @escaping @Sendable (URL) -> FilePresence = filePresence,
                record: @escaping @Sendable (String) async throws -> Void) {
        self.executor = executor; self.presence = presence; self.record = record
    }
    /// Nil means the requested effect was accepted. URL acceptance does not prove navigation.
    public func perform(_ request: ActionRequest) async -> ActionFailure? {
        let entry = request.entry
        do {
            if let url = entry.target.fileURL, presence(url) == .missing { throw SourceError("The item no longer exists.") }
            switch request.operation {
            case .copyPath:
                guard let url = entry.target.fileURL else { throw SourceError("This item has no file path.") }
                try await executor.copyPath(url.path)
            case .reveal:
                guard let url = entry.target.fileURL else { throw SourceError("This item has no file path.") }
                try await executor.reveal(url)
            case .open:
                switch entry.target {
                case .application(let url): try await executor.openApplication(url)
                case .file(let url): try await executor.openURL(url)
                case .settings(let bundle, let anchor): try await executor.openURL(ActionURL.settings(bundle: bundle, anchor: anchor))
                case .web(let template, let query): try await executor.openURL(ActionURL.web(template: template, query: query))
                case .command(let command): try await executor.command(command)
                }
            }
        } catch {
            let missing = entry.target.fileURL.map { presence($0) == .missing } ?? false
            return ActionFailure(title: entry.item.name, reason: error.localizedDescription, missingID: missing ? entry.item.id : nil)
        }
        if request.operation == .open {
            do { try await record(entry.item.id) } catch { onHistoryError?(error.localizedDescription) }
        }
        return nil
    }
}
