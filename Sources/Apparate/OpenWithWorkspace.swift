import AppKit
import UniformTypeIdentifiers
import ApparateCore

/// No native discovery adapter is constructed in unattended app profiles.
enum OpenWithWorkspace {
    static func service(history: UsageStore) -> OpenWithService {
        OpenWithService(lookup: discover, application: { try AppSource.bundleEntry(at: $0) }, lastChoice: { try await history.lastOpenWith(for: $0) })
    }

    private static func discover(_ entry: CatalogEntry, access: FileAccessPolicy) throws -> OpenWithDiscovery {
        guard case .file(let url) = entry.target else { throw SourceError("This item cannot use Open With.") }
        try OpenWithAccess.validate(url, access: access)
        if filePresence(url) == .missing { throw OpenWithLookupError("The item no longer exists.", missingID: entry.item.id) }
        try Task.checkCancellation()
        let type = entry.item.kind == .folder ? "public.folder" : (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier)
        let workspace = NSWorkspace.shared
        let claimed = workspace.urlsForApplications(toOpen: url).compactMap { try? AppSource.bundleEntry(at: $0) }
        let current = workspace.urlForApplication(toOpen: url).flatMap { try? AppSource.bundleEntry(at: $0) }
        return OpenWithDiscovery(contentType: type, claimed: claimed, defaultApplication: current)
    }
}
