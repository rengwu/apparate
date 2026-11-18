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
    public func replace(with key: AppConfig.HotKey) throws {
        if active?.keyCode == key.keyCode && active?.modifiers == key.modifiers { active = key; return }
        let replacement = try registrar.register(key)
        if let token { registrar.unregister(token) }
        token = replacement; active = key
    }
    public func stop() { if let token { registrar.unregister(token) }; token = nil; active = nil }
}
