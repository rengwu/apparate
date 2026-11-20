import AppKit
import ApparateCore

@MainActor final class SetupWindow: NSObject, NSWindowDelegate {
    let window: PreferencesNativeWindow
    let model: SettingsModel
    var onKeyboardShortcuts: (() -> Void)?, onChooseFolders: (() -> Void)?
    private let shortcutMark = NSTextField(labelWithString: "○"), accessMark = NSTextField(labelWithString: "○")
    private let shortcutTitle = NSTextField(labelWithString: "Free up ⌘Space")
    private let shortcutText = NSTextField(wrappingLabelWithString: "")
    private let accessText = NSTextField(wrappingLabelWithString: "")
    private let keyboard = NSButton(title: "Open Keyboard Shortcuts…", target: nil, action: nil)
    private let allow = NSButton(title: "Allow Access…", target: nil, action: nil)
    private let choose = NSButton(title: "Choose Folders…", target: nil, action: nil), done = NSButton(title: "Done", target: nil, action: nil)
    init(model: SettingsModel, presentationAllowed: Bool) {
        self.model = model; window = PreferencesNativeWindow(title: "Set up Apparate", size: NSSize(width: 660, height: 310), presentationAllowed: presentationAllowed)
        super.init(); window.delegate = self
        let content = PreferencesContent(); window.contentView = content
        let title = NSTextField(labelWithString: "Set up Apparate"); title.font = .boldSystemFont(ofSize: 17)
        shortcutTitle.identifier = .init("setup-shortcut-title")
        let accessTitle = NSTextField(labelWithString: "Allow access to Desktop, Documents and Downloads")
        let explanation = NSTextField(wrappingLabelWithString: "macOS may ask for access to each folder.")
        for label in [shortcutText, accessText, explanation] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; label.isSelectable = false; label.preferredMaxLayoutWidth = 588; label.widthAnchor.constraint(equalToConstant: 588).isActive = true }
        let first = NSStackView(views: [shortcutTitle, shortcutText, keyboard]); first.orientation = .vertical; first.alignment = .leading; first.spacing = 6
        let second = NSStackView(views: [accessTitle, explanation, accessText, allow]); second.orientation = .vertical; second.alignment = .leading; second.spacing = 6
        let grid = NSGridView(views: [[shortcutMark, first], [accessMark, second]]); grid.rowSpacing = 20; grid.columnSpacing = 12; grid.yPlacement = .top
        grid.column(at: 0).width = 12; grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).width = 588; grid.column(at: 1).xPlacement = .leading
        let buttons = NSStackView(views: [choose, done]); buttons.spacing = 8
        for view in [title, grid, buttons] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22), grid.leadingAnchor.constraint(equalTo: title.leadingAnchor), grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), grid.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18), buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 24), buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)])
        keyboard.target = self; keyboard.action = #selector(openKeyboard)
        allow.target = self; allow.action = #selector(checkAccess)
        choose.target = self; choose.action = #selector(chooseFolders)
        done.target = self; done.action = #selector(finish); done.keyEquivalent = "\r"
        for button in [keyboard, allow, choose, done] { PreferencesStyle.button(button) }
        refresh()
    }
    static func shouldShow(configExisted: Bool, override: String?) -> Bool { !configExisted || override == "setup" }
    func refresh() {
        shortcutMark.stringValue = model.shortcutReady ? "✓" : "○"; shortcutMark.textColor = model.shortcutReady ? .systemGreen : .secondaryLabelColor
        accessMark.stringValue = model.accessReady ? "✓" : "○"; accessMark.textColor = model.accessReady ? .systemGreen : .secondaryLabelColor
        shortcutTitle.stringValue = model.usesCommandSpace ? "Free up ⌘Space" : "Use \(model.config.hotKey.display)"
        if model.shortcutReady { shortcutText.stringValue = "" }
        else if model.spotlightNotice { shortcutText.stringValue = "Spotlight uses ⌘Space. Turn off its shortcut, then Apparate takes it." }
        else if model.usesCommandSpace && model.spotlight == .unknown { shortcutText.stringValue = "Check Spotlight’s shortcut in Keyboard Shortcuts." }
        else { shortcutText.stringValue = "Shortcut unavailable. Choose another in Settings." }
        shortcutText.isHidden = shortcutText.stringValue.isEmpty
        keyboard.isHidden = model.shortcutReady || !model.usesCommandSpace
        accessText.stringValue = model.accessText; accessText.isHidden = model.accessText.isEmpty; allow.isEnabled = !model.access.busy
        if let content = window.contentView { content.layoutSubtreeIfNeeded(); window.setContentSize(NSSize(width: 660, height: ceil(content.fittingSize.height))) }
    }
    func show() { model.refresh(); refresh(); window.present() }
    func hide() { model.cancelAccess(); window.orderOut(nil) }
    func windowDidBecomeKey(_ notification: Notification) { model.refresh(); refresh() }
    func windowWillClose(_ notification: Notification) { model.cancelAccess() }
    @objc private func openKeyboard() { onKeyboardShortcuts?() }
    @objc func checkAccess() { model.requestAccess() }
    @objc func chooseFolders() { onChooseFolders?() }
    @objc func finish() { model.cancelAccess(); window.close() }
    func verifyHidden() throws { try window.verifyHidden() }
    func capture(to url: URL, dark: Bool? = nil) throws {
        if let dark { window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
        refresh(); try window.capture(to: url)
    }
}
