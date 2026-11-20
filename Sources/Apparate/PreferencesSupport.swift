import AppKit
import Carbon
import ServiceManagement
import ApparateCore

@MainActor final class NativeLoginService: LoginServicing {
    private var supported: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }
    var state: LoginState {
        guard supported else { return .unavailable }
        return Self.state(for: SMAppService.mainApp.status)
    }
    static func state(for status: SMAppService.Status) -> LoginState {
        switch status {
        case .enabled: return .enabled
        // A never-registered ad-hoc bundle can report notFound. Registration
        // must remain available; its result is read back instead of assumed.
        case .notRegistered, .notFound: return .notRegistered
        case .requiresApproval: return .requiresApproval
        @unknown default: return .notRegistered
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
    var status: SMAppService.Status
    var supported = true
    var state: LoginState { supported ? NativeLoginService.state(for: status) : .unavailable }
    var changes: [Bool] = [], failure = false
    init(status: SMAppService.Status = .notRegistered) { self.status = status }
    func setEnabled(_ enabled: Bool) throws {
        changes.append(enabled)
        if failure { throw SourceError("Fixture login change refused.") }
        status = enabled ? .enabled : .notRegistered
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
    override func draw(_ dirtyRect: NSRect) { PreferencesStyle.background.setFill(); dirtyRect.fill() }
}
// Shared native preferences surfaces. Controls retain AppKit editing, focus and AX behavior.
@MainActor enum PreferencesStyle {
    static let background = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.94, alpha: 1) }
    static let fieldFill = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1) }
    static func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: secondary ? 11 : 13)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    static func vertical(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = spacing; return stack
    }
    static func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.alignment = .centerY; stack.spacing = 8; stack.distribution = .fill; return stack
    }
    static func button(_ button: NSButton) {
        button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 13)
        button.setContentHuggingPriority(.required, for: .horizontal)
    }
}
final class PreferencesField: NSTextField {
    var paintsFill = true
    init(_ value: String = "") {
        super.init(frame: .zero); stringValue = value
        isBezeled = false; isBordered = false; drawsBackground = false
        font = .systemFont(ofSize: 13); focusRingType = .exterior
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        cell = PreferencesFieldCell(textCell: value); cell?.font = font; isEditable = true; isSelectable = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        if paintsFill {
            PreferencesStyle.fieldFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
}
private final class PreferencesFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let height = (font?.ascender ?? 10) - (font?.descender ?? -3) + 2
        return NSRect(x: rect.minX + 8, y: rect.midY - height / 2, width: max(0, rect.width - 16), height: height)
    }
    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }
}
/// A single filled number surface; native text editing and NSStepper tracking/AX remain intact.
final class PreferencesNumber: NSView {
    init(field: PreferencesField, stepper: NSStepper) {
        super.init(frame: .zero); field.paintsFill = false
        stepper.cell = PreferencesStepperCell()
        for view in [field, stepper] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 72), heightAnchor.constraint(equalToConstant: 28),
            field.leadingAnchor.constraint(equalTo: leadingAnchor), field.centerYAnchor.constraint(equalTo: centerYAnchor),
            stepper.leadingAnchor.constraint(equalTo: field.trailingAnchor), stepper.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stepper.centerYAnchor.constraint(equalTo: centerYAnchor), stepper.heightAnchor.constraint(equalToConstant: 24)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        PreferencesStyle.fieldFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}
private final class PreferencesStepperCell: NSStepperCell {
    override func draw(withFrame frame: NSRect, in view: NSView) {
        // Only replace the bezel drawing. NSStepperCell still owns hit testing,
        // key handling, autorepeat, bounds, actions and accessibility increments.
        (isEnabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor).setStroke()
        let top = view.isFlipped ? frame.minY : frame.maxY
        let direction: CGFloat = view.isFlipped ? 1 : -1
        for (offset, up) in [(CGFloat(7), true), (CGFloat(17), false)] {
            let y = top + direction * offset, apex = y + direction * (up ? -2 : 2)
            let path = NSBezierPath(); path.lineWidth = isHighlighted ? 1.8 : 1.4
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: NSPoint(x: frame.midX - 3, y: y)); path.line(to: NSPoint(x: frame.midX, y: apex)); path.line(to: NSPoint(x: frame.midX + 3, y: y)); path.stroke()
        }
    }
}
final class PreferencesRow: NSView {
    let title: NSTextField, detail = PreferencesStyle.label("", secondary: true)
    let rowControl: NSView
    private var titleBottom: NSLayoutConstraint!, detailBottom: NSLayoutConstraint!
    init(_ text: String, control: NSView) {
        title = NSTextField(labelWithString: text); title.font = .systemFont(ofSize: 13); title.isSelectable = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rowControl = control
        super.init(frame: .zero)
        let labels = NSView()
        detail.isHidden = true; detail.preferredMaxLayoutWidth = 360
        for label in [title, detail] {
            labels.addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentHuggingPriority(.required, for: .vertical)
        }
        for view in [labels, control] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let naturalHeight = heightAnchor.constraint(equalTo: labels.heightAnchor, constant: 20); naturalHeight.priority = .defaultHigh
        titleBottom = labels.bottomAnchor.constraint(equalTo: title.bottomAnchor)
        detailBottom = labels.bottomAnchor.constraint(equalTo: detail.bottomAnchor)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -16), labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: labels.leadingAnchor), title.trailingAnchor.constraint(equalTo: labels.trailingAnchor), title.topAnchor.constraint(equalTo: labels.topAnchor),
            detail.leadingAnchor.constraint(equalTo: labels.leadingAnchor), detail.trailingAnchor.constraint(equalTo: labels.trailingAnchor), detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3), titleBottom,
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), control.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: control.heightAnchor, constant: 16), heightAnchor.constraint(greaterThanOrEqualTo: labels.heightAnchor, constant: 20),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44), naturalHeight])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func describe(_ text: String) {
        detail.stringValue = text; detail.isHidden = text.isEmpty
        titleBottom.isActive = false; detailBottom.isActive = false
        (text.isEmpty ? titleBottom : detailBottom)?.isActive = true
    }
}
final class PreferencesCard: NSStackView {
    init(_ rows: [NSView] = []) {
        super.init(frame: .zero); orientation = .vertical; alignment = .leading; spacing = 0
        setRows(rows)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setRows(_ rows: [NSView]) {
        for view in arrangedSubviews { removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox(); line.boxType = .separator
                let inset = NSView(); inset.addSubview(line); line.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 12), line.trailingAnchor.constraint(equalTo: inset.trailingAnchor, constant: -12), line.centerYAnchor.constraint(equalTo: inset.centerYAnchor), inset.heightAnchor.constraint(equalToConstant: 1)])
                addArrangedSubview(inset); inset.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            }
            addArrangedSubview(row); row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 1, alpha: 0.7)
        }.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}
final class PreferencesDocument: NSView { override var isFlipped: Bool { true } }
@MainActor final class ControlAction: NSObject {
    let run: (NSControl) -> Void
    init(_ run: @escaping (NSControl) -> Void) { self.run = run }
    @objc func fire(_ sender: NSControl) { run(sender) }
}
@MainActor enum ShortcutEvent {
    static func key(_ event: NSEvent, allowShiftOnly: Bool = false) -> AppConfig.HotKey? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !event.isARepeat, !(allowShiftOnly ? flags : flags.intersection([.command, .option, .control])).isEmpty else { return nil }
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
