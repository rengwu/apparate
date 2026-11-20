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
    private struct IconRequest: Equatable { let icon: ItemIcon, kind: ItemKind; let size: PanelIconSize }
    private var requestedIcons: [String: IconRequest] = [:]
    var observationMarker: FrameMarker? { didSet { needsDisplay = true } }
    var resultLocation = ResultLocation.inline {
        didSet {
            if oldValue != resultLocation {
                artwork.removeAll(); wheelRemainder = 0; needsDisplay = true
                if oldValue.iconSize != resultLocation.iconSize {
                    images.removeAll(); requestedIcons.removeAll(); loadVisibleIcons()
                }
                for (index, content) in contents.enumerated() {
                    accessibilityElements[content.id]?.setAccessibilityFrameInParentSpace(NSRect(x: 0,
                        y: rowTop + CGFloat(index - firstVisible) * rowHeight, width: bounds.width, height: rowHeight))
                }
            }
        }
    }
    var rowHeight: CGFloat { resultLocation.rowHeight }
    var rowTop: CGFloat = 0
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
            element.setAccessibilityFrameInParentSpace(NSRect(x: 0, y: rowTop + CGFloat(index - firstVisible) * rowHeight, width: bounds.width, height: rowHeight))
            accessibilityElements[content.id] = element
        }
        loadVisibleIcons()
        changed(from: old, first: oldFirst)
        if oldSelected != selectedID { onAccessibilitySelection?() }
    }
    private func loadVisibleIcons() {
        for index in visibleIndices {
            let content = contents[index]
            let request = IconRequest(icon: content.icon, kind: content.itemKind, size: resultLocation.iconSize)
            if requestedIcons[content.id] != request {
                requestedIcons[content.id] = request; images.removeValue(forKey: content.id)
                icons.load(content.icon, kind: content.itemKind, size: request.size) { [weak self] image in
                    guard let self, self.requestedIcons[content.id] == request, self.resultLocation.iconSize == request.size else { return }
                    self.images[content.id] = image; self.invalidate(id: content.id)
                }
            }
        }
    }
    func loadedIcon(at index: Int) -> NSImage? { images[contents[index].id] }
    func changed(from old: [PanelRowContent], first oldFirst: Int) {
        for slot in 0..<PanelModel.pageSize {
            let before = old.indices.contains(oldFirst + slot) ? old[oldFirst + slot] : nil
            let after = contents.indices.contains(firstVisible + slot) ? contents[firstVisible + slot] : nil
            if before != after { setNeedsDisplay(NSRect(x: 0, y: rowTop + CGFloat(slot) * rowHeight, width: bounds.width, height: rowHeight)) }
        }
    }
    func invalidate(id: String) {
        guard let index = contents.firstIndex(where: { $0.id == id }), visibleIndices.contains(index) else { return }
        setNeedsDisplay(NSRect(x: 0, y: rowTop + CGFloat(index - firstVisible) * rowHeight, width: bounds.width, height: rowHeight))
    }
    func invalidateAppearance() { artwork.removeAll(); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); invalidateAppearance() }
    func drawing(at index: Int) -> PanelRowDrawing {
        let content = contents[index]
        if let cached = artwork[content.id], cached.0 == content, cached.1 == bounds.width { return cached.2 }
        var result: PanelRowDrawing!
        effectiveAppearance.performAsCurrentDrawingAppearance { result = PanelRowDrawing(content: content, width: bounds.width, layout: resultLocation) }
        artwork[content.id] = (content, bounds.width, result)
        return result
    }
    func drawRow(_ index: Int, rect: NSRect) {
        guard contents.indices.contains(index) else { return }
        drawing(at: index).draw(content: contents[index], in: rect, icon: loadedIcon(at: index))
    }
    override func draw(_ dirtyRect: NSRect) {
        for index in visibleIndices {
            let rect = NSRect(x: 0, y: rowTop + CGFloat(index - firstVisible) * rowHeight, width: bounds.width, height: rowHeight)
            if dirtyRect.intersects(rect) { drawRow(index, rect: rect) }
        }
        if let marker = observationMarker {
            // Same draw as the complete rows; compact diagnostic code in the search strip. A full invalidation
            // on each accepted revision draws every visible row and this marker together.
            for (i, bit) in marker.bits.enumerated() {
                (bit ? NSColor.white : NSColor.black).setFill()
                NSRect(x: 582 + i % FrameMarker.columns, y: 16 + i / FrameMarker.columns, width: 1, height: 1).fill()
            }
        }
    }
    func geometryIsValid() -> Bool {
        bounds.width == 628 && (rowTop == 0 ? bounds.height == rowHeight * 9 : bounds.height >= PanelLayout.stripHeight && bounds.height <= PanelLayout.maximumHeight && (contents.isEmpty || rowTop + CGFloat(visibleIndices.count) * rowHeight <= bounds.height - 35))
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard local.y >= rowTop, local.y < rowTop + CGFloat(visibleIndices.count) * rowHeight else { return nil }
        return super.hitTest(point)
    }
    func activate(point: NSPoint) {
        let index = firstVisible + Int(floor((point.y - rowTop) / rowHeight))
        guard bounds.contains(point), visibleIndices.contains(index) else { return }
        onActivate?(contents[index].id)
    }
    override func mouseDown(with event: NSEvent) { activate(point: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? -event.scrollingDeltaY : -event.scrollingDeltaY * rowHeight
        wheelRemainder += delta
        let rows = Int(wheelRemainder / rowHeight)
        if rows != 0 { wheelRemainder -= CGFloat(rows) * rowHeight; onScroll?(rows) }
    }
    override func accessibilityChildren() -> [Any]? { contents.compactMap { accessibilityElements[$0.id] } }
    override func accessibilityRows() -> [Any]? { accessibilityChildren() }
    override func accessibilityVisibleRows() -> [Any]? { visibleIndices.compactMap { accessibilityElements[contents[$0].id] } }
    override func accessibilitySelectedRows() -> [Any]? { selectedID.flatMap { accessibilityElements[$0] }.map { [$0] } ?? [] }
    override func accessibilityRowCount() -> Int { contents.count }
}

