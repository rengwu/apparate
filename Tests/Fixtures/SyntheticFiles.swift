import Foundation
import Synchronization
import ApparateCore

public final class SyntheticFiles: Sendable {
    public let count: Int
    public let change = Mutex(0)
    public let root = "/Fixture/Projects"
    public let groups = 500
    public let includeDots: Bool
    public static let dotNames = [".git", ".github", ".gitignore", ".env", ".editorconfig", ".config"]
    public var dotCount: Int { includeDots ? groups * 6 - groups / 10 : 0 }
    public init(count: Int, includeDots: Bool = false) { self.count = count; self.includeDots = includeDots }
    public var reader: FileReading {
        FileReading(metadata: { [self] path in
            let parts = path.dropFirst(root.count + 1).split(separator: "/")
            let directory = path == root || parts.count == 1 || (includeDots && [".git", ".github", ".config"].contains(String(parts.last ?? "")))
            let inode = path.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            return FileMetadata(type: directory ? .directory : .file, device: 1, inode: inode)
        }, children: { [self] path in
            if path == root { return (0..<groups).map { String(format: "Project-%04d", $0) } }
            if includeDots && path.dropFirst(root.count + 1).contains("/") { throw NSError(domain: "DotSentinelMustNotBeListed", code: 1) }
            let group = Int(path.suffix(4))!
            let names = ["README", "Report", "Config", "Network", "Calendar", "Terminal", "Archive", "Notes", "Search", "Index", "Café", "Straße", "東京資料"]
            var files: [String] = []
            for i in stride(from: group, to: count - groups - 1 - dotCount, by: groups) {
                files.append(names[(i &* 17 &+ 31) % names.count] + String(format: "-%06d.md", i))
            }
            if includeDots { files += Self.dotNames }
            let state = change.withLock { $0 }
            if group == 0 && state > 0 { files.append("new-entry.txt") }
            if group == 0 && state == 2 { files = files.filter { $0 == "new-entry.txt" } }
            return files
        }, ignoreContents: { [self] path in
            includeDots && path != root && Int(path.suffix(4)).map({ $0 % 10 == 0 }) == true ? Data(".env\n".utf8) : nil
        }, ignoresCase: { _ in false })
    }
}

