import Foundation
import CoreFoundation

public enum SpotlightShortcut: Equatable, Sendable {
    case unknown, disabled, enabled(keyCode: UInt32, modifiers: UInt64)
    public static func read(_ dictionary: [String: Any]?) -> Self {
        guard let entry = dictionary?["64"] as? [String: Any], let enabled = entry["enabled"] as? NSNumber,
              CFGetTypeID(enabled) == CFBooleanGetTypeID() else { return .unknown }
        if !enabled.boolValue { return .disabled }
        guard let value = entry["value"] as? [String: Any], value["type"] as? String == "standard", let parameters = value["parameters"] as? [NSNumber], parameters.count == 3,
              parameters.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue >= 0 && $0.doubleValue.rounded() == $0.doubleValue }),
              parameters[1].doubleValue <= Double(UInt16.max), parameters[2].doubleValue <= Double(UInt32.max) else { return .unknown }
        return .enabled(keyCode: parameters[1].uint32Value, modifiers: parameters[2].uint64Value)
    }
    public var usesCommandSpace: Bool { self == .enabled(keyCode: 49, modifiers: 1 << 20) }
    public var commandSpaceIsFree: Bool { self != .unknown && !usesCommandSpace }
}
public enum LoginState: Equatable, Sendable { case notRegistered, enabled, requiresApproval, unavailable }
@MainActor public protocol LoginServicing: AnyObject {
    var state: LoginState { get }
    func setEnabled(_ enabled: Bool) throws
}
public enum SearchPreset: String, CaseIterable, Sendable {
    case duckDuckGo = "DuckDuckGo", google = "Google", bing = "Bing", kagi = "Kagi"
    public var url: String {
        switch self {
        case .duckDuckGo: "https://duckduckgo.com/?q={query}"
        case .google: "https://www.google.com/search?q={query}"
        case .bing: "https://www.bing.com/search?q={query}"
        case .kagi: "https://kagi.com/search?q={query}"
        }
    }
}
public struct SettingsIndexState: Sendable {
    public var count: Int, updated: Date?, roots: [FileRoot], indexing: Bool, error: String?
    public init(count: Int = 0, updated: Date? = nil, roots: [FileRoot] = [], indexing: Bool = false, error: String? = nil) {
        self.count = count; self.updated = updated; self.roots = roots; self.indexing = indexing; self.error = error
    }
    public func text(now: Date) -> String {
        let countText = count.formatted() + " items"
        if indexing { return countText + " · Indexing…" }
        guard let updated else { return count == 0 ? "No indexed items" : countText }
        let seconds = max(0, Int(now.timeIntervalSince(updated)))
        let age: String
        if seconds < 60 { age = "just now" }
        else if seconds < 3600 { let n = seconds / 60; age = "\(n) minute\(n == 1 ? "" : "s") ago" }
        else if seconds < 86400 { let n = seconds / 3600; age = "\(n) hour\(n == 1 ? "" : "s") ago" }
        else { let n = seconds / 86400; age = "\(n) day\(n == 1 ? "" : "s") ago" }
        return countText + " · updated " + age
    }
}

@MainActor public final class SettingsModel {
    public let store: ConfigStore, hotkey: HotKeyRegistration, access: FolderAccessController
    public let home: String
    public var onChange: (() -> Void)?
    public var onRebuild: (() -> Void)?
    public private(set) var spotlight = SpotlightShortcut.unknown
    public private(set) var loginState = LoginState.unavailable
    public private(set) var error: String?
    public private(set) var hotkeyError: String?
    public var index = SettingsIndexState() { didSet { onChange?() } }
    private let login: any LoginServicing
    private let readSpotlight: () -> SpotlightShortcut
    private var accessTask: Task<Void, Never>?
    public init(store: ConfigStore, hotkey: HotKeyRegistration, access: FolderAccessController,
                login: any LoginServicing, readSpotlight: @escaping () -> SpotlightShortcut,
                home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.store = store; self.hotkey = hotkey; self.access = access; self.login = login
        self.readSpotlight = readSpotlight; self.home = home
        spotlight = readSpotlight(); loginState = login.state
    }
    public var config: AppConfig { store.current }
    public var editable: Bool { store.errors.isEmpty }
    public var preset: SearchPreset? { SearchPreset.allCases.first { $0.url == config.searchURL } }
    public var usesCommandSpace: Bool { config.hotKey.keyCode == 49 && config.hotKey.modifiers == 256 }
    public var spotlightNotice: Bool { usesCommandSpace && spotlight.usesCommandSpace }
    public var shortcutReady: Bool {
        guard hotkey.active?.keyCode == config.hotKey.keyCode, hotkey.active?.modifiers == config.hotKey.modifiers else { return false }
        return !usesCommandSpace || spotlight.commandSpaceIsFree
    }
    public var accessReady: Bool { AccessFolder.allCases.allSatisfy { folder in access.observations.contains { $0.folder == folder && $0.status == .allowed } } }
    public var needsAccess: Bool {
        config.folders.contains { folder in
            let path = normalized(folder.path)
            return AccessFolder.allCases.contains { protected in
                let root = home + "/" + protected.rawValue
                guard path == root || path.hasPrefix(root + "/") else { return false }
                return !access.observations.contains { $0.folder == protected && $0.status == .allowed } ||
                    index.roots.contains { $0.path == path && [.denied, .waitingForAccess].contains($0.status) }
            }
        }
    }
    public var accessText: String {
        if let checking = access.checking { return "Checking \(checking.rawValue)…" }
        if accessReady { return "Last check: all three folders allowed." }
        return AccessFolder.allCases.compactMap { folder -> String? in
            let status = access.observations.first { $0.folder == folder }?.status
            if status == .allowed { return nil }
            let label: String
            switch status { case .denied: label = "Denied"; case .notFound: label = "Not found"; case .error: label = "Could not check"; default: label = "Not checked" }
            return folder.rawValue + ": " + label
        }.joined(separator: " · ")
    }
    public func normalized(_ path: String) -> String { AppConfig.normalizedFolder(path, home: home) }
    public func displayed(_ path: String) -> String {
        let path = normalized(path)
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    public func refresh() {
        store.reload(); spotlight = readSpotlight(); loginState = login.state
        retryHotkey(); onChange?()
    }
    public func configChanged(retry: Bool = true) { if retry { retryHotkey() }; onChange?() }
    public func retryHotkey() {
        do { try hotkey.replace(with: config.hotKey); hotkeyError = nil }
        catch { hotkeyError = String(describing: error) }
    }
    public func clearError() { error = nil; onChange?() }
    public func report(_ message: String) { error = message; onChange?() }
    private func attempt(_ work: () throws -> Void) -> Bool {
        guard editable else { onChange?(); return false }
        do { try work(); error = nil; onChange?(); return true }
        catch {
            self.error = (error as? ConfigError)?.description ?? error.localizedDescription
            store.reload(); onChange?(); return false
        }
    }
    private func conflict() -> ConfigError { ConfigError(messages: ["This value changed in config.json. Review the current value and try again."]) }
    @discardableResult public func set<Value: Equatable>(_ field: WritableKeyPath<AppConfig, Value>, from expected: Value, to value: Value) -> Bool {
        attempt { try store.update { latest in
            guard latest[keyPath: field] == expected else { throw conflict() }
            latest[keyPath: field] = value
        } }
    }
    @discardableResult public func setHotkey(_ value: AppConfig.HotKey, expected: AppConfig.HotKey) -> Bool {
        attempt {
            try store.update({ latest in
                guard latest.hotKey == expected else { throw conflict() }; latest.hotKey = value
            }, persist: { candidate in try self.hotkey.replace(with: value) { try self.store.save(candidate) } })
            hotkeyError = nil
        }
    }
    @discardableResult public func setPrefix(scope: SearchScope, expected: String?, value: String?) -> Bool {
        attempt { try store.update { latest in
            guard latest.prefixes[scope.rawValue] == expected else { throw conflict() }
            latest.prefixes[scope.rawValue] = value
        } }
    }
    @discardableResult public func addFolders(_ paths: [String]) -> Bool {
        guard !paths.isEmpty else { return true }
        return attempt { try store.update { latest in
            var known = Set(latest.folders.map { normalized($0.path) })
            for path in paths { let path = normalized(path); if known.insert(path).inserted { latest.folders.append(.init(path: path)) } }
        } }
    }
    @discardableResult public func changeFolder(path: String, expectedDepth: Int, depth: Int?) -> Bool {
        attempt { try store.update { latest in
            guard let i = latest.folders.firstIndex(where: { normalized($0.path) == normalized(path) }), latest.folders[i].depth == expectedDepth else { throw conflict() }
            if let depth { latest.folders[i].depth = depth } else { latest.folders.remove(at: i) }
        } }
    }
    public func setLogin(_ enabled: Bool) {
        guard editable else { return }
        do { try login.setEnabled(enabled); error = nil }
        catch { self.error = error.localizedDescription }
        loginState = login.state; onChange?()
    }
    public func rebuild() { guard editable && !index.indexing else { return }; onRebuild?() }
    public func requestAccess() {
        guard accessTask == nil && !access.busy else { return }
        accessTask = Task { await access.check(); accessTask = nil }
    }
    public func cancelAccess() { accessTask?.cancel(); access.cancelPending() }
}
