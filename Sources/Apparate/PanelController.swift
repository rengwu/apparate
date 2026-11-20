import AppKit
import QuartzCore
import ApparateCore

private final class LauncherPanel: NSPanel {
    let presentationAllowed: Bool
    var onKey: ((NSEvent) -> Bool)?
    private(set) var dispatchedKey: NSEvent?
    init(presentationAllowed: Bool) {
        self.presentationAllowed = presentationAllowed
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 41),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
    }
    override var canBecomeKey: Bool { presentationAllowed }
    override var canBecomeMain: Bool { false }
    override func orderFront(_ sender: Any?) { if presentationAllowed { super.orderFront(sender) } }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if presentationAllowed || place == .out { super.order(place, relativeTo: otherWin) }
    }
    override func sendEvent(_ event: NSEvent) {
        let previous = dispatchedKey
        if event.type == .keyDown { dispatchedKey = event }
        defer { dispatchedKey = previous }
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
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
    private let search: NSTextField
    private let footer = NSTextField(labelWithString: ""), empty = NSTextField(labelWithString: "")
    private let background = PanelBackground(frame: NSRect(x: 0, y: 0, width: 640, height: 41))
    private let opaque: Bool
    private let activityEnabled: Bool
    private var activity: PanelActivity?
#if APPARATE_TESTING
    private(set) var activityBegins = 0, activityEnds = 0
#endif
    var activityHeld: Bool { activity != nil }
#if APPARATE_TESTING
    var observationRun: UInt64?
    private(set) var observationShow: UInt64 = 0
#endif
    private let magnifier = NSImageView(), topRule = NSBox(), bottomRule = NSBox()
    private var hasCompletedPresentation = false
    private var displayedOpenWith = false
    var panelFrame: NSRect { panel.frame }
#if APPARATE_TESTING
    private(set) var layoutFrameChanges = 0
#endif
    var onHidden: (() -> Void)?, onQuit: (() -> Void)?, onSettings: (() -> Void)?
#if APPARATE_TESTING
    var onTiming: ((Double, Double?) -> Void)?
    var onUpdate: ((UInt64, Bool, Double) -> Void)?
    var onTextBegin: (() -> Void)?
    var onText: ((String, UInt64) -> Void)?
    private(set) var accessibilityNotifications = 0
    private(set) var warmUpMS: Double?
#endif
    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    var isMain: Bool { panel.isMainWindow }
    var footerText: String { footer.stringValue }
    var emptyText: String? { empty.isHidden ? nil : empty.stringValue }
    var text: String { search.stringValue }
    var placeholderText: String { search.placeholderString ?? "" }
    var contentView: NSView { background }
    var appearanceName: String { panel.effectiveAppearance.name.rawValue }
    var usesVibrancy: Bool { background.usesVibrancy }

    init(session: LauncherSession, icons: IconLoader, presentationAllowed: Bool = true,
         opaque: Bool = false, warmUp: Bool = true, activityEnabled: Bool = true,
         initialAppearance: NSAppearance.Name? = nil, bareField: Bool = false) {
        self.session = session; self.opaque = opaque; self.activityEnabled = activityEnabled
        search = bareField ? NSTextField() : NSSearchField()
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
#if APPARATE_TESTING
            self.accessibilityNotifications += 1
#endif
            if self.panel.presentationAllowed && self.panel.isVisible {
                NSAccessibility.post(element: self.rows, notification: .selectedRowsChanged)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(colorsChanged), name: NSColor.systemColorsDidChangeNotification, object: nil)
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(editorHistoryChanged), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(colorsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        if warmUp { self.warmUp() }
    }
    private func build() {
        background.wantsLayer = true
        panel.contentView = background
        rows.rowTop = PanelLayout.rowTop
        background.addSubview(rows)
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        magnifier.contentTintColor = .secondaryLabelColor; background.addSubview(magnifier)
        search.frame = NSRect(x: 43, y: 301, width: 580, height: 24)
        search.font = .systemFont(ofSize: 16); search.isBezeled = false; search.drawsBackground = false
        search.cell?.usesSingleLineMode = true
        if let search = search as? NSSearchField {
            search.maximumRecents = 0; search.searchMenuTemplate = nil
            search.sendsSearchStringImmediately = true; search.sendsWholeSearchString = false
        }
        if let cell = search.cell as? NSSearchFieldCell { cell.searchButtonCell = nil; cell.cancelButtonCell = nil }
        search.allowsWritingTools = false; search.allowsWritingToolsAffordance = false
        search.isAutomaticTextCompletionEnabled = false
        search.focusRingType = .none; search.placeholderString = "Search"; search.delegate = self
        search.setAccessibilityLabel("Search apps, settings, files and folders"); background.addSubview(search)
        for rule in [topRule, bottomRule] { rule.boxType = .separator; background.addSubview(rule) }
        empty.frame = NSRect(x: 15, y: 259, width: 610, height: 22); empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor; empty.isHidden = true; background.addSubview(empty)
        // Its native baseline puts the 11 pt cap-height midpoint at 14 pt,
        // centered in the footer's 28 pt band below the divider.
        footer.frame = NSRect(x: 15, y: 1, width: 610, height: 20); footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor; background.addSubview(footer)
        layout(rows: 0, message: false); colorsChanged()
    }
    @objc private func colorsChanged() {
        let solid = opaque || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        panel.isOpaque = solid; panel.backgroundColor = solid ? .windowBackgroundColor : .clear
        background.configure(vibrancy: !solid)
        rows.invalidateAppearance(); background.needsDisplay = true
    }
    func warmUp() {
#if APPARATE_TESTING
        let start = ContinuousClock.now
#endif
        background.layoutSubtreeIfNeeded(); _ = try? render()
#if APPARATE_TESTING
        warmUpMS = durationMS(start.duration(to: .now))
#endif
    }
    func show(start: ContinuousClock.Instant = .now) {
        guard panel.presentationAllowed else { return }
        beginShowing()
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - 320, y: area.midY + 167 - panel.frame.height))
        }
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search)
#if APPARATE_TESTING
        let shown = durationMS(start.duration(to: .now)); onTiming?(shown, nil)
        // An implicit transaction completion is only a proxy, never a presentation timestamp.
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated {
            self?.onTiming?(shown, durationMS(start.duration(to: .now)))
        } }
#endif
    }
    private func beginShowing() {
#if APPARATE_TESTING
        observationShow &+= 1
#endif
        hasCompletedPresentation = false
        if activityEnabled && activity == nil {
            activity = PanelActivity()
#if APPARATE_TESTING
            activityBegins += 1
#endif
        }
        editor?.unmarkText(); search.stringValue = ""; editor?.string = ""
        editor?.setSelectedRange(NSRange(location: 0, length: 0))
        session.show(); update()
    }
#if APPARATE_TESTING
    func beginHiddenShowing() throws {
        guard !panel.presentationAllowed else { throw SourceError("Hidden checks require a non-presenting panel.") }
        beginShowing(); try verifyHidden()
    }
    func sendHiddenKey(_ event: NSEvent) throws {
        guard !panel.presentationAllowed else { throw SourceError("Owned key checks require a hidden panel.") }
        try verifyHidden(); panel.sendEvent(event); try verifyHidden()
    }
    func verifyHidden() throws {
        guard !panel.isVisible, !panel.isKeyWindow, !panel.isMainWindow, !NSApp.isActive,
              !panel.canBecomeKey, !panel.canBecomeMain else { throw SourceError("The automated panel acquired presentation or focus.") }
    }
#endif
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
#if APPARATE_TESTING
        onTextBegin?()
#endif
        let value = editor?.string ?? search.stringValue
        session.edit(value, composing: editor?.hasMarkedText() ?? false)
#if APPARATE_TESTING
        onText?(value, session.model.revision)
#endif
    }
    @objc private func editorHistoryChanged(_ notification: Notification) {
        // Inspect the undo manager only for a history event, not on each keystroke.
        guard session.model.visible, let manager = notification.object as? UndoManager,
              manager === editor?.undoManager else { return }
        // Native history can restore NSSearchField without a control-change callback.
        // Reconcile after AppKit finishes its transaction, without polling.
        Task { @MainActor [weak self] in
            guard let self, self.session.model.visible, let editor = self.editor, editor.string != self.session.model.query else { return }
            self.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // The input method handles the key first. Any Tab command reaching this
        // delegate stays in the editor, including while composition is active.
        if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) {
            session.setComposing(textView.hasMarkedText())
            if selector == #selector(NSResponder.insertTab(_:)), !textView.hasMarkedText() { _ = completeSelection(in: textView) }
            return true
        }
        guard !textView.hasMarkedText() else { session.setComposing(true); return false }
        session.setComposing(false)
        switch selector {
        case #selector(NSResponder.moveRight(_:)):
            guard session.model.selected?.entry.item.kind == .folder,
                  textView.selectedRanges.count == 1,
                  textView.selectedRange() == NSRange(location: textView.string.utf16.count, length: 0),
                  plainRightCommand else { return false }
            return completeSelection(in: textView)
        case #selector(NSResponder.moveUp(_:)): session.move(-1); return true
        case #selector(NSResponder.moveDown(_:)): session.move(1); return true
        case #selector(NSResponder.insertNewline(_:)):
            // isARepeat is only valid on key events; editor/AX commands may have none.
            let event = NSApp.currentEvent
            session.act(.open, isRepeat: event?.type == .keyDown && event?.isARepeat == true); return true
        case #selector(NSResponder.cancelOperation(_:)): return escape()
        default: return false
        }
    }
    private var plainRightCommand: Bool {
        // Owned dispatch supplies context even for directly delivered hidden events.
        // An eventless native command remains valid; an unrelated/non-key event does not
        // supply key-only properties. Arrow function/numeric-pad bits are incidental.
        let current = NSApp.currentEvent
        let event = panel.dispatchedKey ?? (current?.type == .keyDown && current?.window === panel ? current : nil)
        guard let event else { return true }
        return event.keyCode == 124 && event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty
    }
    @discardableResult private func completeSelection(in textView: NSTextView) -> Bool {
        guard textView.string == session.model.query,
              let completion = session.completion, completion != textView.string else { return false }
        textView.breakUndoCoalescing()
        textView.insertText(completion, replacementRange: NSRange(location: 0, length: textView.string.utf16.count))
        textView.breakUndoCoalescing()
        return true
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
        if flags == .command, event.charactersIgnoringModifiers == "," { hide(); onSettings?(); return true }
        let openKey = session.openWithKey
        if event.keyCode == openKey.keyCode && flags == ShortcutEvent.modifiers(openKey) {
            session.setComposing(editor?.hasMarkedText() ?? false)
            if (editor?.string ?? search.stringValue) == session.model.query { _ = session.beginOpenWith(isRepeat: event.isARepeat) }
            return true
        }
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
        if !session.model.visible && activity != nil {
            activity = nil
#if APPARATE_TESTING
            activityEnds += 1
#endif
        }
#if APPARATE_TESTING
        let start = ContinuousClock.now
        defer { onUpdate?(session.model.revision, session.model.pending, durationMS(start.duration(to: .now))) }
#endif
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if displayedOpenWith != session.isOpenWith {
            displayedOpenWith = session.isOpenWith; hasCompletedPresentation = false
            search.stringValue = session.model.query; editor?.string = session.model.query
            editor?.setSelectedRange(NSRange(location: session.model.query.utf16.count, length: 0))
            editor?.undoManager?.removeAllActions()
        }
        search.placeholderString = session.placeholder
        search.setAccessibilityLabel(session.isOpenWith ? session.placeholder : "Search apps, settings, files and folders")
        let layoutChanged = rows.resultLocation != session.resultLocation
        rows.resultLocation = session.resultLocation
        // A pending generation keeps the last complete rows, footer and height. Clearing
        // always wins. With no accepted presentation yet, show one progress row.
        if session.model.pending && (!session.model.query.isEmpty || session.isOpenWith) && hasCompletedPresentation {
            if rows.firstVisible != session.model.firstVisibleRow { rows.apply(session.model) }
            if layoutChanged {
                layout(rows: rows.contents.count, message: !empty.isHidden)
                background.layoutSubtreeIfNeeded()
            }
            return
        }
        rows.apply(session.model)
        let blank = session.model.query.isEmpty && !session.isOpenWith
        if blank { hasCompletedPresentation = false }
        else if !session.model.pending { hasCompletedPresentation = true }
        empty.isHidden = blank || !session.model.rows.isEmpty
        empty.stringValue = session.model.pending ? "Searching…" : session.pathMessage ?? (session.isOpenWith ? "No applications" : "No results")
        if blank || session.model.pending || session.model.rows.isEmpty { footer.stringValue = "" }
        else if session.isOpenWith { footer.stringValue = "↩ Open with " + (session.model.selected?.entry.item.name ?? "") + "   esc Back" }
        else if session.model.restartArmed { footer.stringValue = "↩ Confirm Restart   esc Cancel" }
        else if session.model.selected?.entry.target.fileURL != nil { footer.stringValue = "↩ Open   ⌘↩ Reveal in Finder   ⌘C Copy path" + ((session.model.selected?.entry.item.kind == .file || session.model.selected?.entry.item.kind == .folder) ? "   " + session.openWithKey.display + " Open With…" : "") }
        else { footer.stringValue = "↩ Open" }
        layout(rows: rows.contents.count, message: !empty.isHidden)
#if APPARATE_TESTING
        if let run = observationRun, !session.model.pending {
            rows.observationMarker = FrameMarker(run: run, show: observationShow, revision: session.model.revision,
                digest: ObservationClock.digest(session.model.rows.map(\.result)))
        } else { rows.observationMarker = nil }
#endif
        rows.needsDisplay = true; background.layoutSubtreeIfNeeded()
    }
    private func layout(rows count: Int, message: Bool) {
        let height = PanelLayout.height(rows: count, message: message, location: rows.resultLocation)
        let top = panel.frame.maxY
        // Lay out the complete accepted state before changing window geometry. The
        // live observer, not this transaction, will establish atomic screen delivery.
        background.setFrameSize(NSSize(width: 640, height: height))
        rows.frame = NSRect(x: 6, y: 0, width: 628, height: height)
        // Center the 16 pt text's cap height in the 40 pt search row. AppKit draws
        // it high within this borderless 24 pt cell; move the whole native field
        // down 2 pt so its editor, placeholder and marked text move together.
        magnifier.frame = NSRect(x: 16, y: height - 29, width: 18, height: 18)
        var searchWidth: CGFloat = 580
#if APPARATE_TESTING
        if observationRun != nil { searchWidth = 536 }
#endif
        search.frame = NSRect(x: 43, y: height - 35, width: searchWidth, height: 24)
        topRule.frame = NSRect(x: 0, y: height - 41, width: 640, height: 1)
        topRule.isHidden = count == 0 && !message
        bottomRule.frame = NSRect(x: 0, y: 28, width: 640, height: 1); bottomRule.isHidden = count == 0
        footer.isHidden = count == 0
        empty.frame = NSRect(x: 15, y: height - 75, width: 610, height: 22)
        let frame = NSRect(x: panel.frame.minX, y: top - height, width: 640, height: height)
        if panel.frame != frame {
#if APPARATE_TESTING
            layoutFrameChanges += 1
#endif
            panel.setFrame(frame, display: false, animate: false)
        }
    }
#if APPARATE_TESTING
    /// Existing smoke checks enter via the text-field delegate, with no presentation.
    func enterTestQuery(_ value: String) {
        search.stringValue = value; editor?.string = value
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
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
        let query = search.stringValue, previous = rows.contents, oldFooter = footer.stringValue, oldEmpty = emptyText, oldFrame = panel.frame
        defer { enterTestQuery(query) }
        for text in ["t", "te", ".pending fixture"] {
            enterTestQuery(text)
            guard session.model.pending, rows.contents == previous, footer.stringValue == oldFooter, emptyText == oldEmpty, panel.frame == oldFrame else {
                throw SourceError("Pending query changed the presentation.")
            }
        }
    }
    func setAppearance(dark: Bool) { panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); rows.invalidateAppearance(); colorsChanged() }
#endif
    func render() throws -> NSBitmapImageRep {
        background.layoutSubtreeIfNeeded()
        guard let rep = background.bitmapImageRepForCachingDisplay(in: background.bounds) else { throw SourceError("The panel could not be rendered.") }
        background.effectiveAppearance.performAsCurrentDrawingAppearance {
            background.cacheDisplay(in: background.bounds, to: rep)
        }
        return rep
    }
#if APPARATE_TESTING
    func capture(to url: URL) throws {
        guard let data = try render().representation(using: url.pathExtension == "jpg" ? .jpeg : .png, properties: [.compressionFactor: 0.82]) else { throw SourceError("The panel render could not be encoded.") }
        try data.write(to: url, options: .atomic)
    }
#endif

}
