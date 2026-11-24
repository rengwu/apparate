import AppKit
import Carbon.HIToolbox
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
@MainActor final class ResultsView: NSView, NSDraggingSource {
    private(set) var contents: [PanelRowContent] = []
    private(set) var firstVisible = 0
    private(set) var selectedID: String?
    private(set) var accessibilityElements: [String: ResultAccessibilityRow] = [:]
    private var artwork: [String: (PanelRowContent, CGFloat, PanelRowDrawing)] = [:]
    private var images: [String: NSImage] = [:]
    private struct IconRequest: Equatable { let icon: ItemIcon, kind: ItemKind; let size: PanelIconSize }
    private var requestedIcons: [String: IconRequest] = [:]
#if APPARATE_TESTING
    var observationMarker: FrameMarker? { didSet { needsDisplay = true } }
#endif
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
    private var press: (id: String, point: NSPoint, event: NSEvent)?
    private var tracksDragExit = false
    private var draggedID: String?
    private let dragCanMove: () -> Bool
    var onDragExit: (() -> Void)?
    var onDrop: ((String) -> Void)?
    private static let dragDistance: CGSize = {
        var distance = CGSize.zero
        guard HIMouseTrackingGetParameters(OSType(kMouseParamsDragInitiation), nil, &distance) == noErr else {
            return CGSize(width: 4, height: 4)
        }
        return distance
    }()
    private let icons: IconLoader
    private var iconGeneration = -1
    var onActivate: ((String) -> Void)?, onSelect: ((String) -> Void)?, onScroll: ((Int) -> Void)?
    var onAccessibilitySelection: (() -> Void)?
    var visibleIndices: Range<Int> { firstVisible..<min(contents.count, firstVisible + PanelModel.pageSize) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    init(icons: IconLoader, dragCanMove: @escaping () -> Bool) {
        self.icons = icons; self.dragCanMove = dragCanMove
        super.init(frame: NSRect(x: 6, y: 35, width: 628, height: 252))
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
        if !model.visible { tracksDragExit = false; press = nil }
        if let press, !ids.contains(press.id) { self.press = nil }
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
#if APPARATE_TESTING
        if let marker = observationMarker {
            // Same draw as the complete rows; compact diagnostic code in the search strip. A full invalidation
            // on each accepted revision draws every visible row and this marker together.
            for (i, bit) in marker.bits.enumerated() {
                (bit ? NSColor.white : NSColor.black).setFill()
                NSRect(x: 582 + i % FrameMarker.columns, y: 16 + i / FrameMarker.columns, width: 1, height: 1).fill()
            }
        }
#endif
    }
    func geometryIsValid() -> Bool {
        bounds.width == 628 && (rowTop == 0 ? bounds.height == rowHeight * 9 : bounds.height >= PanelLayout.stripHeight && bounds.height <= PanelLayout.maximumHeight && (contents.isEmpty || rowTop + CGFloat(visibleIndices.count) * rowHeight <= bounds.height - 35))
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard local.y >= rowTop, local.y < rowTop + CGFloat(visibleIndices.count) * rowHeight else { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        press = nil
        let point = convert(event.locationInWindow, from: nil)
        let index = firstVisible + Int(floor((point.y - rowTop) / rowHeight))
        guard bounds.contains(point), visibleIndices.contains(index) else { return }
        let id = contents[index].id
        press = (id, point, event)
        onSelect?(id)
    }
    override func mouseUp(with event: NSEvent) {
        guard let press else { return }
        self.press = nil
        onActivate?(press.id)
    }
    func takeDrag(at point: NSPoint) -> (item: NSDraggingItem, event: NSEvent)? {
        guard let press,
              abs(point.x - press.point.x) > Self.dragDistance.width || abs(point.y - press.point.y) > Self.dragDistance.height,
              let index = visibleIndices.first(where: { contents[$0].id == press.id }),
              let url = contents[index].fileURL else { return nil }
        let rowY = rowTop + CGFloat(index - firstVisible) * rowHeight
        let frame = drawing(at: index).iconFrame.offsetBy(dx: 0, dy: rowY)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        // A cold row can still be dragged before its asynchronous icon arrives.
        let icon = loadedIcon(at: index) ?? NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(frame, contents: icon)
        draggedID = contents[index].usageID
        self.press = nil
        tracksDragExit = true
        return (item, press.event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag = takeDrag(at: convert(event.locationInWindow, from: nil)) else { return }
        beginDraggingSession(with: [drag.item], event: drag.event, source: self)
    }
    func dragOperations(in context: NSDraggingContext) -> NSDragOperation {
        guard context == .outsideApplication else { return [] }
        return dragCanMove() ? [.copy, .move, .link, .generic] : [.copy, .link]
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        dragOperations(in: context)
    }
    func dragMoved(to point: NSPoint) {
        guard tracksDragExit, let window, !window.frame.contains(point) else { return }
        tracksDragExit = false
        onDragExit?()
    }
    func dragEnded(at point: NSPoint, operation: NSDragOperation) {
        let id = draggedID
        draggedID = nil
        dragMoved(to: point)
        tracksDragExit = false
        if !operation.isEmpty, let id { onDrop?(id) }
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        dragMoved(to: session.draggingLocation)
    }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        dragMoved(to: session.draggingLocation)
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragEnded(at: screenPoint, operation: operation)
    }
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

