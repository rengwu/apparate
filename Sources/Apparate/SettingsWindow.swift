import AppKit
import ApparateCore

@MainActor final class SettingsWindow: NSObject, NSToolbarDelegate, NSWindowDelegate, NSTextFieldDelegate {
    enum Tab: String, CaseIterable { case general = "General", search = "Search", folders = "Folders" }
    let window: PreferencesNativeWindow
    let model: SettingsModel
    private(set) var tab = Tab.general
    private(set) var recording = false
    private(set) var recordingOpenWith = false
    var onKeyboardShortcuts: (() -> Void)?, onRevealConfig: (() -> Void)?
    var onPickFolders: ((NSWindow, @escaping ([String]) -> Void) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private var handlers: [ControlAction] = [], rowHandlers: [ControlAction] = [], monitor: Any?, timer: Timer?
    private var shortcutBase = AppConfig.HotKey()
    private let toolbar = NSToolbar(identifier: "settings")
    private let content = PreferencesContent(), document = PreferencesDocument(), scroll = NSScrollView()
    private let stack = PreferencesStyle.vertical([])
    private let configError = PreferencesStyle.label("", secondary: true), inlineError = PreferencesStyle.label("", secondary: true)
    private let reveal = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let shortcut = NSButton(title: "", target: nil, action: nil), keyboard = NSButton(title: "Open Keyboard Shortcuts…", target: nil, action: nil)
    private let openWithShortcut = NSButton(title: "", target: nil, action: nil)
    private let login = NSSwitch(), menuIcon = NSSwitch(), respect = NSSwitch(), skipHidden = NSSwitch()
    private let location = NSSegmentedControl(labels: ["Inline", "Right", "Below"], trackingMode: .selectOne, target: nil, action: nil)
    private let draggedFiles = NSSegmentedControl(labels: ["Like Finder", "Never move"], trackingMode: .selectOne, target: nil, action: nil)
    private var renderedLocation = ResultLocation.inline
    private var renderedDragCanMove = true
    private var renderedSkipHidden = true
    private let presets = NSPopUpButton(), url = PreferencesField()
    private let prefixes = PreferencesCard(), folders = PreferencesCard()
    private let prefixAdd = NSPopUpButton(frame: .zero, pullsDown: true)
    private let folderAdd = NSButton(title: "Add Folders…", target: nil, action: nil)
    private let indexingSpinner = NSProgressIndicator()
    private let indexingLabel = PreferencesStyle.label("Indexing…", secondary: true)
    private var indexingIndicator: NSStackView!
    private let rebuild = NSButton(title: "Rebuild", target: nil, action: nil), allow = NSButton(title: "Allow Access…", target: nil, action: nil)
    private var shortcutCard: PreferencesCard!, spotlightRow: PreferencesRow!
    private var shortcutRow: PreferencesRow!, loginRow: PreferencesRow!, indexRow: PreferencesRow!, brokenCard: PreferencesCard!
    private var pages: [Tab: NSView] = [:], controls: [NSControl] = [], rowControls: [NSControl] = []
    private var prefixFields: [SearchScope: NSTextField] = [:]
    private var draftScope: SearchScope?
    private var renderedScopes: [SearchScope] = [], renderedStatuses: [String] = []
    private var renderedFolders: [AppConfig.Folder] = [], renderedPrefixes: [String: String] = [:]
    private enum Edit { case url(String), prefix(SearchScope, String?), depth(String, Int) }
    private var editing: Edit?
    private var scopes: [SearchScope] { SearchScope.allCases.filter { model.config.prefixes[$0.rawValue] != nil || $0 == draftScope } }

    init(model: SettingsModel, presentationAllowed: Bool) {
        self.model = model
        window = PreferencesNativeWindow(title: "Apparate Settings", size: NSSize(width: 620, height: 280), presentationAllowed: presentationAllowed)
        super.init(); window.delegate = self; window.toolbarStyle = .preference
        toolbar.delegate = self; toolbar.displayMode = .iconAndLabel; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar; window.contentView = content
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        document.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20), stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20), stack.widthAnchor.constraint(equalToConstant: 580)])
        configError.preferredMaxLayoutWidth = 556; inlineError.preferredMaxLayoutWidth = 580
        inlineError.textColor = .systemRed
        inlineError.widthAnchor.constraint(equalToConstant: 580).isActive = true
        bind(reveal) { [weak self] _ in self?.onRevealConfig?() }
        let broken = PreferencesStyle.vertical([configError, reveal], spacing: 8)
        broken.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        configError.widthAnchor.constraint(equalToConstant: 556).isActive = true
        brokenCard = PreferencesCard([broken]); brokenCard.widthAnchor.constraint(equalToConstant: 580).isActive = true
        bind(shortcut) { [weak self] _ in self?.startRecording() }
        shortcut.widthAnchor.constraint(equalToConstant: 160).isActive = true
        shortcut.heightAnchor.constraint(equalToConstant: 28).isActive = true; shortcut.bezelStyle = .regularSquare
        shortcut.wantsLayer = true; shortcut.layer?.cornerRadius = 6
        bind(openWithShortcut) { [weak self] _ in self?.startRecording(openWith: true) }
        openWithShortcut.widthAnchor.constraint(equalToConstant: 160).isActive = true
        openWithShortcut.heightAnchor.constraint(equalToConstant: 28).isActive = true; openWithShortcut.bezelStyle = .regularSquare
        openWithShortcut.wantsLayer = true; openWithShortcut.layer?.cornerRadius = 6
        bind(keyboard) { [weak self] _ in self?.onKeyboardShortcuts?() }
        bind(login) { [weak self] _ in guard let self else { return }; self.model.setLogin(self.model.loginState == .notRegistered) }
        bind(menuIcon) { [weak self] control in guard let self else { return }; self.model.set(\.showMenuBarIcon, from: self.model.config.showMenuBarIcon, to: (control as! NSSwitch).state == .on) }
        shortcutRow = PreferencesRow("Open Apparate", control: shortcut)
        loginRow = PreferencesRow("Launch at login", control: login)
        spotlightRow = PreferencesRow("Spotlight also uses ⌘Space.", control: keyboard)
        shortcutCard = PreferencesCard([shortcutRow])
        location.segmentStyle = .rounded
        bind(location) { [weak self] control in
            guard let self, ResultLocation.allCases.indices.contains((control as! NSSegmentedControl).selectedSegment) else { return }
            model.set(\.resultLocation, from: renderedLocation, to: ResultLocation.allCases[(control as! NSSegmentedControl).selectedSegment])
        }
        draggedFiles.segmentStyle = .rounded
        bind(draggedFiles) { [weak self] _ in
            guard let self else { return }
            model.set(\.dragCanMove, from: renderedDragCanMove, to: draggedFiles.selectedSegment == 0)
        }
        pages[.general] = page([shortcutCard, PreferencesCard([PreferencesRow("Open With", control: openWithShortcut)]), PreferencesCard([loginRow, PreferencesRow("Show menu bar icon", control: menuIcon)]),
                               PreferencesCard([PreferencesRow("Location in results", control: location), PreferencesRow("Dragged files", control: draggedFiles)])])
        presets.addItems(withTitles: SearchPreset.allCases.map(\.rawValue) + ["Custom"])
        bind(presets) { [weak self] _ in
            guard let self else { return }
            if presets.indexOfSelectedItem < SearchPreset.allCases.count { model.set(\.searchURL, from: model.config.searchURL, to: SearchPreset.allCases[presets.indexOfSelectedItem].url) }
            else { window.makeFirstResponder(url); url.selectText(nil) }
        }
        url.identifier = .init("url"); url.delegate = self; url.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        url.widthAnchor.constraint(equalToConstant: 556).isActive = true
        let urlRow = PreferencesStyle.vertical([PreferencesStyle.label("Search URL"), url], spacing: 8)
        urlRow.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        bind(prefixAdd) { [weak self] _ in
            guard let self, let raw = prefixAdd.selectedItem?.representedObject as? String, let scope = SearchScope(rawValue: raw) else { return }; beginPrefix(scope)
        }
        let heading = PreferencesStyle.label("Prefixes"); heading.font = .systemFont(ofSize: 13, weight: .semibold)
        pages[.search] = page([heading, prefixes, prefixAdd, PreferencesCard([PreferencesRow("Search engine", control: presets), urlRow])])
        bind(folderAdd) { [weak self] _ in guard let self else { return }; onPickFolders?(window) { [weak self] paths in self?.model.addFolders(paths) } }
        bind(respect) { [weak self] control in guard let self else { return }; self.model.set(\.respectGitignore, from: self.model.config.respectGitignore, to: (control as! NSSwitch).state == .on) }
        bind(skipHidden) { [weak self] control in guard let self else { return }; self.model.set(\.skipHiddenFiles, from: self.renderedSkipHidden, to: (control as! NSSwitch).state == .on) }
        bind(rebuild) { [weak self] _ in self?.model.rebuild() }
        bind(allow) { [weak self] _ in self?.model.requestAccess() }
        indexingSpinner.style = .spinning; indexingSpinner.controlSize = .small
        indexingSpinner.isIndeterminate = true; indexingSpinner.isDisplayedWhenStopped = true
        indexingSpinner.identifier = .init("indexing-spinner"); indexingSpinner.setAccessibilityLabel("Indexing")
        indexingSpinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        indexingSpinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        indexingLabel.maximumNumberOfLines = 1; indexingLabel.setAccessibilityElement(false)
        indexingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        indexingIndicator = PreferencesStyle.horizontal([indexingSpinner, indexingLabel]); indexingIndicator.spacing = 6
        indexingIndicator.identifier = .init("indexing-indicator")
        indexingIndicator.setContentHuggingPriority(.required, for: .horizontal)
        let folderActions = PreferencesStyle.horizontal([folderAdd, indexingIndicator, NSView(), allow])
        // Retain the progress slot even while hidden; the button fixes row height.
        folderActions.detachesHiddenViews = false
        folderActions.widthAnchor.constraint(equalToConstant: 580).isActive = true
        folderActions.heightAnchor.constraint(equalTo: folderAdd.heightAnchor).isActive = true
        folders.identifier = .init("folder-card"); folderActions.identifier = .init("folder-actions")
        indexRow = PreferencesRow("Index", control: rebuild)
        pages[.folders] = page([folders, folderActions, PreferencesCard([PreferencesRow("Skip files listed in .gitignore", control: respect), PreferencesRow("Skip hidden files", control: skipHidden)]), PreferencesCard([indexRow])])
        controls = [shortcut, openWithShortcut, keyboard, login, menuIcon, location, draggedFiles, presets, url, prefixAdd, folderAdd, respect, skipHidden, rebuild, allow]
        draggedFiles.identifier = .init("dragged-files"); draggedFiles.setAccessibilityLabel("Dragged files")
        skipHidden.identifier = .init("skip-hidden"); skipHidden.setAccessibilityLabel("Skip hidden files")
        for (id, control, label) in [("open-with-shortcut", openWithShortcut as NSControl, "Open With shortcut"), ("result-location", location as NSControl, "Location in results"), ("shortcut", shortcut as NSControl, "Open Apparate shortcut"), ("url", url, "Search URL"), ("menu-icon", menuIcon, "Show menu bar icon"), ("login", login, "Launch at login"), ("preset", presets, "Search engine"), ("folder-add", folderAdd, "Add Folders"), ("prefix-add", prefixAdd, "Add Prefix"), ("respect", respect, "Skip files listed in .gitignore"), ("rebuild", rebuild, "Rebuild index"), ("allow", allow, "Allow folder access"), ("reveal", reveal, "Show config.json in Finder"), ("keyboard", keyboard, "Open Keyboard Shortcuts")] {
            control.identifier = .init(id); control.setAccessibilityLabel(label)
        }
        setTab(.general)
    }
    isolated deinit { stopRecording(); timer?.invalidate() }
    private func bind(_ control: NSControl, row: Bool = false, _ action: @escaping (NSControl) -> Void) {
        let handler = ControlAction(action)
        if row { rowHandlers.append(handler) } else { handlers.append(handler) }
        control.target = handler; control.action = #selector(ControlAction.fire(_:))
        if let button = control as? NSButton { PreferencesStyle.button(button) }
    }
    private func page(_ views: [NSView]) -> NSView {
        let page = PreferencesStyle.vertical(views)
        page.widthAnchor.constraint(equalToConstant: 580).isActive = true
        for card in views.compactMap({ $0 as? PreferencesCard }) { card.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        return page
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
        for view in [brokenCard!, pages[next]!, inlineError] { stack.addArrangedSubview(view) }
        toolbar.selectedItemIdentifier = .init(next.rawValue); refresh(); document.scroll(.zero); updateTimer()
    }
    func show(tab: Tab? = nil) { if let tab { setTab(tab) }; model.refresh(); refresh(); window.present(); updateTimer() }
    func close() { stopRecording(); model.cancelAccess(); timer?.invalidate(); timer = nil; indexingSpinner.stopAnimation(nil); window.close() }
    func windowWillClose(_ notification: Notification) { stopRecording(); model.cancelAccess(); timer?.invalidate(); timer = nil; indexingSpinner.stopAnimation(nil) }
    func windowDidBecomeKey(_ notification: Notification) { model.refresh(); refresh(); updateTimer() }
    func windowDidResignKey(_ notification: Notification) { stopRecording() }
    private func updateTimer() {
        timer?.invalidate(); timer = nil
        updateIndexingIndicator()
        if tab == .folders && window.isVisible {
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateIndex() } }
        }
    }
    private func updateIndex() { indexRow.describe([model.index.text(now: Date()), model.index.error].compactMap { $0 }.joined(separator: "\n")) }
    private func updateIndexingIndicator() {
        indexingIndicator.isHidden = !model.index.indexing
        indexingSpinner.setAccessibilityHidden(!model.index.indexing)
        if model.index.indexing && tab == .folders && window.isVisible { indexingSpinner.startAnimation(nil) }
        else { indexingSpinner.stopAnimation(nil) }
    }
    func refresh() {
        let enabled = model.editable
        configError.stringValue = model.store.errors.joined(separator: "\n"); brokenCard.isHidden = enabled
        inlineError.stringValue = model.error ?? ""; inlineError.isHidden = model.error == nil
        for control in controls + rowControls { control.isEnabled = enabled }
        if !enabled { stopRecording() }
        if !recording || recordingOpenWith { shortcut.title = model.config.hotKey.display }
        if !recording || !recordingOpenWith { openWithShortcut.title = model.config.openWithKey.display }
        openWithShortcut.setAccessibilityLabel("Open With shortcut, " + (recording && recordingOpenWith ? "Recording; press Escape to cancel" : model.config.openWithKey.display))
        shortcut.setAccessibilityLabel("Open Apparate shortcut, " + (recording && !recordingOpenWith ? "Recording; press Escape to cancel" : model.config.hotKey.display))
        let description = model.hotkeyError.map { _ in "Shortcut unavailable. " + (model.hotkey.active.map { "Using \($0.display)." } ?? "Choose another shortcut.") } ?? ""
        shortcutRow.describe(description)
        if (spotlightRow.superview != nil) != model.spotlightNotice {
            shortcutCard.setRows(model.spotlightNotice ? [shortcutRow, spotlightRow] : [shortcutRow])
        }
        menuIcon.state = model.config.showMenuBarIcon ? .on : .off
        renderedLocation = model.config.resultLocation
        location.selectedSegment = ResultLocation.allCases.firstIndex(of: renderedLocation)!
        renderedDragCanMove = model.config.dragCanMove
        draggedFiles.selectedSegment = renderedDragCanMove ? 0 : 1
        login.state = [.enabled, .requiresApproval].contains(model.loginState) ? .on : .off
        login.isEnabled = enabled && model.loginState != .unavailable
        loginRow.describe(model.loginState == .requiresApproval ? "Approval required in Login Items" : model.loginState == .unavailable ? "Launch at login is unavailable for this app." : "")
        if url.currentEditor() == nil { url.stringValue = model.config.searchURL }
        presets.selectItem(at: model.preset.flatMap { SearchPreset.allCases.firstIndex(of: $0) } ?? SearchPreset.allCases.count)
        respect.state = model.config.respectGitignore ? .on : .off
        renderedSkipHidden = model.config.skipHiddenFiles; skipHidden.state = renderedSkipHidden ? .on : .off
        allow.isHidden = !model.needsAccess; allow.isEnabled = enabled && !model.access.busy
        rebuild.isEnabled = enabled && !model.index.indexing
        updateIndexingIndicator()
        prefixAdd.removeAllItems(); prefixAdd.addItem(withTitle: "Add Prefix")
        for scope in SearchScope.allCases where model.config.prefixes[scope.rawValue] == nil {
            prefixAdd.addItem(withTitle: scopeName(scope)); prefixAdd.lastItem?.representedObject = scope.rawValue
        }
        prefixAdd.isEnabled = enabled && prefixAdd.numberOfItems > 1 && draftScope == nil
        if editing == nil { rebuildRows() }
        updateIndex(); stack.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height) + 40
        document.setFrameSize(NSSize(width: 620, height: height))
        let available = window.screen?.visibleFrame.height ?? 800
        window.setContentSize(NSSize(width: 620, height: min(height, max(300, min(680, available - 140)))))
        content.layoutSubtreeIfNeeded()
    }
    private func scopeName(_ scope: SearchScope) -> String { scope == .files ? "Files and folders" : scope.rawValue.capitalized }
    private func field(_ value: String, id: String, label: String, width: CGFloat) -> PreferencesField {
        let field = PreferencesField(value); field.identifier = .init(id); field.delegate = self
        field.setAccessibilityLabel(label); field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.isEnabled = model.editable; rowControls.append(field); return field
    }
    private func removeButton(_ id: String, label: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: "−", target: nil, action: nil); button.identifier = .init(id)
        button.setAccessibilityLabel(label); button.toolTip = label
        bind(button, row: true) { _ in action() }; button.isEnabled = model.editable
        rowControls.append(button); return button
    }
    private func rebuildRows() {
        let statuses = model.index.roots.map { "\($0.path):\(folderStatus($0.status))" }
        if renderedPrefixes == model.config.prefixes && renderedFolders.map(\.path) == model.config.folders.map(\.path) && renderedScopes == scopes && renderedStatuses == statuses {
            renderedFolders = model.config.folders
            for control in rowControls {
                if let stepper = control as? NSStepper, let folder = renderedFolders.first(where: { "depth-stepper:" + model.normalized($0.path) == stepper.identifier?.rawValue }) { stepper.integerValue = folder.depth }
                guard let field = control as? NSTextField, let id = field.identifier?.rawValue else { continue }
                if id.hasPrefix("prefix:") { field.stringValue = model.config.prefixes[String(id.dropFirst(7))] ?? "" }
                else if let folder = renderedFolders.first(where: { "depth:" + model.normalized($0.path) == id }) { field.stringValue = String(folder.depth) }
            }
            return
        }
        renderedScopes = scopes; renderedStatuses = statuses
        rowHandlers.removeAll(); rowControls.removeAll(); prefixFields.removeAll()
        renderedPrefixes = model.config.prefixes; renderedFolders = model.config.folders
        prefixes.setRows(scopes.map { scope in
            let value = renderedPrefixes[scope.rawValue]
            let editor = field(value ?? "", id: "prefix:" + scope.rawValue, label: scopeName(scope) + " prefix", width: 40)
            editor.alignment = .center
            prefixFields[scope] = editor
            let remove = removeButton("prefix-remove:" + scope.rawValue, label: "Remove " + scopeName(scope) + " prefix") { [weak self] in
                guard let self else { return }
                if scope == draftScope { editing = nil; draftScope = nil; window.makeFirstResponder(nil); refresh() }
                else { model.setPrefix(scope: scope, expected: value, value: nil) }
            }
            return PreferencesRow(scopeName(scope), control: PreferencesStyle.horizontal([editor, remove]))
        })
        prefixes.isHidden = scopes.isEmpty
        folders.setRows(renderedFolders.map { folder in
            let path = model.normalized(folder.path)
            let editor = field(String(folder.depth), id: "depth:" + path, label: "Depth for " + path, width: 48)
            editor.alignment = .center
            let stepper = NSStepper()
            let number = PreferencesNumber(field: editor, stepper: stepper)
            stepper.minValue = 1; stepper.maxValue = 30; stepper.increment = 1; stepper.integerValue = folder.depth; stepper.valueWraps = false
            stepper.identifier = .init("depth-stepper:" + path); stepper.setAccessibilityLabel("Depth for " + path)
            stepper.isEnabled = model.editable; rowControls.append(stepper)
            bind(stepper, row: true) { [weak self, weak editor] sender in
                guard let self, let editor else { return }
                // Commit a pending text edit first. Never overwrite a validation/conflict failure.
                guard let previous = renderedFolders.first(where: { model.normalized($0.path) == path })?.depth else { return }
                let delta = (sender as! NSStepper).integerValue - previous
                let wasEditing = editor.currentEditor() != nil
                window.makeFirstResponder(nil)
                if wasEditing && model.error != nil { refresh(); return }
                let expected = wasEditing ? model.config.folders.first { model.normalized($0.path) == path }?.depth : previous
                guard let expected else { refresh(); return }
                model.changeFolder(path: folder.path, expectedDepth: expected, depth: min(30, max(1, expected + delta)))
            }
            let remove = removeButton("folder-remove:" + path, label: "Remove " + path) { [weak self] in
                guard let self, let current = renderedFolders.first(where: { model.normalized($0.path) == path }) else { return }
                model.changeFolder(path: current.path, expectedDepth: current.depth, depth: nil)
            }
            let depthLabel = PreferencesStyle.label("Depth", secondary: true)
            depthLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
            remove.widthAnchor.constraint(equalToConstant: 32).isActive = true
            let depthControls = PreferencesStyle.horizontal([depthLabel, number, remove])
            depthControls.widthAnchor.constraint(equalToConstant: 156).isActive = true
            let row = PreferencesRow(model.displayed(folder.path), control: depthControls)
            row.title.maximumNumberOfLines = 1; row.title.lineBreakMode = .byTruncatingMiddle; row.title.toolTip = path
            row.title.setAccessibilityLabel(path)
            let state = model.index.roots.first { $0.path == path }?.status
            row.describe(folderStatus(state)); return row
        })
        folders.isHidden = renderedFolders.isEmpty
    }
    private func folderStatus(_ state: FileRootStatus?) -> String {
        switch state {
        case .denied: "Denied"
        case .notFound: "Not found"
        case .unavailable: "Unavailable"
        case .waitingForAccess: "Waiting for access"
        default: ""
        }
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
        draftScope = scope; refresh(); window.makeFirstResponder(prefixFields[scope])
    }
    func startRecording(openWith: Bool = false) {
        guard model.editable else { return }
        if recording { stopRecording(); return }
        recordingOpenWith = openWith; shortcutBase = openWith ? model.config.openWithKey : model.config.hotKey; recording = true
        let button = openWith ? openWithShortcut : shortcut
        button.title = "Type shortcut…"; button.setAccessibilityLabel((openWith ? "Open With" : "Open Apparate") + " shortcut, Recording; press Escape to cancel"); onRecordingChanged?(true)
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
        guard let key = ShortcutEvent.key(event, allowShiftOnly: recordingOpenWith) else { model.report(recordingOpenWith ? "Use a shortcut with a modifier." : "Use a shortcut with ⌘, ⌥ or ⌃."); return true }
        finishRecording(key); return true
    }
    func recordCurrentShortcut() {
        guard recording, let active = model.hotkey.active else { return }
        finishRecording(active)
    }
    private func finishRecording(_ key: AppConfig.HotKey) {
        let expected = shortcutBase, openWith = recordingOpenWith; stopRecording()
        if openWith { model.set(\.openWithKey, from: expected, to: key) }
        else { model.setHotkey(key, expected: expected) }
        refresh()
    }
    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if recording { recording = false; onRecordingChanged?(false) }
        recordingOpenWith = false
        openWithShortcut.title = model.config.openWithKey.display; openWithShortcut.setAccessibilityLabel("Open With shortcut, " + model.config.openWithKey.display)
        shortcut.title = model.config.hotKey.display; shortcut.setAccessibilityLabel("Open Apparate shortcut, " + model.config.hotKey.display)
    }
#if APPARATE_TESTING
    func capture(to url: URL, dark: Bool) throws { window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); refresh(); try window.capture(to: url) }
    func verifyHidden() throws { try window.verifyHidden() }
#endif

}
