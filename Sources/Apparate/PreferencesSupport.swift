import AppKit
import Carbon
import ServiceManagement
import ApparateCore

@MainActor final class NativeLoginService: LoginServicing {
    private var supported: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }
    var state: LoginState {
        guard supported else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        default: return .unavailable
        }
    }
    func setEnabled(_ enabled: Bool) throws {
        guard supported else { throw SourceError("Launch at login requires the installed app bundle.") }
        if enabled { if state != .enabled && state != .requiresApproval { try SMAppService.mainApp.register() } }
        else if state == .enabled || state == .requiresApproval { try SMAppService.mainApp.unregister() }
    }
    static func spotlight() -> SpotlightShortcut {
        let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys")
        return SpotlightShortcut.read(domain?["AppleSymbolicHotKeys"] as? [String: Any])
    }
}

/// Test profiles never construct a native service or status item.
@MainActor final class FixtureLoginService: LoginServicing {
    var state = LoginState.notRegistered
    var changes: [Bool] = [], failure = false
    func setEnabled(_ enabled: Bool) throws {
        changes.append(enabled)
        if failure { throw SourceError("Fixture login change refused.") }
        state = enabled ? .enabled : .notRegistered
    }
}

final class PreferencesNativeWindow: NSWindow {
    let presentationAllowed: Bool
    init(title: String, size: NSSize, presentationAllowed: Bool) {
        self.presentationAllowed = presentationAllowed
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        self.title = title; isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { presentationAllowed }
    override var canBecomeMain: Bool { presentationAllowed }
    override func orderFront(_ sender: Any?) { if presentationAllowed { super.orderFront(sender) } }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if presentationAllowed || place == .out { super.order(place, relativeTo: otherWin) }
    }
    func present() {
        guard presentationAllowed else { return }
        center(); NSApp.activate(); makeKeyAndOrderFront(nil)
    }
    func verifyHidden() throws {
        guard !presentationAllowed, !isVisible, !isKeyWindow, !isMainWindow, !NSApp.isActive,
              !canBecomeKey, !canBecomeMain else { throw SourceError("A preferences test acquired presentation or focus.") }
    }
    func capture(to url: URL) throws {
        try verifyHidden()
        guard let view = contentView else { throw SourceError("Missing preferences content") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SourceError("Could not allocate preferences raster") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { throw SourceError("Could not encode preferences raster") }
        try data.write(to: url); try verifyHidden()
    }
}
final class PreferencesContent: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}
@MainActor final class ControlAction: NSObject {
    let run: (NSControl) -> Void
    init(_ run: @escaping (NSControl) -> Void) { self.run = run }
    @objc func fire(_ sender: NSControl) { run(sender) }
}
@MainActor enum ShortcutEvent {
    static func key(_ event: NSEvent) -> AppConfig.HotKey? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !event.isARepeat, !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var value = AppConfig.HotKey(); value.keyCode = UInt32(event.keyCode); value.modifiers = 0
        var display = ""
        for (flag, mask, symbol) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] {
            if flags.contains(flag) { value.modifiers |= UInt32(mask); display += symbol }
        }
        let named = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let text = named[Int(event.keyCode)] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        guard !text.isEmpty else { return nil }; value.display = display + text; return value
    }
    static func equivalent(_ key: AppConfig.HotKey) -> String {
        let named = [49: " ", 36: "\r", 48: "\t", 51: "\u{8}", 123: "\u{f702}", 124: "\u{f703}", 125: "\u{f701}", 126: "\u{f700}"]
        if let value = named[Int(key.keyCode)] { return value }
        // The recorder stores the unmodified key glyph in the display string.
        return String(key.display.drop(while: { "⌃⌥⇧⌘".contains($0) })).lowercased()
    }
    static func modifiers(_ key: AppConfig.HotKey) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        for (flag, mask) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)] {
            if key.modifiers & UInt32(mask) != 0 { flags.insert(flag) }
        }
        return flags
    }
}
