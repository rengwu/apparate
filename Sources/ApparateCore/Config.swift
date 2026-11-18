import Foundation

public enum SearchScope: String, Codable, CaseIterable, Sendable {
    case apps, commands, settings, files, web
}

public struct AppConfig: Codable, Equatable, Sendable {
    public struct HotKey: Codable, Equatable, Sendable {
        public var keyCode: UInt32 = 49
        public var modifiers: UInt32 = 256
        public var display = "⌘Space"
        public init() {}
        private enum CodingKeys: String, CodingKey { case keyCode, modifiers, display }
        public init(from decoder: Decoder) throws {
            self.init()
            let c = try decoder.container(keyedBy: CodingKeys.self)
            keyCode = c.contains(.keyCode) ? try c.decode(UInt32.self, forKey: .keyCode) : keyCode
            modifiers = c.contains(.modifiers) ? try c.decode(UInt32.self, forKey: .modifiers) : modifiers
            display = c.contains(.display) ? try c.decode(String.self, forKey: .display) : display
        }
    }
    public struct Folder: Codable, Equatable, Sendable {
        public var path: String
        public var depth: Int
        public init(path: String, depth: Int = 10) { self.path = path; self.depth = depth }
        private enum CodingKeys: String, CodingKey { case path, depth }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            depth = c.contains(.depth) ? try c.decode(Int.self, forKey: .depth) : 10
        }
    }
    public var version = 1
    public var hotKey = HotKey()
    public var showMenuBarIcon = true
    public var prefixes = ["files": "'", "settings": ".", "web": "?"]
    public var searchURL = "https://duckduckgo.com/?q={query}"
    public var folders = ["Projects", "Desktop", "Documents", "Downloads"].map { Folder(path: "~/" + $0) }
    public var respectGitignore = true
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case version, hotKey, showMenuBarIcon, prefixes, searchURL, folders, respectGitignore
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.contains(.version) ? try c.decode(Int.self, forKey: .version) : version
        hotKey = c.contains(.hotKey) ? try c.decode(HotKey.self, forKey: .hotKey) : hotKey
        showMenuBarIcon = c.contains(.showMenuBarIcon) ? try c.decode(Bool.self, forKey: .showMenuBarIcon) : showMenuBarIcon
        prefixes = c.contains(.prefixes) ? try c.decode([String: String].self, forKey: .prefixes) : prefixes
        searchURL = c.contains(.searchURL) ? try c.decode(String.self, forKey: .searchURL) : searchURL
        folders = c.contains(.folders) ? try c.decode([Folder].self, forKey: .folders) : folders
        respectGitignore = c.contains(.respectGitignore) ? try c.decode(Bool.self, forKey: .respectGitignore) : respectGitignore
    }

    public func validationErrors(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        var errors: [String] = []
        if version != 1 { errors.append("Config version \(version) is not supported. This app supports version 1.") }
        var used = Set<String>()
        for scope in prefixes.keys.sorted() {
            let prefix = prefixes[scope]!
            if SearchScope(rawValue: scope) == nil { errors.append("Unknown prefix scope: \(scope).") }
            let forbidden = CharacterSet.alphanumerics.union(.whitespacesAndNewlines).union(.controlCharacters)
            if prefix.count != 1 || prefix == "/" || prefix == "~" || prefix.unicodeScalars.contains(where: forbidden.contains) {
                errors.append("The \(scope) prefix must be one symbol other than / or ~, with no letters, digits or spaces.")
            }
            if !used.insert(prefix).inserted { errors.append("The prefix \(prefix) is assigned to more than one scope.") }
        }
        var paths = Set<String>()
        for (i, folder) in folders.enumerated() {
            let path = Self.normalizedFolder(folder.path, home: home)
            if !path.hasPrefix("/") { errors.append("Folder \(i + 1) must have an absolute path or start with ~/.") }
            if !paths.insert(path).inserted { errors.append("Folder \(i + 1) repeats another folder.") }
            if !(1...30).contains(folder.depth) { errors.append("Folder \(i + 1) depth must be between 1 and 30.") }
        }
        let sample = searchURL.replacingOccurrences(of: "{query}", with: "example")
        let url = URLComponents(string: sample)
        if searchURL.components(separatedBy: "{query}").count != 2 ||
            !["https", "http"].contains(url?.scheme?.lowercased() ?? "") ||
            (url?.host?.isEmpty ?? true) || url?.url == nil ||
            sample.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) {
            errors.append("Search URL must be a complete http or https URL with a host and exactly one {query}.")
        }
        return errors
    }

    /// Lexical normalization only: no existence, permissions or symlink lookup.
    public static func normalizedFolder(_ input: String, home: String) -> String {
        let path = input == "~" ? home : (input.hasPrefix("~/") ? home + input.dropFirst() : input)
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                if let last = parts.last, last != ".." { parts.removeLast() }
                else if !path.hasPrefix("/") { parts.append(part) }
            } else { parts.append(part) }
        }
        return (path.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
    }

    public static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["APPARATE_HOME"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Apparate", isDirectory: true)
    }
}

public struct ConfigError: Error, CustomStringConvertible, Sendable {
    public let messages: [String]
    public var description: String { messages.joined(separator: "\n") }
}
