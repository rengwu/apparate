import Foundation

public enum IndexError: Error { case duplicateID(String) }

struct ItemTexts: Sendable {
    var alternates: Range<Int32>
    var keywords: Range<Int32>
    var parent: Int32 = -1
}
struct FolderNode: Sendable { let text: Int32; let parent: Int32 }
private struct FolderKey: Hashable { let parent: Int32; let name: String }

/// Immutable, copy-on-write snapshot. Names, masks and bonuses live in flat buffers;
/// repeated ancestor components and directory chains are interned once at preparation.
public struct SearchIndex: Sendable {
    public let items: [SearchItem]
    var text = TextStore()
    var sources: [ItemTexts] = []
    var folders: [FolderNode] = []

    public init(items: [SearchItem]) throws {
        var ids = Set<String>()
        for item in items where !ids.insert(item.id).inserted { throw IndexError.duplicateID(item.id) }
        self.items = items
        text.spans.reserveCapacity(items.count)
        text.ascii.reserveCapacity(items.count * 24)
        text.asciiBonuses.reserveCapacity(items.count * 24)
        // Name ID equals item offset, allowing deterministic comparisons without more indirection.
        for item in items { _ = text.append(item.name) }
        sources.reserveCapacity(items.count)
        var directoryIDs: [FolderKey: Int32] = [:], componentIDs: [String: Int32] = [:]
        for item in items {
            let start = Int32(text.spans.count)
            for alternate in item.alternateNames { _ = text.append(alternate) }
            let middle = Int32(text.spans.count)
            for keyword in item.keywords { _ = text.append(keyword) }
            var source = ItemTexts(alternates: start..<middle, keywords: middle..<Int32(text.spans.count))
            if item.kind.isPath, let path = item.path {
                var parent: Int32 = -1
                for component in path.split(separator: "/").dropLast() {
                    let name = String(component), key = FolderKey(parent: parent, name: name)
                    if let existing = directoryIDs[key] { parent = existing; continue }
                    let textID: Int32
                    if let existing = componentIDs[name] { textID = existing }
                    else { textID = text.append(name); componentIDs[name] = textID }
                    let id = Int32(folders.count)
                    folders.append(FolderNode(text: textID, parent: parent)); directoryIDs[key] = id; parent = id
                }
                source.parent = parent
            }
            sources.append(source)
        }
    }
}
