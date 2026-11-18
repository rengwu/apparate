import Foundation

public struct PanelRow: Sendable, Equatable {
    public let result: SearchResult
    public let entry: CatalogEntry
    public init(result: SearchResult, entry: CatalogEntry) { self.result = result; self.entry = entry }
}
public struct PanelModel: Sendable {
    public static let pageSize = 9
    public private(set) var revision: UInt64 = 0
    public private(set) var rows: [PanelRow] = []
    public private(set) var selectedID: String?
    public private(set) var query = ""
    public private(set) var visible = false
    public private(set) var pending = false
    public private(set) var composing = false
    public private(set) var firstVisibleRow = 0
    private var armed: (id: String, revision: UInt64)?
    private struct PendingAction: Sendable {
        let operation: ActionOperation
        let itemID: String?
        let confirmsRestart: Bool
    }
    private var pendingAction: PendingAction?
    public init() {}
    public var selected: PanelRow? { rows.first { $0.entry.item.id == selectedID } }
    public var restartArmed: Bool { armed?.id == selectedID && armed?.revision == revision }
    public var visibleRange: Range<Int> { firstVisibleRow..<min(rows.count, firstVisibleRow + Self.pageSize) }

    public mutating func show() {
        visible = true; selectedID = nil; rows = []; firstVisibleRow = 0; composing = false; _ = begin(query: "")
    }
    public mutating func hide() { visible = false; revision &+= 1; pending = false; armed = nil; pendingAction = nil }
    @discardableResult public mutating func begin(query: String) -> UInt64 {
        revision &+= 1; self.query = query; pending = !query.isEmpty; armed = nil; pendingAction = nil
        if query.isEmpty { rows = []; selectedID = nil; firstVisibleRow = 0 }
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
        revealSelection()
    }
    public mutating func move(_ offset: Int) {
        guard !composing else { return }
        armed = nil; pendingAction = nil
        guard !pending, !rows.isEmpty else { return }
        let old = rows.firstIndex { $0.entry.item.id == selectedID } ?? 0
        selectedID = rows[max(0, min(rows.count - 1, old + offset))].entry.item.id
        revealSelection()
    }
    public mutating func scroll(_ offset: Int) {
        guard !composing else { return }
        armed = nil; pendingAction = nil
        firstVisibleRow = max(0, min(max(0, rows.count - Self.pageSize), firstVisibleRow + offset))
    }
    public mutating func cancelRestart() { armed = nil; pendingAction = nil }
    private mutating func revealSelection() {
        firstVisibleRow = min(firstVisibleRow, max(0, rows.count - Self.pageSize))
        guard let index = rows.firstIndex(where: { $0.entry.item.id == selectedID }) else { return }
        if index < firstVisibleRow { firstVisibleRow = index }
        if index >= firstVisibleRow + Self.pageSize { firstVisibleRow = index - Self.pageSize + 1 }
    }
    public mutating func accept(_ rows: [PanelRow], revision: UInt64) -> ActionRequest? {
        guard visible, !query.isEmpty, revision == self.revision else { return nil }
        let queued = pendingAction
        self.rows = rows; pending = false; pendingAction = nil; armed = nil
        if !rows.contains(where: { $0.entry.item.id == selectedID }) { selectedID = rows.first?.entry.item.id }
        revealSelection()
        guard let queued else { return nil }
        if let id = queued.itemID {
            guard rows.contains(where: { $0.entry.item.id == id }) else { return nil }
            selectedID = id; revealSelection()
        }
        return action(queued.operation, confirmsRestart: queued.confirmsRestart)
    }
    public mutating func activateVisible(_ number: Int, isRepeat: Bool = false) -> ActionRequest? {
        guard (1...Self.pageSize).contains(number), visibleRange.contains(firstVisibleRow + number - 1) else { return nil }
        return activate(id: rows[firstVisibleRow + number - 1].entry.item.id, isRepeat: isRepeat)
    }
    public mutating func activate(id: String, isRepeat: Bool = false) -> ActionRequest? {
        guard visible, !composing, !isRepeat, rows.contains(where: { $0.entry.item.id == id }) else { return nil }
        if pending { pendingAction = PendingAction(operation: .open, itemID: id, confirmsRestart: false); return nil }
        select(id: id)
        return action(.open, confirmsRestart: false)
    }
    public mutating func action(_ operation: ActionOperation, isRepeat: Bool = false, confirmsRestart: Bool = true) -> ActionRequest? {
        guard visible, !composing, !isRepeat else { return nil }
        if pending { pendingAction = PendingAction(operation: operation, itemID: nil, confirmsRestart: confirmsRestart); return nil }
        guard let selected else { return nil }
        if operation != .open && selected.entry.target.fileURL == nil { armed = nil; return nil }
        if operation == .open && selected.entry.target == .command(.restart) {
            if !restartArmed || !confirmsRestart { armed = (selected.entry.item.id, revision); return nil }
        }
        armed = nil
        return ActionRequest(entry: selected.entry, operation: operation)
    }
}

/// Shared display transformations. These use stored strings only, never filesystem metadata.
public enum PanelText {
    public static func location(_ entry: CatalogEntry, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        guard let path = entry.target.fileURL?.path else { return entry.location }
        let parent = (path as NSString).deletingLastPathComponent
        if parent == home { return "~" }
        return parent.hasPrefix(home + "/") ? "~" + parent.dropFirst(home.count) : parent
    }
    public static func highlightRanges(_ name: String, offsets: [Int]) -> [NSRange] {
        let selected = Set(offsets)
        var ranges: [NSRange] = [], start = 0
        for (index, character) in name.enumerated() {
            let length = String(character).utf16.count
            if selected.contains(index) { ranges.append(NSRange(location: start, length: length)) }
            start += length
        }
        return ranges
    }
}

/// The request revision begins before awaiting usage, closing the pre-submission race.
@MainActor public final class LauncherSession {
    public private(set) var model = PanelModel()
    public var onChange: (() -> Void)?
    public var onAction: ((ActionRequest) -> Void)?
    public var onError: ((String) -> Void)?
    public var onSubmitted: ((UInt64, UInt64) -> Void)?
    package var onResponse: ((UInt64) -> Void)?
    public var onResults: ((UInt64) -> Void)?
    private let coordinator: SearchCoordinator
    private let usage: @Sendable () async throws -> UsageSnapshot
    private var catalog: CatalogSnapshot?
    private var files: FileIndexSnapshot?
    private let requiresFiles: Bool
    private var config: AppConfig
    private var showing: UInt64 = 0
    private var usageSnapshot: UsageSnapshot?
    private var usageRead: Task<Void, Never>?
    public var isCatalogReady: Bool { catalog != nil && (!requiresFiles || files != nil) }
    public init(config: AppConfig, requiresFiles: Bool = false, coordinator: SearchCoordinator = SearchCoordinator(),
                usage: @escaping @Sendable () async throws -> UsageSnapshot) {
        self.requiresFiles = requiresFiles; self.config = config; self.coordinator = coordinator; self.usage = usage
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
    public func setFiles(_ files: FileIndexSnapshot) {
        let first = self.files == nil; self.files = files
        if first && model.visible && model.pending { submit() } else { restart() }
    }
    public func move(_ offset: Int) { model.move(offset); onChange?() }
    public func select(id: String?) { model.select(id: id); onChange?() }
    public func scroll(_ offset: Int) { model.scroll(offset); onChange?() }
    public func activate(id: String, isRepeat: Bool = false) { deliver(model.activate(id: id, isRepeat: isRepeat)) }
    public func activateVisible(_ number: Int, isRepeat: Bool = false) { deliver(model.activateVisible(number, isRepeat: isRepeat)) }
    public func act(_ operation: ActionOperation, isRepeat: Bool = false) { deliver(model.action(operation, isRepeat: isRepeat)) }
    private func deliver(_ action: ActionRequest?) { onChange?(); if let action { onAction?(action) } }
    @discardableResult public func escape() -> Bool {
        guard !model.composing else { return false }
        if model.restartArmed { model.cancelRestart(); onChange?() }
        else if !model.query.isEmpty { edit("") }
        else { hide() }
        return true
    }
    private func restart() {
        coordinator.invalidate()
        guard model.visible else { return }
        _ = model.begin(query: model.query); submit()
    }
    private func submit() {
        coordinator.invalidate(); onChange?()
        guard model.visible, !model.query.isEmpty, let usageSnapshot else { return }
        let query = ParsedQuery(model.query, config: config)
        guard query.scope == .web || isCatalogReady else { return }
        guard let catalog = catalog ?? (try? CatalogSnapshot(entries: [])) else { return }
        let version = model.revision, config = config, files = files
        let generation = coordinator.submit(index: catalog.index, query: query, files: files, usage: usageSnapshot) { [weak self] response in
            guard let self, self.model.visible, self.model.revision == version else { return }
            self.onResponse?(version)
            let rows = response.results.compactMap { result -> PanelRow? in
                let entry: CatalogEntry?
                if let query = result.webQuery {
                    entry = CatalogEntry(item: result.item, target: .web(template: config.searchURL, query: query), location: "Search the web", icon: .symbol("globe"))
                } else if let existing = catalog.entries[result.item.id] { entry = existing }
                else if let app = files?.applications?.entries[result.item.id] { entry = app }
                else if let path = result.item.path, result.item.kind == .file || result.item.kind == .folder {
                    entry = CatalogEntry(item: result.item, target: .file(URL(fileURLWithPath: path)),
                                         location: (path as NSString).deletingLastPathComponent, icon: .file(path))
                } else { entry = nil }
                return entry.map { PanelRow(result: result, entry: $0) }
            }
            let action = self.model.accept(rows, revision: version)
            self.onResults?(version)
            self.onChange?()
            if let action { self.onAction?(action) }
        }
        onSubmitted?(version, generation)
    }
}
