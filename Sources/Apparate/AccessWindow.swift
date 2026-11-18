import AppKit
import ApparateCore

private final class AccessContentView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); dirtyRect.fill()
    }
}

private final class AccessNativeWindow: NSWindow {
    let presentationAllowed: Bool
    init(presentationAllowed: Bool) {
        self.presentationAllowed = presentationAllowed
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: true)
    }
    override var canBecomeKey: Bool { presentationAllowed }
    override var canBecomeMain: Bool { presentationAllowed }
    override func orderFront(_ sender: Any?) { if presentationAllowed { super.orderFront(sender) } }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if presentationAllowed || place == .out { super.order(place, relativeTo: otherWin) }
    }
}

@MainActor final class AccessWindow: NSObject {
    private let window: NSWindow
    private let presentationAllowed: Bool
    private let controller: FolderAccessController
    private var labels: [AccessFolder: NSTextField] = [:]
    private let button = NSButton(title: "Allow folder access", target: nil, action: nil)
    init(controller: FolderAccessController, presentationAllowed: Bool = true) {
        self.presentationAllowed = presentationAllowed; self.controller = controller
        window = AccessNativeWindow(presentationAllowed: presentationAllowed)
        super.init()
        window.title = "Folder Access"; window.isReleasedWhenClosed = false
        window.contentView = AccessContentView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        let text = NSTextField(wrappingLabelWithString: "Allow Apparate to search file and folder names in these folders.")
        text.frame = NSRect(x: 20, y: 179, width: 380, height: 40); window.contentView?.addSubview(text)
        for (i, folder) in AccessFolder.allCases.enumerated() {
            let name = NSTextField(labelWithString: folder.rawValue); name.frame = NSRect(x: 20, y: 139 - i * 31, width: 145, height: 22)
            let status = NSTextField(labelWithString: "Not checked"); status.frame = NSRect(x: 168, y: 139 - i * 31, width: 232, height: 22)
            status.textColor = .secondaryLabelColor; labels[folder] = status
            window.contentView?.addSubview(name); window.contentView?.addSubview(status)
        }
        button.frame = NSRect(x: 226, y: 17, width: 174, height: 32); button.bezelStyle = .rounded
        button.target = self; button.action = #selector(check); window.contentView?.addSubview(button)
        controller.onChange = { [weak self] in self?.update() }; update()
    }
    func show() { guard presentationAllowed else { return }; window.center(); window.makeKeyAndOrderFront(nil) }
    func hide() { window.orderOut(nil) }
    @objc private func check() { Task { await controller.check() } }
    private func update() {
        button.isEnabled = !controller.busy
        for folder in AccessFolder.allCases {
            if controller.checking == folder { labels[folder]?.stringValue = "Checking…"; continue }
            let value = controller.observations.first { $0.folder == folder }?.status
            let text: String
            switch value { case .allowed: text = "Allowed"; case .denied: text = "Denied"; case .notFound: text = "Not found"; case .error: text = "Could not check"; case nil: text = "Not checked" }
            labels[folder]?.stringValue = value == nil ? text : "Last check: " + text
        }
    }
    func verifyHidden() throws {
        guard !window.isVisible, !window.isKeyWindow, !window.isMainWindow, !NSApp.isActive,
              !window.canBecomeKey, !window.canBecomeMain else { throw SourceError("The automated access window acquired presentation or focus.") }
    }
    func capture(to url: URL) throws {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SourceError("The access step could not be rendered.") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw SourceError("The access render could not be encoded.") }
        try data.write(to: url, options: .atomic)
    }
}
