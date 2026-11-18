import Foundation
import Darwin

/// Per-source, bounded to bundles in the latest successful scan. Never persisted.
public struct AppSourceCache: Sendable {
    fileprivate var records: [String: AppBundleRecord] = [:]
    public init() {}
    mutating func retain(_ paths: Set<String>) { records = records.filter { paths.contains($0.key) } }
    mutating func entry(at original: URL, canonical: URL, languages: [String]) throws -> (CatalogEntry, reused: Bool) {
        let key = original.standardizedFileURL.path
        let previous = records[key]
        // Stat failures other than absence bypass caching; normal source error handling still applies.
        let metadata = try? AppBundleMetadata(url: canonical, languages: languages, previous: previous?.metadata)
        if let metadata, let previous, metadata == previous.metadata { return (previous.entry, true) }
        let entry = try AppSource.bundleEntry(at: original, languages: languages)
        // A concurrent writer must not associate a new stamp with old resource contents.
        if let metadata, let after = try? AppBundleMetadata(url: canonical, languages: languages, previous: metadata), after == metadata {
            records[key] = AppBundleRecord(metadata: metadata, entry: entry)
        } else { records.removeValue(forKey: key) }
        return (entry, false)
    }
}

private struct AppBundleRecord: Sendable {
    let metadata: AppBundleMetadata
    let entry: CatalogEntry
}
private struct AppFileStamp: Sendable, Equatable {
    let device: Int32, inode: UInt64, mode: UInt16
    let size: Int64, modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    static func read(_ path: String, directory: Bool = false, identityOnly: Bool = false) throws -> Self? {
        var value = stat()
        guard stat(path, &value) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw SourceError("Could not inspect application metadata.")
        }
        return Self(device: value.st_dev, inode: value.st_ino, mode: value.st_mode,
                    size: directory ? 0 : value.st_size,
                    modifiedSeconds: identityOnly ? 0 : value.st_mtimespec.tv_sec,
                    modifiedNanos: identityOnly ? 0 : value.st_mtimespec.tv_nsec,
                    changedSeconds: directory ? 0 : value.st_ctimespec.tv_sec,
                    changedNanos: directory ? 0 : value.st_ctimespec.tv_nsec)
    }
}
private struct AppBundleMetadata: Sendable, Equatable {
    let path: String, languages: [String], systemLanguages: [String]
    let bundle: AppFileStamp?, info: AppFileStamp?, resources: AppFileStamp?
    let localizations: [String], stringPaths: [String], strings: [AppFileStamp?]
    let selectedPath: String, selectedStamp: AppFileStamp?, usesSelectedStrings: Bool
    init(url: URL, languages: [String], previous: Self?) throws {
        path = url.path; self.languages = languages; systemLanguages = Locale.preferredLanguages
        // Bundle directory timestamps/xattrs are irrelevant to the searchable metadata.
        bundle = try AppFileStamp.read(path, directory: true, identityOnly: true)
        info = try AppFileStamp.read(path + "/Contents/Info.plist")
        let directory = path + "/Contents/Resources"
        resources = try AppFileStamp.read(directory, directory: true)
        if let previous, previous.path == path, previous.resources == resources {
            localizations = previous.localizations
        } else if resources != nil {
            localizations = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".lproj") }.sorted()
        } else { localizations = [] }
        if let previous, previous.path == path, previous.resources == resources, previous.languages == languages {
            selectedPath = previous.selectedPath
        } else {
            let language = BundleData.language(available: localizations.map { String($0.dropLast(6)) }, preferences: languages)
            selectedPath = directory + "/" + language + ".lproj/InfoPlist.strings"
        }
        selectedStamp = try AppFileStamp.read(selectedPath)
        if let previous, previous.selectedPath == selectedPath, previous.selectedStamp == selectedStamp {
            usesSelectedStrings = previous.usesSelectedStrings
        } else {
            usesSelectedStrings = selectedStamp != nil && (try? BundleData.dictionary(URL(fileURLWithPath: selectedPath))) != nil
        }
        if usesSelectedStrings {
            // BundleData uses this dictionary exclusively, even when it is empty.
            // Changes in other translations cannot change this entry's name.
            stringPaths = [selectedPath]; strings = [selectedStamp]
        } else {
            // Missing/malformed selected strings invoke Bundle's system-language fallback.
            // Conservatively check every possible translation and the unlocalized resource.
            if let previous, !previous.usesSelectedStrings, previous.path == path, previous.resources == resources {
                stringPaths = previous.stringPaths
            } else {
                stringPaths = (["InfoPlist.strings"] + localizations.map { $0 + "/InfoPlist.strings" }).map { directory + "/" + $0 }
            }
            strings = try stringPaths.map { try AppFileStamp.read($0) }
        }
    }
}
