import Foundation
import Darwin

public struct CachedSettings: Sendable {
    public let scan: SettingsScan
    public let hit: Bool
    public let writeFailed: Bool
}
/// Disposable, versioned metadata only. A failed decode/key mismatch falls back to system resources.
public enum SettingsCache {
    private struct Record: Codable {
        let title: String, bundle: String, location: String, icon: String
        let anchor: String?
        let keywords: [String]
        init?(_ entry: CatalogEntry) {
            guard case .settings(let bundle, let anchor) = entry.target, case .file(let icon) = entry.icon else { return nil }
            title = entry.item.name; self.bundle = bundle; self.anchor = anchor
            keywords = entry.item.keywords; location = entry.location; self.icon = icon
        }
        var entry: CatalogEntry {
            CatalogEntry(item: SearchItem(id: ItemID.setting(bundle: bundle, anchor: anchor ?? "", title: title), kind: .setting, name: title, keywords: keywords),
                         target: .settings(bundle: bundle, anchor: anchor), location: location, icon: .file(icon))
        }
    }
    private struct Document: Codable {
        let version: Int
        let build: String
        let languages: [String]
        let malformed: Int
        let records: [Record]
    }
    public static var systemBuild: String {
        var count = 0
        guard sysctlbyname("kern.osversion", nil, &count, nil, 0) == 0, count > 1 else { return ProcessInfo.processInfo.operatingSystemVersionString }
        var bytes = [CChar](repeating: 0, count: count)
        guard sysctlbyname("kern.osversion", &bytes, &count, nil, 0) == 0 else { return ProcessInfo.processInfo.operatingSystemVersionString }
        return String(decoding: bytes.prefix(count - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    public static func load(directory: URL, build: String = systemBuild, languages: [String] = Locale.preferredLanguages,
                            loader: (() throws -> SettingsScan)? = nil) throws -> CachedSettings {
        let file = directory.appendingPathComponent("settings-cache.json")
        if let data = try? Data(contentsOf: file), let document = try? JSONDecoder().decode(Document.self, from: data),
           document.version == 2, document.build == build, document.languages == languages,
           document.malformed >= 0, document.records.allSatisfy({ !$0.title.isEmpty && !$0.bundle.isEmpty && $0.icon.hasPrefix("/") }) {
            let entries = document.records.map(\.entry)
            if Set(entries.map(\.item.id)).count == entries.count {
                return CachedSettings(scan: SettingsScan(entries: entries, malformedResources: document.malformed), hit: true, writeFailed: false)
            }
        }
        let scan = try loader?() ?? SettingsSource.scan(languages: languages)
        let records = scan.entries.compactMap(Record.init)
        let document = Document(version: 2, build: build, languages: languages, malformed: scan.malformedResources, records: records)
        var failed = false
        do {
            guard records.count == scan.entries.count else { throw SourceError("A settings item cannot be cached.") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(document).write(to: file, options: .atomic)
        } catch { failed = true }
        return CachedSettings(scan: scan, hit: false, writeFailed: failed)
    }
}
