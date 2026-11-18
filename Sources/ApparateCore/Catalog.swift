import Foundation

public enum SystemCommand: String, Sendable, CaseIterable {
    case lock, sleep, restart, trash
    public var title: String {
        switch self { case .lock: "Lock Screen"; case .sleep: "Sleep"; case .restart: "Restart"; case .trash: "Show Trash" }
    }
    public var symbol: String {
        switch self { case .lock: "lock"; case .sleep: "moon.zzz"; case .restart: "arrow.clockwise"; case .trash: "trash" }
    }
}

public enum ActionTarget: Sendable, Equatable {
    case application(URL), file(URL), settings(bundle: String, anchor: String?)
    case web(template: String, query: String), command(SystemCommand)
    public var fileURL: URL? {
        switch self { case .application(let url), .file(let url): url; default: nil }
    }
}
public enum ItemIcon: Sendable, Equatable { case file(String), symbol(String) }
public struct CatalogEntry: Sendable, Equatable {
    public let item: SearchItem
    public let target: ActionTarget
    public let location: String
    public let icon: ItemIcon
    public init(item: SearchItem, target: ActionTarget, location: String = "", icon: ItemIcon = .symbol("square")) {
        self.item = item; self.target = target; self.location = location; self.icon = icon
    }
    public static var commands: [CatalogEntry] {
        SystemCommand.allCases.map { command in
            let alternate = command == .lock ? ["Lock"] : (command == .trash ? ["Trash"] : [])
            return CatalogEntry(item: SearchItem(id: "command:" + command.rawValue, kind: .command, name: command.title, alternateNames: alternate),
                                target: .command(command), icon: .symbol(command.symbol))
        }
    }
}
public struct CatalogSnapshot: Sendable {
    public let index: SearchIndex
    public let entries: [String: CatalogEntry]
    public init(entries: [CatalogEntry]) throws {
        index = try SearchIndex(items: entries.map(\.item))
        self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.item.id, $0) })
    }
    public func removing(_ id: String) throws -> CatalogSnapshot {
        try CatalogSnapshot(entries: entries.values.filter { $0.item.id != id }.sorted { $0.item.id < $1.item.id })
    }
}

public struct SourceError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Reads bundle data only. Never loads a bundle's executable.
enum BundleData {
    static func dictionary(_ url: URL) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
            throw SourceError("The resource is not a property-list dictionary.")
        }
        return value
    }
    static func language(in resources: URL, preferences: [String]) -> String {
        let available = ((try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? [])
            .filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) }.sorted()
        return language(available: available, preferences: preferences)
    }
    static func language(available: [String], preferences: [String]) -> String {
        // Include an English candidate even if absent, so unmatched preferences never select
        // an arbitrary other translation. A missing English resource is handled by the reader.
        return Bundle.preferredLocalizations(from: Array(Set(available + ["en"])).sorted(), forPreferences: preferences + ["en"]).first ?? "en"
    }
    static func name(url: URL, info: [String: Any], preferences: [String]) -> String {
        let resources = url.appendingPathComponent("Contents/Resources")
        let language = language(in: resources, preferences: preferences)
        let strings = try? dictionary(resources.appendingPathComponent("\(language).lproj/InfoPlist.strings"))
        let localized = strings ?? Bundle(url: url)?.localizedInfoDictionary ?? [:]
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = (localized[key] ?? info[key]) as? String, !value.isEmpty { return value }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
