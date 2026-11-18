import Foundation
import Darwin

public struct AppScan: Sendable {
    public let entries: [CatalogEntry]
    public let watchPaths: [String]
    public let skippedBundles: Int
}

public enum AppSource {
    public static var defaultRoots: [URL] {
        ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
         "/System/Library/CoreServices/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    public static let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    public static func scan(roots: [URL] = defaultRoots, additionalApps: [URL] = [finder],
                            languages: [String] = Locale.preferredLanguages) throws -> AppScan {
        var entries: [String: CatalogEntry] = [:], watched = Set<String>(), skipped = 0
        func app(_ original: URL) {
            let url = original.resolvingSymlinksInPath().standardizedFileURL
            guard url.pathExtension.lowercased() == "app", entries["app:" + url.path] == nil else { return }
            // Observe bundles themselves; scanning roots already cover alias locations.
            watched.insert(original.path)
            watched.insert(url.path)
            do {
                let info = try BundleData.dictionary(url.appendingPathComponent("Contents/Info.plist"))
                let name = BundleData.name(url: url, info: info, preferences: languages)
                let alternate = [original.deletingPathExtension().lastPathComponent, url.deletingPathExtension().lastPathComponent, info["CFBundleName"] as? String ?? ""]
                let names = Array(Set(alternate.filter { !$0.isEmpty && $0 != name })).sorted()
                let item = SearchItem(id: "app:" + url.path, kind: .app, name: name, alternateNames: names, path: url.path)
                entries[item.id] = CatalogEntry(item: item, target: .application(url), location: url.deletingLastPathComponent().path, icon: .file(url.path))
            } catch { skipped += 1 }
        }
        func folder(_ url: URL, nested: Bool) throws {
            let children: [URL]
            do { children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) }
            catch {
                if filePresence(url) == .missing { return }
                throw SourceError("Could not read an application folder: \(error.localizedDescription)")
            }
            for child in children.sorted(by: { $0.path < $1.path }) {
                if child.pathExtension.lowercased() == "app" { app(child); continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if !nested && values?.isDirectory == true && values?.isSymbolicLink != true { try folder(child, nested: true) }
            }
        }
        for root in roots {
            watched.insert(root.standardizedFileURL.path)
            watched.insert(root.resolvingSymlinksInPath().standardizedFileURL.path)
            try folder(root, nested: false)
        }
        for url in additionalApps { app(url) }
        return AppScan(entries: entries.values.sorted { $0.item.id < $1.item.id }, watchPaths: watched.sorted(), skippedBundles: skipped)
    }

    /// Also catches creation of a root that does not exist at launch.
    public static func watchableParent(of url: URL) -> URL {
        var current = url.resolvingSymlinksInPath().standardizedFileURL
        while filePresence(current) == .missing && current.path != "/" { current.deleteLastPathComponent() }
        return current
    }
}
