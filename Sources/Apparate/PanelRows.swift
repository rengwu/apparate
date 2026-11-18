import AppKit
import ApparateCore

final class ResultAccessibilityRow: NSAccessibilityElement {
    private weak var owner: ResultsView?
    let id: String
    private let select: @MainActor @Sendable () -> Void
    private let press: @MainActor @Sendable () -> Bool
    @MainActor init(id: String, owner: ResultsView) {
        self.id = id; self.owner = owner
        select = { [weak owner] in
            guard let owner, owner.contents.contains(where: { $0.id == id }) else { return }
            owner.onSelect?(id)
        }
        press = { [weak owner] in
            guard let owner, owner.contents.contains(where: { $0.id == id }) else { return false }
            owner.onActivate?(id); return true
        }
        super.init(); setAccessibilityRole(.row); setAccessibilityEnabled(true)
    }
    override func accessibilityParent() -> Any? { owner }
    @MainActor func updateSelected(_ selected: Bool) { super.setAccessibilitySelected(selected) }
    override func setAccessibilitySelected(_ selected: Bool) {
        guard selected else { return }
        let action = select
        if Thread.isMainThread { MainActor.assumeIsolated { action() } }
        else { Task { @MainActor in action() } }
    }
    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        if focused { setAccessibilitySelected(true) }
    }
    override func accessibilityPerformPress() -> Bool {
        let action = press
        if Thread.isMainThread { return MainActor.assumeIsolated { action() } }
        Task { @MainActor in _ = action() }; return true
    }
}

/// One whole-row viewport with stable item-ID accessibility elements.
@MainActor final class ResultsView: NSView {
    private(set) var contents: [PanelRowContent] = []
    private(set) var firstVisible = 0
    private(set) var selectedID: String?
    private(set) var accessibilityElements: [String: ResultAccessibilityRow] = [:]
    private var artwork: [String: (PanelRowContent, CGFloat, PanelRowDrawing)] = [:]
    private var images: [String: NSImage] = [:]
    private var requestedIcons: [String: ItemIcon] = [:]
    private var wheelRemainder: CGFloat = 0
    private let icons: IconLoader
    private var iconGeneration = -1
    var onActivate: ((String) -> Void)?, onSelect: ((String) -> Void)?, onScroll: ((Int) -> Void)?
    var onAccessibilitySelection: (() -> Void)?
    var visibleIndices: Range<Int> { firstVisible..<min(contents.count, firstVisible + PanelModel.pageSize) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    init(icons: IconLoader) {
        self.icons = icons; super.init(frame: NSRect(x: 6, y: 35, width: 628, height: 252))
        setAccessibilityElement(true); setAccessibilityRole(.table); setAccessibilityLabel("Search results")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func apply(_ model: PanelModel) {
        if iconGeneration != icons.generation {
            iconGeneration = icons.generation; images.removeAll(); requestedIcons.removeAll()
        }
        let old = contents, oldFirst = firstVisible, oldSelected = selectedID
        contents = model.rows.enumerated().map { PanelRowContent($0.element, model: model, index: $0.offset) }
        firstVisible = model.firstVisibleRow; selectedID = model.selectedID
        let ids = Set(contents.map(\.id))
        artwork = artwork.filter { ids.contains($0.key) }; images = images.filter { ids.contains($0.key) }
        requestedIcons = requestedIcons.filter { ids.contains($0.key) }
        accessibilityElements = accessibilityElements.filter { ids.contains($0.key) }
        for (index, content) in contents.enumerated() {
            let element = accessibilityElements[content.id] ?? ResultAccessibilityRow(id: content.id, owner: self)
            element.setAccessibilityLabel([content.title, content.location, content.kind, "\(index + 1) of \(contents.count)"].filter { !$0.isEmpty }.joined(separator: ", "))
            element.updateSelected(content.selected)
            element.setAccessibilityIndex(index)
            element.setAccessibilityFrameInParentSpace(NSRect(x: 0, y: CGFloat(index - firstVisible) * 28, width: bounds.width, height: 28))
            accessibilityElements[content.id] = element
        }
        for index in visibleIndices {
            let content = contents[index]
            if requestedIcons[content.id] != content.icon {
                requestedIcons[content.id] = content.icon; images.removeValue(forKey: content.id)
                icons.load(content.icon) { [weak self] image in
                    guard let self, self.requestedIcons[content.id] == content.icon else { return }
                    self.images[content.id] = image; self.invalidate(id: content.id)
                }
            }
        }
        changed(from: old, first: oldFirst)
        if oldSelected != selectedID { onAccessibilitySelection?() }
    }
    func changed(from old: [PanelRowContent], first oldFirst: Int) {
        for slot in 0..<PanelModel.pageSize {
            let before = old.indices.contains(oldFirst + slot) ? old[oldFirst + slot] : nil
            let after = contents.indices.contains(firstVisible + slot) ? contents[firstVisible + slot] : nil
            if before != after { setNeedsDisplay(NSRect(x: 0, y: CGFloat(slot) * 28, width: bounds.width, height: 28)) }
        }
    }
    func invalidate(id: String) {
        guard let index = contents.firstIndex(where: { $0.id == id }), visibleIndices.contains(index) else { return }
        setNeedsDisplay(NSRect(x: 0, y: CGFloat(index - firstVisible) * 28, width: bounds.width, height: 28))
    }
    func invalidateAppearance() { artwork.removeAll(); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); invalidateAppearance() }
    func drawing(at index: Int) -> PanelRowDrawing {
        let content = contents[index]
        if let cached = artwork[content.id], cached.0 == content, cached.1 == bounds.width { return cached.2 }
        var result: PanelRowDrawing!
        effectiveAppearance.performAsCurrentDrawingAppearance { result = PanelRowDrawing(content: content, width: bounds.width) }
        artwork[content.id] = (content, bounds.width, result)
        return result
    }
    func drawRow(_ index: Int, rect: NSRect) {
        guard contents.indices.contains(index) else { return }
        drawing(at: index).draw(content: contents[index], in: rect, icon: images[contents[index].id])
    }
    override func draw(_ dirtyRect: NSRect) {
        for index in visibleIndices {
            let rect = NSRect(x: 0, y: CGFloat(index - firstVisible) * 28, width: bounds.width, height: 28)
            if dirtyRect.intersects(rect) { drawRow(index, rect: rect) }
        }
    }
    func geometryIsValid() -> Bool { bounds.size == NSSize(width: 628, height: 252) }
    func activate(point: NSPoint) {
        let index = firstVisible + Int(floor(point.y / 28))
        guard bounds.contains(point), visibleIndices.contains(index) else { return }
        onActivate?(contents[index].id)
    }
    override func mouseDown(with event: NSEvent) { activate(point: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? -event.scrollingDeltaY : -event.scrollingDeltaY * 28
        wheelRemainder += delta
        let rows = Int(wheelRemainder / 28)
        if rows != 0 { wheelRemainder -= CGFloat(rows) * 28; onScroll?(rows) }
    }
    override func accessibilityChildren() -> [Any]? { contents.compactMap { accessibilityElements[$0.id] } }
    override func accessibilityRows() -> [Any]? { accessibilityChildren() }
    override func accessibilityVisibleRows() -> [Any]? { visibleIndices.compactMap { accessibilityElements[contents[$0].id] } }
    override func accessibilitySelectedRows() -> [Any]? { selectedID.flatMap { accessibilityElements[$0] }.map { [$0] } ?? [] }
    override func accessibilityRowCount() -> Int { contents.count }
}

