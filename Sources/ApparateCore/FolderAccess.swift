import Foundation

public enum AccessFolder: String, Codable, CaseIterable, Sendable { case desktop = "Desktop", documents = "Documents", downloads = "Downloads" }
public enum AccessStatus: String, Codable, Sendable { case allowed, denied, notFound, error }
public struct AccessObservation: Codable, Sendable, Equatable {
    public let folder: AccessFolder
    public let status: AccessStatus
    public let date: Date
    public init(folder: AccessFolder, status: AccessStatus, date: Date = Date()) { self.folder = folder; self.status = status; self.date = date }
}
public enum FolderAccessProbe {
    /// Call only from an explicit user request. Loading saved observations never calls this.
    public static func check(_ url: URL) -> AccessStatus {
        do { _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil); return .allowed }
        catch {
            let e = error as NSError
            if filePresence(url) == .missing { return .notFound }
            if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError { return .denied }
            let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError ?? e
            if underlying.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(underlying.code) { return .denied }
            return .error
        }
    }
}
@MainActor public final class FolderAccessController {
    public private(set) var observations: [AccessObservation] = []
    public private(set) var checking: AccessFolder?
    public private(set) var busy = false
    public var onChange: (() -> Void)?
    public var onCompletion: (([AccessObservation]) -> Void)?
    public var onError: ((String) -> Void)?
    private let file: URL
    private let probe: @Sendable (AccessFolder) async -> AccessStatus
    public init(directory: URL, probe: @escaping @Sendable (AccessFolder) async -> AccessStatus = { folder in
        await Task.detached(priority: .utility) {
            FolderAccessProbe.check(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(folder.rawValue))
        }.value
    }) {
        file = directory.appendingPathComponent("access.json"); self.probe = probe
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([AccessObservation].self, from: data) { observations = saved }
    }
    public func check() async {
        guard !busy else { return }
        busy = true; defer { busy = false; checking = nil; onChange?() }
        for folder in AccessFolder.allCases {
            checking = folder; onChange?()
            let status = await probe(folder)
            observations.removeAll { $0.folder == folder }
            observations.append(AccessObservation(folder: folder, status: status)); onChange?()
        }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(observations).write(to: file, options: .atomic)
        } catch { onError?("Folder-access results could not be saved.") }
        onCompletion?(observations)
    }
}
