import Foundation
import Darwin

/// Small config reads and notifications belong to the UI owner. No directory scanning or polling.
@MainActor
public final class ConfigStore {
    public private(set) var current = AppConfig()
    public private(set) var errors: [String] = []
    public var onChange: ((AppConfig, [String]) -> Void)?
    public let file: URL
    private var folderWatch: (any DispatchSourceFileSystemObject)?
    private var fileWatch: (any DispatchSourceFileSystemObject)?
    private var fileIdentity: (dev_t, ino_t)?

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("config.json")
        // Watch before reading, closing the window where a first external save could be missed.
        folderWatch = try watch(directory, events: [.write, .delete, .rename])
        reload()
    }

    deinit { folderWatch?.cancel(); fileWatch?.cancel() }

    public func stopWatching() {
        folderWatch?.cancel(); folderWatch = nil
        fileWatch?.cancel(); fileWatch = nil; fileIdentity = nil
    }

    public func reload() {
        let old = current, oldErrors = errors
        do {
            if !FileManager.default.fileExists(atPath: file.path) { try write(AppConfig()) }
            current = try Self.decode(Data(contentsOf: file))
            errors = []
        } catch let error as ConfigError { errors = error.messages }
        catch { errors = ["Could not read config.json: \(error.localizedDescription)"] }
        rearmFileWatch()
        if current != old || errors != oldErrors { onChange?(current, errors) }
    }

    public func save(_ config: AppConfig) throws {
        let problems = config.validationErrors()
        guard problems.isEmpty else { throw ConfigError(messages: problems) }
        // A newer or broken external file must never be silently overwritten.
        if FileManager.default.fileExists(atPath: file.path) { _ = try Self.decode(Data(contentsOf: file)) }
        try write(config)
        reload()
    }

    public static func decode(_ data: Data) throws -> AppConfig {
        let decoded: AppConfig
        do { decoded = try JSONDecoder().decode(AppConfig.self, from: data) }
        catch let DecodingError.typeMismatch(_, context) {
            throw ConfigError(messages: ["Config has the wrong value type at \(context.codingPath.map(\.stringValue).joined(separator: "."))."])
        } catch let DecodingError.keyNotFound(key, _) {
            throw ConfigError(messages: ["Config is missing the required value \(key.stringValue)."])
        } catch { throw ConfigError(messages: ["Config is not valid JSON with the expected value types."]) }
        let problems = decoded.validationErrors()
        guard problems.isEmpty else { throw ConfigError(messages: problems) }
        return decoded
    }

    private func write(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: file, options: .atomic)
    }

    private func watch(_ url: URL, events: DispatchSource.FileSystemEvent) throws -> any DispatchSourceFileSystemObject {
        let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            // Main queue is the MainActor's executor on macOS.
            MainActor.assumeIsolated { self?.reload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func rearmFileWatch() {
        var info = stat()
        guard stat(file.path, &info) == 0 else { fileWatch?.cancel(); fileWatch = nil; fileIdentity = nil; return }
        if let old = fileIdentity, old.0 == info.st_dev, old.1 == info.st_ino { return }
        fileWatch?.cancel(); fileWatch = nil; fileIdentity = nil
        do {
            fileWatch = try watch(file, events: [.write, .extend, .attrib, .delete, .rename, .revoke])
            fileIdentity = (info.st_dev, info.st_ino)
        } catch { errors.append("Could not watch config.json: \(error.localizedDescription)") }
    }
}
