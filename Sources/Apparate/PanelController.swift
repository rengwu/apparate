import AppKit
import QuartzCore
import ApparateCore

private final class LauncherPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { onKey?(event) == true || super.performKeyEquivalent(with: event) }
}
private final class LauncherRow: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
}
private final class LauncherCell: NSTableCellView {
    let lead = NSImageView(), title = NSTextField(labelWithString: ""), location = NSTextField(labelWithString: "")
    var itemID = ""
    override init(frame: NSRect) {
        super.init(frame: frame)
        lead.frame = NSRect(x: 4, y: 4, width: 20, height: 20)
        title.frame = NSRect(x: 34, y: 4, width: 290, height: 20); title.font = .systemFont(ofSize: 13)
        location.frame = NSRect(x: 330, y: 4, width: 278, height: 20); location.font = .systemFont(ofSize: 12)
        location.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail; location.lineBreakMode = .byTruncatingMiddle
        [lead, title, location].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class PanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    let session: LauncherSession
    private let panel: LauncherPanel
    private let search = NSTextField(), table = NSTableView(), scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: ""), empty = NSTextField(labelWithString: "")
    private let icons: IconLoader
    private var applying = false, waitingForCatalog = false
    var onHidden: (() -> Void)?
    var onTiming: ((Double, Double?) -> Void)?
    var isVisible: Bool { panel.isVisible }
    init(session: LauncherSession, icons: IconLoader) {
        self.session = session; self.icons = icons
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 334),
                              styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isMovable = false; panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self; panel.onKey = { [weak self] in self?.keyEquivalent($0) ?? false }
        build()
        session.onChange = { [weak self] in self?.update() }
    }
    private func build() {
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 640, height: 334))
        background.material = .popover; background.state = .active; background.wantsLayer = true
        panel.contentView = background
        let magnifier = NSImageView(frame: NSRect(x: 16, y: 299, width: 20, height: 20))
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        magnifier.contentTintColor = .secondaryLabelColor; background.addSubview(magnifier)
        search.frame = NSRect(x: 46, y: 294, width: 578, height: 30)
        search.font = .systemFont(ofSize: 20); search.isBezeled = false; search.drawsBackground = false
        search.focusRingType = .none; search.placeholderString = "Search"; search.delegate = self
        search.setAccessibilityLabel("Search apps and settings"); background.addSubview(search)
        for y in [283.0, 30.0] {
            let rule = NSBox(frame: NSRect(x: 0, y: y, width: 640, height: 1)); rule.boxType = .separator; background.addSubview(rule)
        }
        scroll.frame = NSRect(x: 10, y: 31, width: 620, height: 252)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        table.headerView = nil; table.rowHeight = 28; table.intercellSpacing = .zero
        table.backgroundColor = .clear; table.focusRingType = .none; table.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item")); column.width = 620; table.addTableColumn(column)
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openSelection)
        scroll.documentView = table; background.addSubview(scroll)
        empty.frame = NSRect(x: 18, y: 248, width: 600, height: 24); empty.textColor = .secondaryLabelColor; background.addSubview(empty)
        footer.frame = NSRect(x: 16, y: 5, width: 608, height: 20); footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor; background.addSubview(footer)
    }
    func show(start: ContinuousClock.Instant = .now) {
        search.stringValue = ""; session.show(); update(force: true)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - 320, y: area.midY - 167))
        }
        CATransaction.setDisableActions(true)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search)
        let shown = durationMS(start.duration(to: .now)); onTiming?(shown, nil)
        // Completion of the next implicit, non-animated transaction is a commit proxy,
        // not a display/presentation timestamp. No flush or synchronous draw is forced here.
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.onTiming?(shown, durationMS(start.duration(to: .now))) }
        }
    }
    func hide() { session.hide(); panel.orderOut(nil) }
    func windowDidResignKey(_ notification: Notification) { if session.model.visible { hide(); onHidden?() } }
    func controlTextDidChange(_ notification: Notification) {
        session.edit(search.stringValue, composing: (search.currentEditor() as? NSTextView)?.hasMarkedText() ?? false)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { session.setComposing(true); return false }
        session.setComposing(false)
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): session.move(-1); return true
        case #selector(NSResponder.moveDown(_:)): session.move(1); return true
        case #selector(NSResponder.insertNewline(_:)): session.act(.open, isRepeat: NSApp.currentEvent?.isARepeat ?? false); return true
        case #selector(NSResponder.cancelOperation(_:)): hide(); return true
        default: return false
        }
    }
    private func keyEquivalent(_ event: NSEvent) -> Bool {
        guard !((search.currentEditor() as? NSTextView)?.hasMarkedText() ?? false) else { session.setComposing(true); return false }
        session.setComposing(false)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if event.keyCode == 36 { session.act(.reveal, isRepeat: event.isARepeat); return true }
            if event.charactersIgnoringModifiers?.lowercased() == "c" { session.act(.copyPath, isRepeat: event.isARepeat); return true }
        }
        return false
    }
    @objc private func openSelection() { session.act(.open) }
    func numberOfRows(in tableView: NSTableView) -> Int { session.model.rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { LauncherRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard session.model.rows.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell"), owner: self) as? LauncherCell) ?? LauncherCell()
        cell.identifier = NSUserInterfaceItemIdentifier("cell")
        let item = session.model.rows[row].entry
        cell.itemID = item.item.id; cell.title.stringValue = item.item.name
        if item.item.id == session.model.selectedID && session.model.restartArmed { cell.title.stringValue += " — Press Return again" }
        cell.location.stringValue = item.location; cell.lead.image = nil
        icons.load(item.icon) { [weak cell] image in if cell?.itemID == item.item.id { cell?.lead.image = image } }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applying else { return }
        let row = table.selectedRow
        session.select(id: session.model.rows.indices.contains(row) ? session.model.rows[row].entry.item.id : nil)
    }
    private func update(force: Bool = false) {
        if session.model.pending && session.isCatalogReady && !force {
            if waitingForCatalog {
                waitingForCatalog = false; empty.isHidden = true; footer.stringValue = "esc Close"
            }
            return
        }
        waitingForCatalog = !session.isCatalogReady
        applying = true; defer { applying = false }
        table.reloadData()
        if let row = session.model.rows.firstIndex(where: { $0.entry.item.id == session.model.selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
        } else { table.deselectAll(nil) }
        empty.isHidden = !session.model.rows.isEmpty || session.model.query.isEmpty
        empty.stringValue = waitingForCatalog ? "Searching…" : "No results"
        if waitingForCatalog { footer.stringValue = "Searching…" }
        else if session.model.restartArmed { footer.stringValue = "↩ Confirm Restart     esc Cancel" }
        else if session.model.selected?.entry.target.fileURL != nil { footer.stringValue = "↩ Open     ⌘↩ Reveal in Finder     ⌘C Copy path     esc Close" }
        else { footer.stringValue = session.model.rows.isEmpty ? "esc Close" : "↩ Open     esc Close" }
    }
    /// Fixture driver enters through the text-field delegate; it does not prove physical IME input.
    func enterTestQuery(_ value: String) {
        search.stringValue = value; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        (search.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: value.utf16.count, length: 0))
    }
    /// The fixture driver checks the actual views before the worker can publish a result.
    func verifyPendingPresentation() throws {
        guard !session.model.pending, session.isCatalogReady else { throw SourceError("Fixture results are not ready.") }
        let query = search.stringValue, rows = session.model.rows, count = table.numberOfRows
        let previousFooter = footer.stringValue, previousEmpty = empty.stringValue, wasHidden = empty.isHidden
        defer { enterTestQuery(query) }
        for text in ["t", "te", ".pending fixture"] {
            enterTestQuery(text)
            guard session.model.pending, session.model.rows == rows, table.numberOfRows == count,
                  footer.stringValue == previousFooter, empty.stringValue == previousEmpty, empty.isHidden == wasHidden,
                  footer.stringValue != "Searching…" else { throw SourceError("Pending query changed the presentation.") }
        }
    }
    func capture(to url: URL) throws {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SourceError("The panel could not be rendered.") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw SourceError("The panel render could not be encoded.") }
        try data.write(to: url, options: .atomic)
    }
}
