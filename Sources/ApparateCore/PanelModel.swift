import Foundation

public struct PanelRow: Sendable, Equatable {
    public let result: SearchResult
    public let entry: CatalogEntry
    public init(result: SearchResult, entry: CatalogEntry) { self.result = result; self.entry = entry }
}
public struct PanelModel: Sendable {
    public private(set) var revision: UInt64 = 0
    public private(set) var rows: [PanelRow] = []
    public private(set) var selectedID: String?
    public private(set) var query = ""
    public private(set) var visible = false
    public private(set) var pending = false
    public private(set) var composing = false
    private var armed: (id: String, revision: UInt64)?
    private var pendingAction: ActionOperation?
    public init() {}
    public var selected: PanelRow? { rows.first { $0.entry.item.id == selectedID } }
    public var restartArmed: Bool { armed?.id == selectedID && armed?.revision == revision }

    public mutating func show() { visible = true; selectedID = nil; rows = []; composing = false; _ = begin(query: "") }
    public mutating func hide() { visible = false; revision &+= 1; pending = false; armed = nil; pendingAction = nil }
    @discardableResult public mutating func begin(query: String) -> UInt64 {
        revision &+= 1; self.query = query; pending = true; armed = nil; pendingAction = nil
        return revision
    }
    public mutating func setComposing(_ value: Bool) {
        composing = value
        if value { armed = nil; pendingAction = nil }
    }
    public mutating func select(id: String?) {
        guard !pending, !composing else { pendingAction = nil; return }
        if id != selectedID { armed = nil; pendingAction = nil }
        selectedID = rows.contains { $0.entry.item.id == id } ? id : rows.first?.entry.item.id
    }
    public mutating func move(_ offset: Int) {
        guard !composing else { return }
        armed = nil; pendingAction = nil
        guard !pending, !rows.isEmpty else { return }
        let old = rows.firstIndex { $0.entry.item.id == selectedID } ?? 0
        selectedID = rows[max(0, min(rows.count - 1, old + offset))].entry.item.id
    }
    public mutating func accept(_ rows: [PanelRow], revision: UInt64) -> ActionRequest? {
        guard visible, revision == self.revision else { return nil }
        let queued = pendingAction
        self.rows = rows; pending = false; pendingAction = nil; armed = nil
        if !rows.contains(where: { $0.entry.item.id == selectedID }) { selectedID = rows.first?.entry.item.id }
        return queued.flatMap { action($0) }
    }
    public mutating func action(_ operation: ActionOperation, isRepeat: Bool = false) -> ActionRequest? {
        guard visible, !composing, !isRepeat else { return nil }
        if pending { pendingAction = operation; return nil }
        guard let selected else { return nil }
        if operation != .open && selected.entry.target.fileURL == nil { armed = nil; return nil }
        if operation == .open && selected.entry.target == .command(.restart) {
            if !restartArmed { armed = (selected.entry.item.id, revision); return nil }
        }
        armed = nil
        return ActionRequest(entry: selected.entry, operation: operation)
    }
}

/// The request revision begins before awaiting usage, closing the pre-submission race.
@MainActor public final class LauncherSession {
    public private(set) var model = PanelModel()
    public var onChange: (() -> Void)?
    public var onAction: ((ActionRequest) -> Void)?
    public var onError: ((String) -> Void)?
    private let coordinator: SearchCoordinator
    private let usage: @Sendable () async throws -> UsageSnapshot
    private var catalog: CatalogSnapshot?
    private var config: AppConfig
    private var showing: UInt64 = 0
    private var usageSnapshot: UsageSnapshot?
    private var usageRead: Task<Void, Never>?
    public var isCatalogReady: Bool { catalog != nil }
    public init(config: AppConfig, coordinator: SearchCoordinator = SearchCoordinator(),
                usage: @escaping @Sendable () async throws -> UsageSnapshot) {
        self.config = config; self.coordinator = coordinator; self.usage = usage
    }
    public func show() {
        showing &+= 1; usageRead?.cancel(); usageSnapshot = nil
        model.show(); submit(); readUsage()
    }
    public func hide() {
        showing &+= 1; usageRead?.cancel(); usageRead = nil; usageSnapshot = nil
        coordinator.invalidate(); model.hide(); onChange?()
    }
    /// Called after an accepted primary open has finished recording history.
    /// Hidden panels read afresh on their next showing; an already reopened panel refreshes now.
    public func successfulOpen() {
        usageSnapshot = nil
        guard model.visible else { return }
        showing &+= 1; usageRead?.cancel(); restart(); readUsage()
    }
    private func readUsage() {
        let showing = showing, usage = usage
        usageRead = Task { [weak self] in
            let snapshot: UsageSnapshot
            var failed = false
            do { snapshot = try await usage() }
            catch { snapshot = UsageSnapshot(); failed = true }
            guard let self, self.showing == showing, self.model.visible else { return }
            self.usageSnapshot = snapshot; self.usageRead = nil
            if failed { self.onError?("Usage history could not be read.") }
            self.submit()
        }
    }
    public func edit(_ text: String, composing: Bool = false) { model.setComposing(composing); _ = model.begin(query: text); submit() }
    public func setComposing(_ value: Bool) { model.setComposing(value) }
    public func setConfig(_ config: AppConfig) { self.config = config; restart() }
    public func setCatalog(_ catalog: CatalogSnapshot) {
        let first = self.catalog == nil
        self.catalog = catalog
        // Initial readiness completes the pending query, including a Return already queued for it.
        if first && model.visible && model.pending { submit() } else { restart() }
    }
    public func move(_ offset: Int) { model.move(offset); onChange?() }
    public func select(id: String?) { model.select(id: id); onChange?() }
    public func act(_ operation: ActionOperation, isRepeat: Bool = false) {
        let action = model.action(operation, isRepeat: isRepeat); onChange?()
        if let action { onAction?(action) }
    }
    private func restart() {
        coordinator.invalidate()
        guard model.visible else { return }
        _ = model.begin(query: model.query); submit()
    }
    private func submit() {
        coordinator.invalidate(); onChange?()
        guard model.visible, let catalog, let usageSnapshot else { return }
        let version = model.revision, query = ParsedQuery(model.query, config: config), config = config
        coordinator.submit(index: catalog.index, query: query, usage: usageSnapshot) { [weak self] response in
            guard let self, self.model.visible, self.model.revision == version else { return }
            let rows = response.results.compactMap { result -> PanelRow? in
                let entry: CatalogEntry?
                if let query = result.webQuery {
                    entry = CatalogEntry(item: result.item, target: .web(template: config.searchURL, query: query), location: "Search the web", icon: .symbol("globe"))
                } else { entry = catalog.entries[result.item.id] }
                return entry.map { PanelRow(result: result, entry: $0) }
            }
            let action = self.model.accept(rows, revision: version)
            self.onChange?()
            if let action { self.onAction?(action) }
        }
    }
}
