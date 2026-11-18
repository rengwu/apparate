import Foundation

public struct SettingsScan: Sendable {
    public let entries: [CatalogEntry]
    public let malformedResources: Int
}
public enum SettingsSource {
    public static let extensions = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions")
    public static let preferencePanes = URL(fileURLWithPath: "/System/Library/PreferencePanes")
    public static let systemSettingsIcon = "/System/Applications/System Settings.app"

    public static func scan(directory: URL = extensions, legacyDirectory: URL = preferencePanes,
                            languages: [String] = Locale.preferredLanguages) throws -> SettingsScan {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "appex" }.sorted { $0.path < $1.path }
        var entries: [String: CatalogEntry] = [:], malformed = 0
        func add(_ entry: CatalogEntry) {
            guard let old = entries[entry.item.id] else { entries[entry.item.id] = entry; return }
            let item = SearchItem(id: old.item.id, kind: .setting, name: old.item.name,
                                  keywords: Array(Set(old.item.keywords + entry.item.keywords)).sorted())
            entries[item.id] = CatalogEntry(item: item, target: old.target, location: old.location, icon: old.icon)
        }
        for url in urls {
            do {
                let info = try BundleData.dictionary(url.appendingPathComponent("Contents/Info.plist"))
                guard let bundle = info["CFBundleIdentifier"] as? String else { malformed += 1; continue }
                let attributes = (info["EXAppExtensionAttributes"] as? [String: Any])?["SettingsExtensionAttributes"] as? [String: Any]
                guard let terms = attributes?["searchTermsFileName"] as? String else { continue }
                let override = ["com.apple.Battery-Settings.extension": "Battery", "com.apple.HeadphoneSettings": "Headphones"][bundle]
                let name = override ?? BundleData.name(url: url, info: info, preferences: languages)
                let icon: ItemIcon = .file(override == nil ? url.path : systemSettingsIcon)
                let paneID = ItemID.setting(bundle: bundle, anchor: "", title: name)
                add(CatalogEntry(item: SearchItem(id: paneID, kind: .setting, name: name), target: .settings(bundle: bundle, anchor: nil), location: "System Settings", icon: icon))
                var resourceBundles: [URL] = [url]
                if let legacy = attributes?["legacyPrefPaneBundleName"] as? String, !legacy.isEmpty {
                    guard legacy == (legacy as NSString).lastPathComponent, legacy != ".", legacy != ".." else {
                        malformed += 1; continue
                    }
                    resourceBundles.append(legacyDirectory.appendingPathComponent(legacy))
                }
                // Modern panes may retain a legacy bundle name after moving their terms
                // into the extension. Read one localization from the first available resource.
                var resource: URL?
                for bundle in resourceBundles {
                    let resources = bundle.appendingPathComponent("Contents/Resources")
                    let selected = BundleData.language(in: resources, preferences: languages)
                    let localized = resources.appendingPathComponent("\(selected).lproj/\(terms).searchTerms")
                    let english = resources.appendingPathComponent("en.lproj/\(terms).searchTerms")
                    if filePresence(localized) != .missing { resource = localized; break }
                    if filePresence(english) != .missing { resource = english; break }
                }
                guard let resource else { malformed += 1; continue }
                let groups = try BundleData.dictionary(resource)
                for anchor in groups.keys.sorted() {
                    guard let group = groups[anchor] as? [String: Any], let records = group["localizableStrings"] as? [[String: Any]] else { malformed += 1; continue }
                    for record in records {
                        guard let title = record["title"] as? String, !title.isEmpty else { malformed += 1; continue }
                        let keywords = (record["index"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        let id = ItemID.setting(bundle: bundle, anchor: anchor, title: title)
                        add(CatalogEntry(item: SearchItem(id: id, kind: .setting, name: title, keywords: keywords),
                                         target: .settings(bundle: bundle, anchor: anchor.isEmpty ? nil : anchor), location: name, icon: icon))
                    }
                }
            } catch { malformed += 1 }
        }
        return SettingsScan(entries: entries.values.sorted { $0.item.id < $1.item.id }, malformedResources: malformed)
    }
}
