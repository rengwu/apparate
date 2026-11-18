import AppKit
import QuartzCore
import ApparateCore

private final class LauncherPanel: NSPanel {
    let presentationAllowed: Bool
    var onKey: ((NSEvent) -> Bool)?
    init(presentationAllowed: Bool) {
        self.presentationAllowed = presentationAllowed
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 334),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
    }
    override var canBecomeKey: Bool { presentationAllowed }
    override var canBecomeMain: Bool { false }
    override func orderFront(_ sender: Any?) { if presentationAllowed { super.orderFront(sender) } }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if presentationAllowed || place == .out { super.order(place, relativeTo: otherWin) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { onKey?(event) == true || super.performKeyEquivalent(with: event) }
}

/// A real opaque comparator has no visual-effect view in its hierarchy.
private final class PanelBackground: NSView {
    private var effect: NSVisualEffectView?
    var usesVibrancy: Bool { effect != nil }
    override var isOpaque: Bool { effect == nil }
    func configure(vibrancy: Bool) {
        if vibrancy && effect == nil {
            let view = NSVisualEffectView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.material = .popover; view.blendingMode = .behindWindow; view.state = .active
            addSubview(view, positioned: .below, relativeTo: subviews.first); effect = view
        } else if !vibrancy { effect?.removeFromSuperview(); effect = nil }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if !usesVibrancy { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
    }
}

/// Activity ends on release, including controller teardown; no window or focus effects.
private final class PanelActivity {
    private let token = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Responding to launcher input")
    deinit { ProcessInfo.processInfo.endActivity(token) }
}

@MainActor final class PanelController: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    let session: LauncherSession
    let rows: ResultsView
    private let panel: LauncherPanel
    private let search = NSSearchField()
    private let footer = NSTextField(labelWithString: ""), empty = NSTextField(labelWithString: "")
    private let background = PanelBackground(frame: NSRect(x: 0, y: 0, width: 640, height: 334))
    private let opaque: Bool
    private let activityEnabled: Bool
    private var activity: PanelActivity?
    private(set) var activityBegins = 0, activityEnds = 0
    var activityHeld: Bool { activity != nil }
    private var waitingForCatalog = false
    var onHidden: (() -> Void)?, onQuit: (() -> Void)?
    var onTiming: ((Double, Double?) -> Void)?
    var onUpdate: ((UInt64, Bool, Double) -> Void)?
    var onTextBegin: (() -> Void)?
    var onText: ((String, UInt64) -> Void)?
    private(set) var accessibilityNotifications = 0
    private(set) var warmUpMS: Double?
    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    var isMain: Bool { panel.isMainWindow }
    var footerText: String { footer.stringValue }
    var emptyText: String? { empty.isHidden ? nil : empty.stringValue }
    var text: String { search.stringValue }
    var contentView: NSView { background }
    var appearanceName: String { panel.effectiveAppearance.name.rawValue }
    var usesVibrancy: Bool { background.usesVibrancy }

    init(session: LauncherSession, icons: IconLoader, presentationAllowed: Bool = true,
         opaque: Bool = false, warmUp: Bool = true, activityEnabled: Bool = true,
         initialAppearance: NSAppearance.Name? = nil) {
        self.session = session; self.opaque = opaque; self.activityEnabled = activityEnabled
        rows = ResultsView(icons: icons)
        panel = LauncherPanel(presentationAllowed: presentationAllowed)
        super.init()
        if let initialAppearance { panel.appearance = NSAppearance(named: initialAppearance) }
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isMovable = false; panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self; panel.onKey = { [weak self] in self?.keyEquivalent($0) ?? false }
        onQuit = { [weak self] in self?.hide(); NSApp.terminate(nil) }
        build()
        session.onChange = { [weak self] in self?.update() }
        rows.onSelect = { [weak session] in session?.select(id: $0) }
        rows.onActivate = { [weak session] in session?.activate(id: $0) }
        rows.onScroll = { [weak session] in session?.scroll($0) }
        rows.onAccessibilitySelection = { [weak self] in
            guard let self else { return }
            self.accessibilityNotifications += 1
            if self.panel.presentationAllowed && self.panel.isVisible {
                NSAccessibility.post(element: self.rows, notification: .selectedRowsChanged)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(colorsChanged), name: NSColor.systemColorsDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(colorsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        if warmUp { self.warmUp() }
    }
    private func build() {
        background.wantsLayer = true
        panel.contentView = background
        let magnifier = NSImageView(frame: NSRect(x: 16, y: 304, width: 18, height: 18))
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        magnifier.contentTintColor = .secondaryLabelColor; background.addSubview(magnifier)
        search.frame = NSRect(x: 43, y: 301, width: 580, height: 24)
        search.font = .systemFont(ofSize: 16); search.isBezeled = false; search.drawsBackground = false
        search.cell?.usesSingleLineMode = true
        search.maximumRecents = 0; search.searchMenuTemplate = nil
        search.sendsSearchStringImmediately = true; search.sendsWholeSearchString = false
        if let cell = search.cell as? NSSearchFieldCell { cell.searchButtonCell = nil; cell.cancelButtonCell = nil }
        search.allowsWritingTools = false; search.allowsWritingToolsAffordance = false
        search.isAutomaticTextCompletionEnabled = false
        search.focusRingType = .none; search.placeholderString = "Search"; search.delegate = self
        search.setAccessibilityLabel("Search apps, settings, files and folders"); background.addSubview(search)
        for y in [293.0, 28.0] {
            let rule = NSBox(frame: NSRect(x: 0, y: y, width: 640, height: 1)); rule.boxType = .separator; background.addSubview(rule)
        }
        background.addSubview(rows)
        empty.frame = NSRect(x: 15, y: 259, width: 610, height: 22); empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor; empty.isHidden = true; background.addSubview(empty)
        footer.frame = NSRect(x: 15, y: 4, width: 610, height: 20); footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor; background.addSubview(footer)
        colorsChanged()
    }
    @objc private func colorsChanged() {
        let solid = opaque || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        panel.isOpaque = solid; panel.backgroundColor = solid ? .windowBackgroundColor : .clear
        background.configure(vibrancy: !solid)
        rows.invalidateAppearance(); background.needsDisplay = true
    }
    func warmUp() {
        let start = ContinuousClock.now
        background.layoutSubtreeIfNeeded(); _ = try? render()
        warmUpMS = durationMS(start.duration(to: .now))
    }
    func show(start: ContinuousClock.Instant = .now) {
        guard panel.presentationAllowed else { return }
        beginShowing()
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - 320, y: area.midY - 167))
        }
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search)
        let shown = durationMS(start.duration(to: .now)); onTiming?(shown, nil)
        // An implicit transaction completion is only a proxy, never a presentation timestamp.
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated {
            self?.onTiming?(shown, durationMS(start.duration(to: .now)))
        } }
    }
    private func beginShowing() {
        if activityEnabled && activity == nil { activity = PanelActivity(); activityBegins += 1 }
        editor?.unmarkText(); search.stringValue = ""; editor?.string = ""
        editor?.setSelectedRange(NSRange(location: 0, length: 0))
        session.show(); update()
    }
    func beginHiddenShowing() throws {
        guard !panel.presentationAllowed else { throw SourceError("Hidden checks require a non-presenting panel.") }
        beginShowing(); try verifyHidden()
    }
    func verifyHidden() throws {
        guard !panel.isVisible, !panel.isKeyWindow, !panel.isMainWindow, !NSApp.isActive,
              !panel.canBecomeKey, !panel.canBecomeMain else { throw SourceError("The automated panel acquired presentation or focus.") }
    }
    func hide() { session.hide(); panel.orderOut(nil) }
    func windowDidResignKey(_ notification: Notification) { if session.model.visible && panel.presentationAllowed { hide(); onHidden?() } }
    private var editor: NSTextView? { search.currentEditor() as? NSTextView ?? panel.firstResponder as? NSTextView }
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let editor else { return }
        // Search syntax and filenames must never be rewritten by prose editing services.
        editor.isAutomaticTextCompletionEnabled = false; editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.smartInsertDeleteEnabled = false
        editor.writingToolsBehavior = .none
    }
    func controlTextDidChange(_ notification: Notification) {
        onTextBegin?()
        session.edit(search.stringValue, composing: editor?.hasMarkedText() ?? false)
        onText?(search.stringValue, session.model.revision)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { session.setComposing(true); return false }
        session.setComposing(false)
        switch selector {
        case #selector(NSResponder.moveUp(_:)): session.move(-1); return true
        case #selector(NSResponder.moveDown(_:)): session.move(1); return true
        case #selector(NSResponder.insertNewline(_:)): session.act(.open, isRepeat: NSApp.currentEvent?.isARepeat ?? false); return true
        case #selector(NSResponder.cancelOperation(_:)): return escape()
        default: return false
        }
    }
    @discardableResult func escape() -> Bool {
        let handled = session.escape()
        if handled {
            search.stringValue = session.model.query; editor?.string = session.model.query
            editor?.setSelectedRange(NSRange(location: session.model.query.utf16.count, length: 0))
            if !session.model.visible { panel.orderOut(nil) }
        }
        return handled
    }
    func keyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "q" { onQuit?(); return true }
        guard !(editor?.hasMarkedText() ?? false) else { session.setComposing(true); return false }
        session.setComposing(false)
        if flags == .command {
            if event.keyCode == 36 { session.act(.reveal, isRepeat: event.isARepeat); return true }
            if event.charactersIgnoringModifiers?.lowercased() == "c" { session.act(.copyPath, isRepeat: event.isARepeat); return true }
            if let value = event.charactersIgnoringModifiers, let number = Int(value), (1...9).contains(number) {
                let index = rows.firstVisible + number - 1
                if rows.visibleIndices.contains(index) { session.activate(id: rows.contents[index].id, isRepeat: event.isARepeat) }
                return true
            }
        }
        return false
    }
    private func update() {
        if !session.model.visible && activity != nil { activity = nil; activityEnds += 1 }
        let start = ContinuousClock.now
        defer { onUpdate?(session.model.revision, session.model.pending, durationMS(start.duration(to: .now))) }
        if session.model.pending && session.isCatalogReady {
            if rows.firstVisible != session.model.firstVisibleRow { rows.apply(session.model) }
            if waitingForCatalog { waitingForCatalog = false; empty.isHidden = true; footer.stringValue = "" }
            return
        }
        rows.apply(session.model)
        let blank = session.model.query.isEmpty
        waitingForCatalog = !blank && session.model.pending && !session.isCatalogReady
        empty.isHidden = blank || !session.model.rows.isEmpty
        empty.stringValue = waitingForCatalog ? "Searching…" : "No results"
        if blank { footer.stringValue = "" }
        else if waitingForCatalog { footer.stringValue = "" }
        else if session.model.restartArmed { footer.stringValue = "↩ Confirm Restart   esc Cancel" }
        else if session.model.selected?.entry.target.fileURL != nil { footer.stringValue = "↩ Open   ⌘↩ Reveal in Finder   ⌘C Copy path" }
        else { footer.stringValue = session.model.rows.isEmpty ? "" : "↩ Open" }
    }
    /// Existing smoke checks enter via the text-field delegate, with no presentation.
    func enterTestQuery(_ value: String) {
        search.stringValue = value; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
    }
    /// Native field-editor input, delivered directly to this hidden window (never global events).
    func injectText(_ value: String) throws {
        try verifyHidden()
        if search.currentEditor() == nil { panel.makeFirstResponder(search) }
        guard let textView = search.currentEditor() as? NSTextView else { throw SourceError("Fixture field editor is unavailable.") }
        // Match real incremental typing/deletion instead of replacing the entire query each key.
        let old = textView.string, prefix = zip(old, value).prefix { $0 == $1 }.count
        let unchanged = String(value.prefix(prefix)).utf16.count
        textView.insertText(String(value.dropFirst(prefix)), replacementRange: NSRange(location: unchanged, length: old.utf16.count - unchanged))
        guard search.stringValue == value, session.model.query == value else { throw SourceError("Field-editor text did not reach the search delegate.") }
        try verifyHidden()
    }
    func hiddenEditor() throws -> NSTextView {
        try verifyHidden()
        guard let editor else { throw SourceError("Fixture editor is unavailable.") }
        return editor
    }
    func verifyPendingPresentation() throws {
        guard !session.model.pending, session.isCatalogReady else { throw SourceError("Fixture results are not ready.") }
        let query = search.stringValue, previous = rows.contents, oldFooter = footer.stringValue, oldEmpty = emptyText
        defer { enterTestQuery(query) }
        for text in ["t", "te", ".pending fixture"] {
            enterTestQuery(text)
            guard session.model.pending, rows.contents == previous, footer.stringValue == oldFooter, emptyText == oldEmpty else {
                throw SourceError("Pending query changed the presentation.")
            }
        }
    }
    func setAppearance(dark: Bool) { panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); rows.invalidateAppearance(); colorsChanged() }
    func render() throws -> NSBitmapImageRep {
        background.layoutSubtreeIfNeeded()
        guard let rep = background.bitmapImageRepForCachingDisplay(in: background.bounds) else { throw SourceError("The panel could not be rendered.") }
        background.effectiveAppearance.performAsCurrentDrawingAppearance {
            background.cacheDisplay(in: background.bounds, to: rep)
        }
        return rep
    }
    func capture(to url: URL) throws {
        guard let data = try render().representation(using: .png, properties: [:]) else { throw SourceError("The panel render could not be encoded.") }
        try data.write(to: url, options: .atomic)
    }
}
