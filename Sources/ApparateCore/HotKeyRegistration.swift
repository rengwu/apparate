import Foundation

@MainActor public protocol HotKeyRegistering: AnyObject {
    func register(_ key: AppConfig.HotKey) throws -> Int
    func unregister(_ token: Int)
}
@MainActor public final class HotKeyRegistration {
    public private(set) var active: AppConfig.HotKey?
    private var token: Int?
    private let registrar: any HotKeyRegistering
    public init(registrar: any HotKeyRegistering) { self.registrar = registrar }
    isolated deinit { stop() }
    public func replace(with key: AppConfig.HotKey, persist: () throws -> Void = {}) throws {
        if active?.keyCode == key.keyCode && active?.modifiers == key.modifiers { try persist(); active = key; return }
        let replacement = try registrar.register(key)
        let previousToken = token, previousKey = active
        // The synchronous config callback sees the reservation and cannot register it twice.
        token = replacement; active = key
        do { try persist() }
        catch { token = previousToken; active = previousKey; registrar.unregister(replacement); throw error }
        if let previousToken { registrar.unregister(previousToken) }
    }
    public func stop() { if let token { registrar.unregister(token) }; token = nil; active = nil }
}
