import AppKit
import ApparateCore

@MainActor final class SettingsWindow: NSObject, NSToolbarDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    enum Tab: String, CaseIterable { case general = "General", search = "Search", folders = "Folders" }
    let window: PreferencesNativeWindow
    let model: SettingsModel
    private(set) var tab = Tab.general
    private(set) var recording = false
    var onKeyboardShortcuts: (() -> Void)?, onRevealConfig: (() -> Void)?
    var onPickFolders: ((NSWindow, @escaping ([String]) -> Void) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private var handlers: [ControlAction] = [], monitor: Any?, timer: Timer?
    private var shortcutBase = AppConfig.HotKey()
    private let toolbar = NSToolbar(identifier: "settings")
    private let content = PreferencesContent(), stack = NSStackView()
    private let configError = NSTextField(wrappingLabelWithString: ""), inlineError = NSTextField(wrappingLabelWithString: "")
    private let reveal = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let shortcut = NSButton(title: "", target: nil, action: nil), keyboard = NSButton(title: "Open Keyboard Shortcuts…", target: nil, action: nil)
    private let spotlight = NSTextField(labelWithString: "Spotlight also uses ⌘Space.")
    private let login = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let loginStatus = NSTextField(labelWithString: ""), activeKey = NSTextField(wrappingLabelWithString: "")
    private let menuIcon = NSButton(checkboxWithTitle: "Show menu bar icon", target: nil, action: nil)
    private let presets = NSPopUpButton(), url = NSTextField()
    private let prefixes = NSTableView(), folders = NSTableView()
    private let prefixAdd = NSPopUpButton(frame: .zero, pullsDown: true), prefixRemove = NSButton(title: "−", target: nil, action: nil)
    private let folderAdd = NSButton(title: "+", target: nil, action: nil), folderRemove = NSButton(title: "−", target: nil, action: nil)
    private let respect = NSButton(checkboxWithTitle: "Skip files listed in .gitignore", target: nil, action: nil)
    private let indexText = NSTextField(labelWithString: ""), indexError = NSTextField(wrappingLabelWithString: "")
    private let rebuild = NSButton(title: "Rebuild", target: nil, action: nil), allow = NSButton(title: "Allow Access…", target: nil, action: nil)
    private var pages: [Tab: NSView] = [:], controls: [NSControl] = []
    private var draftScope: SearchScope?
    private var renderedScopes: [SearchScope] = [], renderedFolders: [AppConfig.Folder] = []
    private var renderedPrefixes: [String: String] = [:]
    private enum Edit { case url(String), prefix(SearchScope, String?), depth(String, Int) }
    private var editing: Edit?
    private var scopes: [SearchScope] { SearchScope.allCases.filter { model.config.prefixes[$0.rawValue] != nil || $0 == draftScope } }

    init(model: SettingsModel, presentationAllowed: Bool) {
        self.model = model
        window = PreferencesNativeWindow(title: "Apparate Settings", size: NSSize(width: 620, height: 280), presentationAllowed: presentationAllowed)
        super.init()
        window.delegate = self; window.toolbarStyle = .preference
        toolbar.delegate = self; toolbar.displayMode = .iconAndLabel; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar; window.contentView = content
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20)])
        configError.preferredMaxLayoutWidth = 580; inlineError.preferredMaxLayoutWidth = 580; activeKey.preferredMaxLayoutWidth = 468
        configError.textColor = .systemRed; inlineError.textColor = .systemRed; indexError.textColor = .secondaryLabelColor
        for label in [configError, inlineError, activeKey, indexError] { label.font = .systemFont(ofSize: 12) }
        bind(reveal) { [weak self] _ in self?.onRevealConfig?() }
        bind(shortcut) { [weak self] _ in self?.startRecording() }
        bind(keyboard) { [weak self] _ in self?.onKeyboardShortcuts?() }
        bind(login) { [weak self] _ in
            guard let self else { return }
            // A mixed checkbox cycles to On in AppKit; pending approval must toggle off.
            self.model.setLogin(self.model.loginState == .notRegistered)
        }
        bind(menuIcon) { [weak self] control in guard let self else { return }; self.model.set(\.showMenuBarIcon, from: self.model.config.showMenuBarIcon, to: (control as! NSButton).state == .on) }
        login.allowsMixedState = true; loginStatus.textColor = .secondaryLabelColor
        pages[.general] = grid([[label("Hotkey"), shortcut], [label(""), activeKey], [label(""), vertical([spotlight, keyboard])], [label(""), vertical([login, loginStatus])], [label(""), menuIcon]])
        presets.addItems(withTitles: SearchPreset.allCases.map(\.rawValue) + ["Custom"])
        bind(presets) { [weak self] _ in
            guard let self else { return }
            if presets.indexOfSelectedItem < SearchPreset.allCases.count { model.set(\.searchURL, from: model.config.searchURL, to: SearchPreset.allCases[presets.indexOfSelectedItem].url) }
            else { window.makeFirstResponder(url); url.selectText(nil) }
        }
        url.identifier = .init("url"); url.delegate = self; url.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        url.widthAnchor.constraint(equalToConstant: 440).isActive = true
        let prefixScroll = table(prefixes, columns: [("prefix", "Prefix", 90), ("scope", "Searches", 450)], height: 108)
        bind(prefixAdd) { [weak self] _ in
            guard let self, let raw = prefixAdd.selectedItem?.representedObject as? String, let scope = SearchScope(rawValue: raw) else { return }
            beginPrefix(scope)
        }
        bind(prefixRemove) { [weak self] _ in self?.removePrefix() }
        pages[.search] = vertical([prefixScroll, horizontal([prefixAdd, prefixRemove]), grid([[label("Search engine"), presets], [label("Search URL"), url]])])
        let folderScroll = table(folders, columns: [("path", "Folder", 475), ("depth", "Depth", 65)], height: 180)
        bind(folderAdd) { [weak self] _ in guard let self else { return }; onPickFolders?(window) { [weak self] paths in self?.model.addFolders(paths) } }
        bind(folderRemove) { [weak self] _ in self?.removeFolder() }
        bind(respect) { [weak self] control in guard let self else { return }; self.model.set(\.respectGitignore, from: self.model.config.respectGitignore, to: (control as! NSButton).state == .on) }
        bind(rebuild) { [weak self] _ in self?.model.rebuild() }
        bind(allow) { [weak self] _ in self?.model.requestAccess() }
        pages[.folders] = vertical([folderScroll, horizontal([folderAdd, folderRemove, allow]), respect, horizontal([label("Index"), indexText, rebuild]), indexError])
        controls = [shortcut, keyboard, login, menuIcon, presets, url, prefixAdd, prefixRemove, folderAdd, folderRemove, respect, rebuild, allow]
        for (id, control) in [("url", url as NSControl), ("menu-icon", menuIcon), ("login", login), ("preset", presets),
            ("folder-add", folderAdd), ("folder-remove", folderRemove), ("prefix-add", prefixAdd), ("prefix-remove", prefixRemove),
            ("respect", respect), ("rebuild", rebuild), ("allow", allow), ("reveal", reveal), ("keyboard", keyboard)] {
            control.identifier = .init(id)
        }
        setTab(.general)
    }
    isolated deinit { stopRecording(); timer?.invalidate() }
    private func bind(_ control: NSControl, _ action: @escaping (NSControl) -> Void) {
        let handler = ControlAction(action); handlers.append(handler); control.target = handler; control.action = #selector(ControlAction.fire(_:))
        if let button = control as? NSButton, button !== login && button !== menuIcon && button !== respect { button.bezelStyle = .rounded }
    }
    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
    private func horizontal(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8; return row
    }
    private func vertical(_ views: [NSView]) -> NSStackView {
        let column = NSStackView(views: views); column.orientation = .vertical; column.alignment = .leading; column.spacing = 10; return column
    }
    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows); grid.rowSpacing = 14; grid.columnSpacing = 12
        grid.column(at: 0).width = 100; grid.column(at: 1).width = 468
        grid.column(at: 0).xPlacement = .trailing; grid.column(at: 1).xPlacement = .leading
        grid.yPlacement = .center; return grid
    }
    private func table(_ table: NSTableView, columns: [(String, String, CGFloat)], height: CGFloat) -> NSScrollView {
        for (id, title, width) in columns { let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = width; table.addTableColumn(c) }
        table.identifier = .init(table === prefixes ? "prefix-table" : "folder-table")
        table.rowHeight = table === prefixes ? 24 : 36
        table.delegate = self; table.dataSource = self; table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true; table.style = .plain
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 580).isActive = true; scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Tab.allCases.map { .init($0.rawValue) } }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let tab = Tab(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id); item.label = tab.rawValue; item.target = self; item.action = #selector(selectToolbar(_:))
        item.image = NSImage(systemSymbolName: tab == .general ? "gearshape" : tab == .search ? "magnifyingglass" : "folder", accessibilityDescription: tab.rawValue)
        return item
    }
    @objc private func selectToolbar(_ sender: NSToolbarItem) { if let tab = Tab(rawValue: sender.itemIdentifier.rawValue) { setTab(tab) } }
    func setTab(_ next: Tab) {
        stopRecording(); window.makeFirstResponder(nil); editing = nil; tab = next
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        stack.addArrangedSubview(configError); stack.addArrangedSubview(reveal)
        stack.addArrangedSubview(pages[next]!); stack.addArrangedSubview(inlineError)
        toolbar.selectedItemIdentifier = .init(next.rawValue); refresh(); updateTimer()
    }
    func show(tab: Tab? = nil) { if let tab { setTab(tab) }; model.refresh(); refresh(); window.present(); updateTimer() }
    func close() { stopRecording(); model.cancelAccess(); timer?.invalidate(); timer = nil; window.close() }
    func windowWillClose(_ notification: Notification) { stopRecording(); model.cancelAccess(); timer?.invalidate(); timer = nil }
    func windowDidBecomeKey(_ notification: Notification) { model.refresh(); refresh(); updateTimer() }
    func windowDidResignKey(_ notification: Notification) { stopRecording() }
    private func updateTimer() {
        timer?.invalidate(); timer = nil
        if tab == .folders && window.isVisible {
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateIndex() } }
        }
    }
    private func updateIndex() { indexText.stringValue = model.index.text(now: Date()); indexError.stringValue = model.index.error ?? ""; indexError.isHidden = model.index.error == nil }
    func refresh() {
        let enabled = model.editable
        configError.stringValue = model.store.errors.joined(separator: "\n"); configError.isHidden = enabled; reveal.isHidden = enabled
        inlineError.stringValue = model.error ?? ""; inlineError.isHidden = model.error == nil
        for control in controls { control.isEnabled = enabled }
        if !enabled { stopRecording() }
        if !recording { shortcut.title = model.config.hotKey.display }
        activeKey.stringValue = model.hotkeyError.map { _ in "Shortcut unavailable. " + (model.hotkey.active.map { "Using \($0.display)." } ?? "Choose another shortcut.") } ?? ""
        activeKey.isHidden = model.hotkeyError == nil
        spotlight.isHidden = !model.spotlightNotice; keyboard.isHidden = !model.spotlightNotice
        if let grid = pages[.general] as? NSGridView { grid.row(at: 1).isHidden = activeKey.isHidden; grid.row(at: 2).isHidden = !model.spotlightNotice }
        menuIcon.state = model.config.showMenuBarIcon ? .on : .off
        login.state = model.loginState == .enabled ? .on : model.loginState == .requiresApproval ? .mixed : .off
        login.isEnabled = enabled && model.loginState != .unavailable
        loginStatus.stringValue = model.loginState == .requiresApproval ? "Approval required in Login Items" : model.loginState == .unavailable ? "Launch at login is unavailable for this app." : ""
        loginStatus.isHidden = loginStatus.stringValue.isEmpty
        if url.currentEditor() == nil { url.stringValue = model.config.searchURL }
        presets.selectItem(at: model.preset.flatMap { SearchPreset.allCases.firstIndex(of: $0) } ?? SearchPreset.allCases.count)
        respect.state = model.config.respectGitignore ? .on : .off
        allow.isHidden = !model.needsAccess; allow.isEnabled = enabled && !model.access.busy
        rebuild.isEnabled = enabled && !model.index.indexing
        prefixAdd.removeAllItems(); prefixAdd.addItem(withTitle: "+")
        for scope in SearchScope.allCases where model.config.prefixes[scope.rawValue] == nil {
            prefixAdd.addItem(withTitle: scopeName(scope)); prefixAdd.lastItem?.representedObject = scope.rawValue
        }
        prefixAdd.isEnabled = enabled && prefixAdd.numberOfItems > 1 && draftScope == nil
        if editing == nil {
            let prefix = renderedScopes.indices.contains(prefixes.selectedRow) ? renderedScopes[prefixes.selectedRow] : nil
            let path = renderedFolders.indices.contains(folders.selectedRow) ? model.normalized(renderedFolders[folders.selectedRow].path) : nil
            renderedScopes = scopes; renderedFolders = model.config.folders; renderedPrefixes = model.config.prefixes
            prefixes.reloadData(); folders.reloadData()
            prefixes.deselectAll(nil); folders.deselectAll(nil)
            if let prefix, let i = renderedScopes.firstIndex(of: prefix) { prefixes.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }
            if let path, let i = renderedFolders.firstIndex(where: { model.normalized($0.path) == path }) { folders.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false) }
        }
        selectionButtons(); updateIndex()
        stack.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 620, height: ceil(stack.fittingSize.height) + 40))
    }
    private func selectionButtons() {
        prefixRemove.isEnabled = model.editable && renderedScopes.indices.contains(prefixes.selectedRow)
        folderRemove.isEnabled = model.editable && renderedFolders.indices.contains(folders.selectedRow)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectionButtons() }
    private func scopeName(_ scope: SearchScope) -> String { scope == .files ? "Files and folders" : scope.rawValue.capitalized }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === prefixes ? renderedScopes.count : renderedFolders.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === prefixes {
            guard renderedScopes.indices.contains(row) else { return nil }; let scope = renderedScopes[row]
            if tableColumn?.identifier.rawValue == "scope" { return cell(label(scopeName(scope))) }
            return cell(editor(renderedPrefixes[scope.rawValue] ?? "", id: "prefix:" + scope.rawValue))
        }
        guard renderedFolders.indices.contains(row) else { return nil }
        let folder = renderedFolders[row], path = model.normalized(folder.path)
        if tableColumn?.identifier.rawValue == "depth" { return cell(editor(String(folder.depth), id: "depth:" + path)) }
        let title = label(model.displayed(folder.path)); title.lineBreakMode = .byTruncatingMiddle; title.toolTip = path
        let state = model.index.roots.first { $0.path == path }?.status
        let text: String
        switch state { case .denied: text = "Denied"; case .notFound: text = "Not found"; case .unavailable: text = "Unavailable"; case .waitingForAccess: text = "Waiting for access"; case .indexing: text = "Indexing…"; default: text = "" }
        let detail = label(text); detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        let content = vertical(text.isEmpty ? [title] : [title, detail]); content.spacing = 1
        title.setAccessibilityLabel(path + (text.isEmpty ? "" : ", " + text))
        title.widthAnchor.constraint(lessThanOrEqualToConstant: 455).isActive = true
        return cell(content, textField: title)
    }
    private func cell(_ content: NSView, textField: NSTextField? = nil) -> NSTableCellView {
        let cell = NSTableCellView(); cell.textField = textField ?? content as? NSTextField
        content.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            content.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    private func editor(_ value: String, id: String) -> NSTextField {
        let field = NSTextField(string: value); field.identifier = .init(id); field.delegate = self; field.isEnabled = model.editable
        field.isBordered = false; field.drawsBackground = false; return field
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let id = field.identifier?.rawValue else { return }
        if id == "url" { editing = .url(field.stringValue) }
        else if id.hasPrefix("prefix:"), let scope = SearchScope(rawValue: String(id.dropFirst(7))) { editing = .prefix(scope, renderedPrefixes[scope.rawValue]) }
        else if id.hasPrefix("depth:"), let folder = renderedFolders.first(where: { model.normalized($0.path) == String(id.dropFirst(6)) }) { editing = .depth(folder.path, folder.depth) }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let edit = editing else { return }; editing = nil
        switch edit {
        case .url(let old): model.set(\.searchURL, from: old, to: field.stringValue)
        case .prefix(let scope, let old):
            if model.setPrefix(scope: scope, expected: old, value: field.stringValue) { draftScope = nil }
        case .depth(let path, let old):
            if let depth = Int(field.stringValue) { model.changeFolder(path: path, expectedDepth: old, depth: depth) }
            else { model.report("Depth must be a whole number between 1 and 30.") }
        }
        refresh()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { editing = nil; draftScope = nil; window.makeFirstResponder(nil); model.clearError(); refresh(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { window.makeFirstResponder(nil); return true }
        return false
    }
    func beginPrefix(_ scope: SearchScope) {
        guard model.editable && model.config.prefixes[scope.rawValue] == nil else { return }
        draftScope = scope; refresh()
        if let row = scopes.firstIndex(of: scope) {
            prefixes.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            window.makeFirstResponder((prefixes.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField)
        }
    }
    private func removePrefix() {
        guard renderedScopes.indices.contains(prefixes.selectedRow) else { return }; let scope = renderedScopes[prefixes.selectedRow]
        if scope == draftScope { editing = nil; draftScope = nil; refresh() }
        else { model.setPrefix(scope: scope, expected: renderedPrefixes[scope.rawValue], value: nil) }
    }
    private func removeFolder() {
        guard renderedFolders.indices.contains(folders.selectedRow) else { return }; let folder = renderedFolders[folders.selectedRow]
        model.changeFolder(path: folder.path, expectedDepth: folder.depth, depth: nil)
    }
    func startRecording() {
        guard model.editable else { return }
        if recording { stopRecording(); return }
        shortcutBase = model.config.hotKey; recording = true; shortcut.title = "Type shortcut…"; onRecordingChanged?(true)
        if window.presentationAllowed && window.isKeyWindow {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                _ = self.record(event); return nil
            }
        }
    }
    @discardableResult func record(_ event: NSEvent) -> Bool {
        guard recording else { return false }
        if event.keyCode == 53 { stopRecording(); return true }
        guard let key = ShortcutEvent.key(event) else { model.report("Use a shortcut with ⌘, ⌥ or ⌃."); return true }
        let expected = shortcutBase; stopRecording(); model.setHotkey(key, expected: expected); refresh(); return true
    }
    func recordCurrentShortcut() {
        guard recording, let active = model.hotkey.active else { return }
        let expected = shortcutBase; stopRecording(); model.setHotkey(active, expected: expected); refresh()
    }
    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if recording { recording = false; onRecordingChanged?(false) }
        shortcut.title = model.config.hotKey.display
    }
    func capture(to url: URL, dark: Bool) throws { window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); refresh(); try window.capture(to: url) }
    func verifyHidden() throws { try window.verifyHidden() }
}
