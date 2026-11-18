import AppKit
import ApparateCore

@MainActor final class MenuController: NSObject {
    let menu = NSMenu(), applicationMenu = NSMenu()
    private let presentationAllowed: Bool
    private var status: NSStatusItem?
    private let openItem = NSMenuItem(title: "Open Apparate", action: #selector(open), keyEquivalent: "")
    private(set) var itemInstalled = false
    var nativeItemCount: Int { status == nil ? 0 : 1 }
    var onOpen: (() -> Void)?, onSettings: (() -> Void)?, onQuit: (() -> Void)?
    init(presentationAllowed: Bool) {
        self.presentationAllowed = presentationAllowed
        super.init()
        openItem.target = self; menu.addItem(openItem)
        menu.addItem(item("Settings…", #selector(settings), ",")); menu.addItem(.separator())
        menu.addItem(item("Quit Apparate", #selector(quit), "q"))
        let appItem = NSMenuItem(); appItem.submenu = NSMenu(title: "Apparate")
        appItem.submenu?.addItem(item("Settings…", #selector(settings), ",")); appItem.submenu?.addItem(.separator())
        appItem.submenu?.addItem(item("Quit Apparate", #selector(quit), "q")); applicationMenu.addItem(appItem)
        let edit = NSMenuItem(); edit.submenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            let entry = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key)
            edit.submenu?.addItem(entry)
        }
        applicationMenu.addItem(edit)
        let window = NSMenuItem(); window.submenu = NSMenu(title: "Window")
        window.submenu?.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        applicationMenu.addItem(window)
        if presentationAllowed { NSApp.mainMenu = applicationMenu }
    }
    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; return item
    }
    func update(visible: Bool, activeKey: AppConfig.HotKey?) {
        openItem.keyEquivalent = activeKey.map(ShortcutEvent.equivalent) ?? ""
        openItem.keyEquivalentModifierMask = activeKey.map(ShortcutEvent.modifiers) ?? []
        itemInstalled = visible
        guard presentationAllowed else { return }
        if visible && status == nil {
            status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = Bundle.main.url(forResource: "MenuBarIconTemplate", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            if let retina = Bundle.main.url(forResource: "MenuBarIconTemplate@2x", withExtension: "png"), let retinaImage = NSImage(contentsOf: retina) { for rep in retinaImage.representations { image?.addRepresentation(rep) } }
            image?.size = NSSize(width: 18, height: 18); image?.isTemplate = true
            status?.button?.image = image; status?.button?.toolTip = "Apparate"; status?.menu = menu
        } else if !visible, let status { NSStatusBar.system.removeStatusItem(status); self.status = nil }
    }
    /// Keep window commands reachable even if the user assigns one as the global key.
    func performWindowCommand(_ key: AppConfig.HotKey, close: () -> Void) -> Bool {
        guard key.modifiers == 256 else { return false }
        switch key.keyCode {
        case 12: onQuit?()
        case 43: onSettings?()
        case 13: close()
        default: return false
        }
        return true
    }
    @objc private func open() { onOpen?() }
    @objc private func settings() { onSettings?() }
    @objc private func quit() { onQuit?() }
}
