import Foundation

public enum ItemKind: UInt8, Sendable, Codable {
    case app, command, setting, folder, file, web
    public var rank: Int {
        switch self { case .app, .command: 0; case .setting: 1; case .folder: 2; case .file: 3; case .web: 4 }
    }
    var isPath: Bool { self == .folder || self == .file }
}

public struct SearchItem: Sendable, Equatable {
    public let id: String
    public let kind: ItemKind
    public let name: String
    public let alternateNames: [String]
    public let keywords: [String]
    public let path: String?
    public init(id: String, kind: ItemKind, name: String, alternateNames: [String] = [], keywords: [String] = [], path: String? = nil) {
        self.id = id; self.kind = kind; self.name = name
        self.alternateNames = alternateNames; self.keywords = keywords; self.path = path
    }
}

public enum ItemID {
    /// Parts are length-prefixed, so embedded ?, #, : and Unicode cannot collide.
    public static func setting(bundle: String, anchor: String, title: String) -> String {
        "setting:" + [bundle, anchor, title].map { "\($0.utf8.count):\($0)" }.joined()
    }
}

public enum MatchTier: Int, Sendable, Comparable {
    case exact, prefix, word, fuzzy, keyword
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum MatchSource: Sendable, Equatable {
    case name, alternate(Int), keyword(Int), keywords([Int]), web
}

public struct SearchResult: Sendable, Equatable {
    public let item: SearchItem
    public let tier: MatchTier
    public let textScore: Double
    public let usageBoost: Double
    public let source: MatchSource
    /// Zero-based extended grapheme cluster offsets in item.name, never UTF-8 offsets.
    public let highlights: [Int]
    public let webQuery: String?
}

public struct ParsedQuery: Sendable, Equatable {
    public let text: String
    public let scope: SearchScope?
    public let isPath: Bool
    public let pathSegments: [String]
    public let hasTrailingSeparator: Bool
    public var isEmpty: Bool { text.isEmpty || (isPath && pathSegments.isEmpty) }
    public init(_ raw: String, config: AppConfig = AppConfig()) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var scope: SearchScope?
        if let first = text.first,
           let key = config.prefixes.keys.sorted().first(where: { config.prefixes[$0] == String(first) }),
           let selected = SearchScope(rawValue: key) {
            scope = selected
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.text = text; self.scope = scope
        isPath = (scope == nil || scope == .files) && text.contains("/")
        var segments = isPath ? text.split(separator: "/").map(String.init) : []
        if text.hasPrefix("~/"), segments.first == "~" { segments.removeFirst() }
        pathSegments = segments
        hasTrailingSeparator = isPath && text.hasSuffix("/")
    }

    func includes(_ kind: ItemKind) -> Bool {
        if isPath { return kind.isPath }
        switch scope {
        case nil: return kind != .web
        case .apps: return kind == .app
        case .commands: return kind == .command
        case .settings: return kind == .setting
        case .files: return kind.isPath
        case .web: return false
        }
    }
}
